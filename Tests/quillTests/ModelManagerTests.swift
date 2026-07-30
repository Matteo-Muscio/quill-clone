import XCTest
@testable import quill

final class ModelManagerTests: XCTestCase {
    actor DownloadHarness {
        enum Outcome: Sendable {
            case success
            case failure
            case suspended
        }

        struct TestError: LocalizedError, Sendable {
            var errorDescription: String? { "download failed" }
        }

        let outcome: Outcome
        private var continuation: CheckedContinuation<Void, Error>?

        init(outcome: Outcome) {
            self.outcome = outcome
        }

        func download(
            progress: @escaping @Sendable (Double) -> Void,
            verifying: @escaping @Sendable () -> Void
        ) async throws {
            progress(0.7)
            progress(0.4)
            verifying()

            switch outcome {
            case .success:
                return
            case .failure:
                throw TestError()
            case .suspended:
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation {
                        continuation = $0
                    }
                } onCancel: {
                    Task { await self.cancelDownload() }
                }
            }
        }

        private func cancelDownload() {
            continuation?.resume(throwing: CancellationError())
            continuation = nil
        }
    }

    @MainActor
    final class ActivationSpy {
        var models: [TranscriptionModel] = []
    }

    @MainActor
    func testInitialStateReflectsInstalledModels() {
        let manager = makeManager(
            active: .parakeetV2,
            installed: [.parakeetV2, .parakeetV3]
        )

        XCTAssertEqual(manager.state(for: .parakeetV2), .active)
        XCTAssertEqual(manager.state(for: .parakeetV3), .installed)
    }

    @MainActor
    func testSuccessfulDownloadPersistsThenActivatesOnce() async {
        let harness = DownloadHarness(outcome: .success)
        let persisted = ActivationSpy()
        let activated = ActivationSpy()
        let manager = makeManager(
            active: .parakeetV2,
            installed: [.parakeetV2],
            harness: harness,
            persist: { persisted.models.append($0) },
            onActivation: { activated.models.append(.parakeetV3) }
        )

        await manager.downloadAndUse(.parakeetV3)

        XCTAssertEqual(persisted.models, [.parakeetV3])
        XCTAssertEqual(manager.activeModel, .parakeetV3)
        XCTAssertEqual(manager.state(for: .parakeetV2), .installed)
        XCTAssertEqual(manager.state(for: .parakeetV3), .active)
        XCTAssertEqual(activated.models, [.parakeetV3])
    }

    @MainActor
    func testProgressIsMonotonic() async {
        let manager = ModelManager(
            activeModel: .parakeetV2,
            operations: .init(
                isInstalled: { $0 == .parakeetV2 },
                downloadAndVerify: { _, progress, _ in
                    progress(0.7)
                    progress(0.4)
                    try await Task.sleep(for: .seconds(3_600))
                },
                persist: { _ in }
            )
        )
        let task = Task { await manager.downloadAndUse(.parakeetV3) }

        await waitUntil { manager.state(for: .parakeetV3) == .downloading(0.7) }
        XCTAssertEqual(manager.state(for: .parakeetV3), .downloading(0.7))
        XCTAssertTrue(manager.isPreparingModel)

        manager.cancel()
        await task.value
    }

    @MainActor
    func testVerificationIsIndeterminate() async {
        let harness = DownloadHarness(outcome: .suspended)
        let manager = makeManager(harness: harness)
        let task = Task { await manager.downloadAndUse(.parakeetV3) }

        await waitUntil { manager.state(for: .parakeetV3) == .verifying }
        XCTAssertEqual(manager.state(for: .parakeetV3), .verifying)

        manager.cancel()
        await task.value
    }

    @MainActor
    func testCancellationRestoresPreviousState() async {
        let harness = DownloadHarness(outcome: .suspended)
        let manager = makeManager(harness: harness)
        let task = Task { await manager.downloadAndUse(.parakeetV3) }
        await waitUntil { manager.state(for: .parakeetV3) == .verifying }

        manager.cancel()
        await task.value

        XCTAssertEqual(manager.activeModel, .parakeetV2)
        XCTAssertEqual(manager.state(for: .parakeetV3), .notInstalled)
        XCTAssertFalse(manager.isPreparingModel)
    }

    @MainActor
    func testFailureLeavesSelectionUnchangedAndOffersRetry() async {
        let harness = DownloadHarness(outcome: .failure)
        let manager = makeManager(harness: harness)

        await manager.downloadAndUse(.parakeetV3)

        XCTAssertEqual(manager.activeModel, .parakeetV2)
        XCTAssertEqual(manager.state(for: .parakeetV3), .failed("download failed"))
    }

    @MainActor
    func testActionsLockedPreventsDownloadAndActivation() async {
        let harness = DownloadHarness(outcome: .success)
        let activated = ActivationSpy()
        let manager = makeManager(
            installed: [.parakeetV2, .parakeetV3],
            harness: harness,
            onActivation: { activated.models.append(.parakeetV3) }
        )
        manager.actionsLocked = true

        await manager.downloadAndUse(.parakeetV3)
        manager.activate(.parakeetV3)

        XCTAssertEqual(manager.activeModel, .parakeetV2)
        XCTAssertTrue(activated.models.isEmpty)
    }

    @MainActor
    func testProgressFromDetachedTaskReachesMainActor() async {
        let manager = ModelManager(
            activeModel: .parakeetV2,
            operations: .init(
                isInstalled: { $0 == .parakeetV2 },
                downloadAndVerify: { _, progress, verifying in
                    await Task.detached {
                        progress(0.6)
                        verifying()
                    }.value
                    try await Task.sleep(for: .seconds(3_600))
                },
                persist: { _ in }
            )
        )
        let task = Task { await manager.downloadAndUse(.parakeetV3) }

        await waitUntil { manager.state(for: .parakeetV3) == .verifying }
        XCTAssertEqual(manager.state(for: .parakeetV3), .verifying)

        manager.cancel()
        await task.value
    }

    @MainActor
    private func makeManager(
        active: TranscriptionModel = .parakeetV2,
        installed: Set<TranscriptionModel> = [.parakeetV2],
        harness: DownloadHarness = DownloadHarness(outcome: .success),
        persist: @escaping @MainActor @Sendable (TranscriptionModel) throws -> Void = { _ in },
        onActivation: @escaping @MainActor @Sendable () -> Void = {}
    ) -> ModelManager {
        ModelManager(
            activeModel: active,
            operations: .init(
                isInstalled: { installed.contains($0) },
                downloadAndVerify: { _, progress, verifying in
                    try await harness.download(progress: progress, verifying: verifying)
                },
                persist: persist
            ),
            onActivation: onActivation
        )
    }

    @MainActor
    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 where !predicate() {
            await Task.yield()
        }
    }
}
