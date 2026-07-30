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
        private var cancellationRequested = false
        private(set) var callCount = 0

        init(outcome: Outcome) {
            self.outcome = outcome
        }

        func download(
            progress: @escaping @Sendable (Double) -> Void,
            verifying: @escaping @Sendable () -> Void
        ) async throws {
            callCount += 1
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
                        (continuation: CheckedContinuation<Void, Error>) in
                        if cancellationRequested {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            self.continuation = continuation
                        }
                    }
                } onCancel: {
                    Task { await self.cancelDownload() }
                }
            }
        }

        private func cancelDownload() {
            if let continuation {
                continuation.resume(throwing: CancellationError())
                self.continuation = nil
            } else {
                cancellationRequested = true
            }
        }
    }

    @MainActor
    final class ActivationSpy {
        var models: [TranscriptionModel] = []
    }

    @MainActor
    final class ActivationPersistence {
        struct TestError: LocalizedError {
            var errorDescription: String? { "config write failed" }
        }

        private var shouldFail = true

        func persist(_ model: TranscriptionModel) throws {
            if shouldFail {
                shouldFail = false
                throw TestError()
            }
        }
    }

    actor ProbeHarness {
        private var resultContinuation: CheckedContinuation<Bool, Never>?
        private var startContinuation: CheckedContinuation<Void, Never>?
        private var started = false
        private var resolved: Bool?

        func isInstalled(_ model: TranscriptionModel) async -> Bool {
            guard model == .parakeetV3 else { return true }
            if let resolved { return resolved }
            started = true
            startContinuation?.resume()
            startContinuation = nil
            return await withCheckedContinuation {
                resultContinuation = $0
            }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation {
                startContinuation = $0
            }
        }

        func resolve(_ installed: Bool) {
            resolved = installed
            resultContinuation?.resume(returning: installed)
            resultContinuation = nil
        }
    }

    @MainActor
    func testInitialStateReflectsInstalledModels() async {
        let manager = makeManager(
            active: .parakeetV2,
            installed: [.parakeetV2, .parakeetV3]
        )
        await waitUntil {
            manager.state(for: .parakeetV2) == .active
                && manager.state(for: .parakeetV3) == .installed
        }

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
    func testCancellingCallerCancelsDownloadAndRestoresState() async {
        let harness = DownloadHarness(outcome: .suspended)
        let manager = makeManager(harness: harness)
        let task = Task { await manager.downloadAndUse(.parakeetV3) }
        await waitUntil { manager.state(for: .parakeetV3) == .verifying }

        task.cancel()
        await task.value

        XCTAssertEqual(manager.state(for: .parakeetV3), .notInstalled)
        XCTAssertFalse(manager.isPreparingModel)
    }

    @MainActor
    func testCancellationReprobesAnUnresolvedInstalledModel() async {
        let probe = ProbeHarness()
        let download = DownloadHarness(outcome: .suspended)
        let manager = ModelManager(
            activeModel: .parakeetV2,
            operations: .init(
                isInstalled: {
                    try Task.checkCancellation()
                    return await probe.isInstalled($0)
                },
                downloadAndVerify: { _, progress, verifying in
                    try await download.download(progress: progress, verifying: verifying)
                },
                persist: { _ in }
            )
        )
        await probe.waitUntilStarted()
        let task = Task { await manager.downloadAndUse(.parakeetV3) }
        await waitUntil { manager.state(for: .parakeetV3) == .verifying }

        manager.cancel()
        await probe.resolve(true)
        await task.value

        XCTAssertEqual(manager.state(for: .parakeetV3), .installed)
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
    func testActivationFailureRetriesPersistenceWithoutDownloading() async {
        let download = DownloadHarness(outcome: .success)
        let persistence = ActivationPersistence()
        let manager = makeManager(
            installed: [.parakeetV2, .parakeetV3],
            harness: download,
            persist: persistence.persist
        )
        await waitUntil { manager.state(for: .parakeetV3) == .installed }
        manager.activate(.parakeetV3)
        XCTAssertEqual(
            manager.state(for: .parakeetV3),
            .activationFailed("config write failed")
        )

        manager.activate(.parakeetV3)

        let downloadCalls = await download.callCount
        XCTAssertEqual(manager.state(for: .parakeetV3), .active)
        XCTAssertEqual(manager.activeModel, .parakeetV3)
        XCTAssertEqual(downloadCalls, 0)
    }

    @MainActor
    func testDownloadedModelRetriesPersistenceWithoutDownloadingAgain() async {
        let download = DownloadHarness(outcome: .success)
        let persistence = ActivationPersistence()
        let manager = makeManager(
            harness: download,
            persist: persistence.persist
        )

        await manager.downloadAndUse(.parakeetV3)
        XCTAssertEqual(
            manager.state(for: .parakeetV3),
            .activationFailed("config write failed")
        )

        manager.activate(.parakeetV3)

        let downloadCalls = await download.callCount
        XCTAssertEqual(manager.state(for: .parakeetV3), .active)
        XCTAssertEqual(manager.activeModel, .parakeetV3)
        XCTAssertEqual(downloadCalls, 1)
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
    func testLateInstallationProbeCannotOverwriteActivation() async {
        let probe = ProbeHarness()
        let manager = ModelManager(
            activeModel: .parakeetV2,
            operations: .init(
                isInstalled: { await probe.isInstalled($0) },
                downloadAndVerify: { _, _, verifying in verifying() },
                persist: { _ in }
            )
        )
        await probe.waitUntilStarted()

        await manager.downloadAndUse(.parakeetV3)
        await probe.resolve(false)
        await Task.yield()

        XCTAssertEqual(manager.state(for: .parakeetV3), .active)
        XCTAssertEqual(manager.activeModel, .parakeetV3)
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
