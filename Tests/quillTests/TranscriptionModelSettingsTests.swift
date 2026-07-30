import Foundation
import FluidAudio
import XCTest
@testable import quill

final class TranscriptionModelSettingsTests: XCTestCase {
    func testV3IsTheRecommendedDefault() {
        XCTAssertEqual(TranscriptionModel.default, .parakeetV3)
        XCTAssertTrue(TranscriptionModel.parakeetV3.isRecommended)
        XCTAssertFalse(TranscriptionModel.parakeetV2.isRecommended)
    }

    func testCatalogExplainsLanguageFit() {
        XCTAssertTrue(TranscriptionModel.parakeetV3.recommendation.contains("Italian"))
        XCTAssertTrue(TranscriptionModel.parakeetV2.recommendation.contains("English"))
    }

    func testCatalogIdentifiesProvider() {
        XCTAssertEqual(TranscriptionModel.parakeetV3.providerName, "NVIDIA")
        XCTAssertEqual(TranscriptionModel.parakeetV2.providerName, "NVIDIA")
    }

    func testModelIdentifiersAreStable() {
        XCTAssertEqual(TranscriptionModel.parakeetV3.rawValue, "parakeet-v3")
        XCTAssertEqual(TranscriptionModel.parakeetV2.rawValue, "parakeet-v2")
        XCTAssertNotEqual(
            TranscriptionModel.parakeetV3.provenance,
            TranscriptionModel.parakeetV2.provenance
        )
    }

    func testMissingModelDefaultsToV3() throws {
        let url = try temporaryConfig(["recordings_dir": "/tmp/example"])
        XCTAssertEqual(Config.transcriptionModel(at: url), .parakeetV3)
    }

    func testSetModelPreservesUnknownKeys() throws {
        let url = try temporaryConfig([
            "recordings_dir": "/tmp/example",
            "custom": ["keep": true],
            "transcription": ["enabled": false, "engine": "parakeet"],
        ])

        try Config.setTranscriptionModel(.parakeetV2, at: url)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(json["recordings_dir"] as? String, "/tmp/example")
        XCTAssertNotNil(json["custom"])
        let transcription = try XCTUnwrap(json["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["enabled"] as? Bool, false)
        XCTAssertEqual(transcription["engine"] as? String, "parakeet")
        XCTAssertEqual(transcription["model"] as? String, "parakeet-v2")
    }

    func testInvalidModelDefaultsToV3() throws {
        let url = try temporaryConfig(["transcription": ["model": "unknown"]])
        XCTAssertEqual(Config.transcriptionModel(at: url), .parakeetV3)
    }

    func testMalformedConfigIsNotOverwritten() throws {
        try assertInvalidConfigIsPreserved(Data("{broken".utf8))
    }

    func testNonObjectRootIsNotOverwritten() throws {
        try assertInvalidConfigIsPreserved(Data("[]".utf8))
    }

    func testNonObjectTranscriptionIsNotOverwritten() throws {
        let data = try JSONSerialization.data(withJSONObject: ["transcription": true])
        try assertInvalidConfigIsPreserved(data)
    }

    func testMissingConfigMayBeCreated() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")

        try Config.setTranscriptionModel(.parakeetV2, at: url)

        XCTAssertEqual(Config.transcriptionModel(at: url), .parakeetV2)
    }

    func testSelectedModelControlsProvenance() {
        XCTAssertEqual(
            ParakeetEngine(model: .parakeetV3).model,
            "parakeet-tdt-0.6b-v3-coreml"
        )
        XCTAssertEqual(
            ParakeetEngine(model: .parakeetV2).model,
            "parakeet-tdt-0.6b-v2-coreml"
        )
    }

    func testCachedLoadsRequestOfflineAccess() async {
        let recorder = EventRecorder()
        let mode = LockedValue(false)
        let store = ModelStore(operations: .init(
            offlineMode: mode.access,
            isInstalled: { _ in false },
            loadCached: { _ in
                await recorder.append(mode.value ? "offline" : "online")
                throw TestError.expected
            },
            downloadAndVerify: { _, _, _ in }
        ))

        do {
            _ = try await store.loadCached(.parakeetV3)
            XCTFail("expected injected load failure")
        } catch {}

        let events = await recorder.values
        XCTAssertEqual(events, ["offline"])
    }

    func testExplicitDownloadsRequestOnlineAccess() async throws {
        let recorder = EventRecorder()
        let mode = LockedValue(true)
        let store = ModelStore(operations: .init(
            offlineMode: mode.access,
            isInstalled: { _ in false },
            loadCached: { _ in throw TestError.expected },
            downloadAndVerify: { _, _, verifying in
                await recorder.append(mode.value ? "offline" : "online")
                verifying()
            }
        ))

        try await store.downloadAndVerify(.parakeetV2, progress: { _ in }, verifying: {})

        let events = await recorder.values
        XCTAssertEqual(events, ["online"])
        XCTAssertTrue(mode.value)
    }

    func testCacheLoadAndDownloadCannotOverlap() async {
        let recorder = EventRecorder()
        let gate = TestGate()
        let store = ModelStore(operations: .init(
            offlineMode: LockedValue(false).access,
            isInstalled: { _ in false },
            loadCached: { _ in
                await recorder.append("load-start")
                await gate.wait()
                await recorder.append("load-end")
                throw TestError.expected
            },
            downloadAndVerify: { _, _, _ in
                await recorder.append("download")
            }
        ))

        let load = Task { try? await store.loadCached(.parakeetV3) }
        await gate.waitUntilEntered()
        let download = Task {
            try? await store.downloadAndVerify(
                .parakeetV2,
                progress: { _ in },
                verifying: {}
            )
        }
        await Task.yield()
        let eventsBeforeOpen = await recorder.values
        XCTAssertEqual(eventsBeforeOpen, ["load-start"])

        await gate.open()
        _ = await (load.value, download.value)
        let eventsAfterOpen = await recorder.values
        XCTAssertEqual(eventsAfterOpen, ["load-start", "load-end", "download"])
    }

    func testCacheLoadFailureDoesNotInvokeDownload() async {
        let recorder = EventRecorder()
        let store = ModelStore(operations: .init(
            offlineMode: LockedValue(false).access,
            isInstalled: { _ in false },
            loadCached: { _ in
                await recorder.append("load")
                throw TestError.expected
            },
            downloadAndVerify: { _, _, _ in
                await recorder.append("download")
            }
        ))

        _ = try? await store.loadCached(.parakeetV3)

        let events = await recorder.values
        XCTAssertEqual(events, ["load"])
    }

    func testInstalledProbeUsesModelStoreBoundary() async throws {
        let store = ModelStore(operations: .init(
            offlineMode: LockedValue(false).access,
            isInstalled: { $0 == .parakeetV2 },
            loadCached: { _ in throw TestError.expected },
            downloadAndVerify: { _, _, _ in }
        ))

        let v2Installed = try await store.isInstalled(.parakeetV2)
        let v3Installed = try await store.isInstalled(.parakeetV3)
        XCTAssertTrue(v2Installed)
        XCTAssertFalse(v3Installed)
    }

    func testInstalledProbeWaitsBehindActiveStoreOperation() async throws {
        let operationGate = TestGate()
        let probeStarted = LockedFlag()
        let probeRan = LockedFlag()
        let store = ModelStore(operations: .init(
            offlineMode: LockedValue(false).access,
            isInstalled: { _ in
                probeRan.set()
                return true
            },
            loadCached: { _ in throw TestError.expected },
            downloadAndVerify: { _, _, _ in
                await operationGate.wait()
            }
        ))

        let download = Task {
            try? await store.downloadAndVerify(
                .parakeetV3,
                progress: { _ in },
                verifying: {}
            )
        }
        await operationGate.waitUntilEntered()
        let probe = Task {
            probeStarted.set()
            return try await store.isInstalled(.parakeetV3)
        }
        while !probeStarted.value {
            await Task.yield()
        }
        for _ in 0..<100 {
            await Task.yield()
        }
        XCTAssertFalse(probeRan.value)

        await operationGate.open()
        _ = await download.value
        let installed = try await probe.value
        XCTAssertTrue(installed)
        XCTAssertTrue(probeRan.value)
    }

    func testOfflineModeRestoresAfterThrownError() async {
        let mode = LockedValue(false)
        let store = ModelStore(operations: .init(
            offlineMode: mode.access,
            isInstalled: { _ in false },
            loadCached: { _ in throw TestError.expected },
            downloadAndVerify: { _, _, _ in }
        ))

        _ = try? await store.loadCached(.parakeetV3)

        XCTAssertFalse(mode.value)
    }

    func testOfflineModeRestoresAfterCancellation() async {
        let mode = LockedValue(true)
        let entered = LockedFlag()
        let store = ModelStore(operations: .init(
            offlineMode: mode.access,
            isInstalled: { _ in false },
            loadCached: { _ in throw TestError.expected },
            downloadAndVerify: { _, _, _ in
                entered.set()
                while !Task.isCancelled {
                    await Task.yield()
                }
                try Task.checkCancellation()
            }
        ))
        let task = Task {
            try await store.downloadAndVerify(
                .parakeetV3,
                progress: { _ in },
                verifying: {}
            )
        }
        while !entered.value {
            await Task.yield()
        }

        task.cancel()
        _ = try? await task.value

        XCTAssertTrue(mode.value)
    }

    func testCancelledQueuedOperationDoesNotRunAndNextWaiterProgresses() async throws {
        let activeGate = TestGate()
        let queuedStarted = LockedFlag()
        let downloadRan = LockedFlag()
        let probeRan = LockedFlag()
        let store = ModelStore(operations: .init(
            offlineMode: LockedValue(false).access,
            isInstalled: { _ in
                probeRan.set()
                return true
            },
            loadCached: { _ in
                await activeGate.wait()
                throw TestError.expected
            },
            downloadAndVerify: { _, _, _ in
                downloadRan.set()
            }
        ))
        let active = Task { try? await store.loadCached(.parakeetV3) }
        await activeGate.waitUntilEntered()
        let cancelled = Task {
            queuedStarted.set()
            try await store.downloadAndVerify(
                .parakeetV2,
                progress: { _ in },
                verifying: {}
            )
        }
        while !queuedStarted.value {
            await Task.yield()
        }
        for _ in 0..<100 {
            await Task.yield()
        }
        cancelled.cancel()
        let probe = Task { try await store.isInstalled(.parakeetV3) }

        await activeGate.open()
        _ = await active.value
        do {
            try await cancelled.value
            XCTFail("cancelled queued operation unexpectedly completed")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
        let installed = try await probe.value

        XCTAssertFalse(downloadRan.value)
        XCTAssertTrue(installed)
        XCTAssertTrue(probeRan.value)
    }

    private func temporaryConfig(_ json: [String: Any]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }

    private func assertInvalidConfigIsPreserved(_ original: Data) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try original.write(to: url)

        XCTAssertThrowsError(try Config.setTranscriptionModel(.parakeetV2, at: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}

private enum TestError: Error {
    case expected
}

private actor EventRecorder {
    private var events: [String] = []
    var values: [String] { events }

    func append(_ event: String) {
        events.append(event)
    }
}

private actor TestGate {
    private var entered = false
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.withLock { flag }
    }

    func set() {
        lock.withLock { flag = true }
    }
}

private final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.withLock { stored }
    }
}

private extension LockedValue where Value == Bool {
    var access: ModelStore.OfflineMode {
        .init(
            get: { [self] in value },
            set: { [self] newValue in lock.withLock { stored = newValue } }
        )
    }
}
