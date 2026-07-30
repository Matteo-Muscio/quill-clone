import Foundation
import XCTest
@testable import quill

final class TranscriptionCoordinatorTests: XCTestCase {
    func testMissingModelRetainsQueueAndPublishesWaitingOnce() async throws {
        let root = try temporaryRoot()
        let session = try makeSession("2026-07-30-100000", in: root)
        let installed = Locked(false)
        let probes = Locked(0)
        let engine = TestEngine()
        let statuses = Locked<[String]>([])
        let notifications = Locked<[String]>([])
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { true },
            selectedModel: { .parakeetV3 },
            isModelInstalled: { _ in
                probes.update { $0 += 1 }
                return installed.value
            },
            makeEngine: { _ in engine },
            notification: { title, _ in notifications.update { $0.append(title) } }
        )
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }

        await coordinator.resumePending(root: root)
        await waitUntil { statuses.value.contains("waiting:1") }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: session.appendingPathComponent("transcript.json").path
        ))
        let prepareCount = await engine.prepareCount
        XCTAssertEqual(prepareCount, 0)
        XCTAssertEqual(notifications.value, ["quill — transcription waiting"])

        await coordinator.resumePending(root: root)
        await waitUntil { probes.value >= 2 }
        await coordinator.resumePending(root: root)
        await waitUntil { probes.value >= 3 }

        XCTAssertEqual(statuses.value.filter { $0 == "waiting:1" }.count, 1)
        XCTAssertEqual(notifications.value, ["quill — transcription waiting"])
        XCTAssertFalse(statuses.value.contains { $0.hasPrefix("failed:") })
    }

    func testActivationRescansAndDrainsRetainedSessionWithoutDuplicates() async throws {
        let root = try temporaryRoot()
        let session = try makeSession("2026-07-30-100000", in: root)
        let installed = Locked(false)
        let engine = TestEngine()
        let statuses = Locked<[String]>([])
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { true },
            selectedModel: { .parakeetV3 },
            isModelInstalled: { _ in installed.value },
            makeEngine: { _ in engine },
            notification: { _, _ in }
        )
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }

        await coordinator.resumePending(root: root)
        await waitUntil { statuses.value.contains("waiting:1") }
        await coordinator.resumePending(root: root)
        installed.set(true)

        await coordinator.modelDidActivate(root: root)
        await waitUntil {
            FileManager.default.fileExists(
                atPath: session.appendingPathComponent("transcript.json").path
            )
        }
        await coordinator.modelDidActivate(root: root)
        for _ in 0..<20 { await Task.yield() }

        let transcribeCount = await engine.transcribeCount
        XCTAssertEqual(transcribeCount, 1)
        XCTAssertEqual(statuses.value.filter { $0 == "waiting:1" }.count, 1)
        XCTAssertEqual(statuses.value.filter { $0.hasPrefix("transcribing:") }.count, 1)
    }

    func testRestartRecoveryContinuesAfterFailedSession() async throws {
        let root = try temporaryRoot()
        let failed = root.appendingPathComponent("2026-07-30-100000", isDirectory: true)
        try FileManager.default.createDirectory(at: failed, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: failed.appendingPathComponent("meta.json"))
        let successful = try makeSession("2026-07-30-100001", in: root)
        let engine = TestEngine()
        let statuses = Locked<[String]>([])
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { true },
            selectedModel: { .parakeetV3 },
            isModelInstalled: { _ in true },
            makeEngine: { _ in engine },
            notification: { _, _ in }
        )
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }

        await coordinator.resumePending(root: root)
        await waitUntil {
            statuses.value.contains("failed:\(failed.lastPathComponent)")
        }

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: failed.appendingPathComponent("transcribe.log").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: successful.appendingPathComponent("transcript.json").path
        ))
        let transcribeCount = await engine.transcribeCount
        XCTAssertEqual(transcribeCount, 1)
    }

    func testRescanDoesNotRequeueInFlightSession() async throws {
        let root = try temporaryRoot()
        _ = try makeSession("2026-07-30-100000", in: root)
        let gate = TestGate()
        let engine = TestEngine(
            model: TranscriptionModel.parakeetV3.provenance,
            transcribeGate: gate
        )
        let statuses = Locked<[String]>([])
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { true },
            selectedModel: { .parakeetV3 },
            isModelInstalled: { _ in true },
            makeEngine: { _ in engine },
            notification: { _, _ in }
        )
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }

        await coordinator.resumePending(root: root)
        await gate.waitUntilEntered()
        await coordinator.modelDidActivate(root: root)
        await gate.open()
        await waitUntil { statuses.value.last == "idle" }

        let transcribeCount = await engine.transcribeCount
        XCTAssertEqual(transcribeCount, 1)
    }

    func testWaitingPublishesChangedPendingCountWithoutRenotifying() async throws {
        let root = try temporaryRoot()
        _ = try makeSession("2026-07-30-100000", in: root)
        let probes = Locked(0)
        let statuses = Locked<[String]>([])
        let notifications = Locked(0)
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { true },
            selectedModel: { .parakeetV3 },
            isModelInstalled: { _ in
                probes.update { $0 += 1 }
                return false
            },
            makeEngine: { _ in TestEngine() },
            notification: { _, _ in notifications.update { $0 += 1 } }
        )
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }

        await coordinator.resumePending(root: root)
        await waitUntil { statuses.value.contains("waiting:1") }
        _ = try makeSession("2026-07-30-100001", in: root)
        await coordinator.resumePending(root: root)
        await waitUntil { probes.value >= 2 }

        XCTAssertEqual(statuses.value.filter { $0.hasPrefix("waiting:") }, [
            "waiting:1",
            "waiting:2",
        ])
        XCTAssertEqual(notifications.value, 1)
    }

    func testFailedReplacementPrepareDoesNotReuseReleasedEngine() async throws {
        let root = try temporaryRoot()
        _ = try makeSession("2026-07-30-100000", in: root)
        let failed = try makeSession("2026-07-30-100001", in: root)
        _ = try makeSession("2026-07-30-100002", in: root)
        let selections = Locked([
            TranscriptionModel.parakeetV3,
            .parakeetV2,
            .parakeetV3,
        ])
        let v3FactoryCalls = Locked(0)
        let firstV3 = TestEngine(model: TranscriptionModel.parakeetV3.provenance)
        let secondV3 = TestEngine(model: TranscriptionModel.parakeetV3.provenance)
        let v2 = TestEngine(
            model: TranscriptionModel.parakeetV2.provenance,
            prepareFails: true
        )
        let statuses = Locked<[String]>([])
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { true },
            selectedModel: { selections.update { $0.removeFirst() } },
            isModelInstalled: { _ in true },
            makeEngine: { model in
                guard model == .parakeetV3 else { return v2 }
                return v3FactoryCalls.update {
                    $0 += 1
                    return $0 == 1 ? firstV3 : secondV3
                }
            },
            notification: { _, _ in }
        )
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }

        await coordinator.resumePending(root: root)
        await waitUntil {
            statuses.value.contains("failed:\(failed.lastPathComponent)")
        }

        XCTAssertEqual(v3FactoryCalls.value, 2)
        let firstReleaseCount = await firstV3.releaseCount
        let secondPrepareCount = await secondV3.prepareCount
        let secondTranscribeCount = await secondV3.transcribeCount
        XCTAssertEqual(firstReleaseCount, 1)
        XCTAssertEqual(secondPrepareCount, 1)
        XCTAssertEqual(secondTranscribeCount, 1)
    }

    private static func label(for status: TranscriptionCoordinator.Status) -> String {
        switch status {
        case .idle:
            "idle"
        case .transcribing(let session, let queued):
            "transcribing:\(session):\(queued)"
        case .failed(let session):
            "failed:\(session)"
        case .waitingForModel(let pending):
            "waiting:\(pending)"
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeSession(_ name: String, in root: URL) throws -> URL {
        let session = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let meta = ["files": ["mic": "mic.caf"]]
        let data = try JSONSerialization.data(withJSONObject: meta)
        try data.write(to: session.appendingPathComponent("meta.json"))
        try Data([1]).write(to: session.appendingPathComponent("mic.caf"))
        return session
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @Sendable () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition was not met before timeout")
    }
}

private actor TestEngine: TranscriptionEngine {
    nonisolated let name = "test"
    nonisolated let model: String

    private(set) var prepareCount = 0
    private(set) var transcribeCount = 0
    private(set) var releaseCount = 0
    private let prepareFails: Bool
    private let transcribeGate: TestGate?

    init(
        model: String = "test-model",
        prepareFails: Bool = false,
        transcribeGate: TestGate? = nil
    ) {
        self.model = model
        self.prepareFails = prepareFails
        self.transcribeGate = transcribeGate
    }

    func prepare() throws {
        prepareCount += 1
        if prepareFails {
            throw TestError.expected
        }
    }

    func transcribe(_ audio: URL) async -> [TranscriptSegment] {
        transcribeCount += 1
        await transcribeGate?.wait()
        return [TranscriptSegment(start: 0, end: 1, text: audio.lastPathComponent)]
    }

    func release() {
        releaseCount += 1
    }
}

private enum TestError: Error {
    case expected
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

private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.withLock { stored }
    }

    func set(_ value: Value) {
        lock.withLock { stored = value }
    }

    func update<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&stored) }
    }
}
