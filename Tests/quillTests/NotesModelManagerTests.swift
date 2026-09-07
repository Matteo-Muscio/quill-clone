import XCTest
@testable import quill

final class NotesModelManagerTests: XCTestCase {
    actor Probe {
        private var pending: CheckedContinuation<Bool, Never>?
        private var started = false
        func installed(_ model: NotesModel) async -> Bool {
            guard model == .qwen35_2B else { return false }
            started = true
            return await withCheckedContinuation { pending = $0 }
        }
        func waitUntilStarted() async { while !started { await Task.yield() } }
        func resolve(_ result: Bool) { pending?.resume(returning: result); pending = nil }
    }

    actor ProgressRelay {
        private var callbacks: [@Sendable (Double) -> Void] = []
        func download(_ progress: @escaping @Sendable (Double) -> Void) async throws {
            callbacks.append(progress)
            try await Task.sleep(for: .seconds(3600))
        }
        func waitForCalls(_ count: Int) async { while callbacks.count < count { await Task.yield() } }
        func emit(_ index: Int, _ value: Double) { callbacks[index](value) }
    }

    @MainActor
    func testLateInstallationProbeCannotOverwriteNewActivation() async {
        let probe = Probe()
        let manager = NotesModelManager(operations: .init(isInstalled: { await probe.installed($0) },
            download: { _, _, verifying in verifying() }, persist: { _ in }))
        await probe.waitUntilStarted()
        await manager.downloadAndUse(.qwen35_2B)
        await probe.resolve(false)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(manager.activeModel, .qwen35_2B)
        XCTAssertEqual(manager.state(for: .qwen35_2B), .active)
    }

    @MainActor
    func testCancelledJobCannotPublishProgressIntoNextDownload() async {
        let relay = ProgressRelay()
        let manager = NotesModelManager(operations: .init(isInstalled: { _ in false },
            download: { _, progress, _ in try await relay.download(progress) }, persist: { _ in }))
        let first = Task { await manager.downloadAndUse(.qwen35_2B) }
        await relay.waitForCalls(1)
        manager.cancel()
        await first.value
        let second = Task { await manager.downloadAndUse(.smolLM3_3B) }
        await relay.waitForCalls(2)
        await relay.emit(0, 0.9)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(manager.state(for: .qwen35_2B), .notInstalled)
        XCTAssertEqual(manager.state(for: .smolLM3_3B), .downloading(0))
        manager.cancel()
        await second.value
        XCTAssertFalse(manager.isPreparingModel)
    }

    @MainActor
    func testLockedManagerCannotDownloadOrActivate() async {
        let manager = NotesModelManager(actionsLocked: true,
            operations: .init(isInstalled: { _ in false }, download: { _, _, _ in XCTFail("Locked download ran") }, persist: { _ in XCTFail("Locked activation ran") }))
        await manager.downloadAndUse(.smolLM3_3B)
        manager.activate(.smolLM3_3B)
        XCTAssertEqual(manager.state(for: .smolLM3_3B), .notInstalled)
    }
}
