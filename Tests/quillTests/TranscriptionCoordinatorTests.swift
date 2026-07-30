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
    nonisolated let model = "test-model"

    private(set) var prepareCount = 0
    private(set) var transcribeCount = 0

    func prepare() {
        prepareCount += 1
    }

    func transcribe(_ audio: URL) -> [TranscriptSegment] {
        transcribeCount += 1
        return [TranscriptSegment(start: 0, end: 1, text: audio.lastPathComponent)]
    }

    func release() {}
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

    func update(_ body: (inout Value) -> Void) {
        lock.withLock { body(&stored) }
    }
}
