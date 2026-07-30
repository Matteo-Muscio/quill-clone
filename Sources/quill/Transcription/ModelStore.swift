import FluidAudio
import Foundation

enum ModelStoreError: Error, LocalizedError {
    case notInstalled(TranscriptionModel)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let model):
            "\(model.displayName) is not installed. Open Settings to download it."
        }
    }
}

/// Serializes access to FluidAudio's process-global offline mode.
actor ModelStore {
    struct OfflineMode: Sendable {
        var get: @Sendable () -> Bool
        var set: @Sendable (Bool) -> Void

        static let live = Self(
            get: { ModelHub.offlineMode },
            set: { ModelHub.offlineMode = $0 }
        )
    }

    struct Operations: Sendable {
        var offlineMode: OfflineMode
        var isInstalled: @Sendable (TranscriptionModel) -> Bool
        var loadCached:
            @Sendable (TranscriptionModel) async throws -> AsrModels
        var downloadAndVerify:
            @Sendable (
                TranscriptionModel,
                @escaping ProgressHandler,
                @escaping @Sendable () -> Void
            ) async throws -> Void

        static let live = Self(
            offlineMode: .live,
            isInstalled: { model in
                let version = model.fluidVersion
                let cache = AsrModels.defaultCacheDirectory(for: version)
                return AsrModels.modelsExist(at: cache, version: version)
            },
            loadCached: { model in
                let version = model.fluidVersion
                let cache = AsrModels.defaultCacheDirectory(for: version)
                guard AsrModels.modelsExist(at: cache, version: version) else {
                    throw ModelStoreError.notInstalled(model)
                }
                return try await AsrModels.load(from: cache, version: version)
            },
            downloadAndVerify: { model, progress, verifying in
                let cache = try await AsrModels.download(
                    version: model.fluidVersion,
                    progressHandler: progress
                )
                verifying()
                let models = try await AsrModels.load(
                    from: cache,
                    version: model.fluidVersion
                )
                let manager = AsrManager()
                do {
                    try await manager.loadModels(models)
                    await manager.cleanup()
                } catch {
                    await manager.cleanup()
                    throw error
                }
            }
        )
    }

    static let shared = ModelStore()

    private let operations: Operations
    private var operationInProgress = false
    private var waiters: [
        (id: UUID, continuation: CheckedContinuation<Bool, Never>)
    ] = []

    init(operations: Operations = .live) {
        self.operations = operations
    }

    func isInstalled(_ model: TranscriptionModel) async throws -> Bool {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return operations.isInstalled(model)
    }

    func loadCached(_ model: TranscriptionModel) async throws -> AsrModels {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await withOfflineMode(true) {
            try await operations.loadCached(model)
        }
    }

    func downloadAndVerify(
        _ model: TranscriptionModel,
        progress: @escaping ProgressHandler,
        verifying: @escaping @Sendable () -> Void
    ) async throws {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        try await withOfflineMode(false) {
            try await operations.downloadAndVerify(model, progress, verifying)
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard operationInProgress else {
            operationInProgress = true
            return
        }

        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        guard acquired else { throw CancellationError() }
        guard !Task.isCancelled else {
            release()
            throw CancellationError()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func release() {
        guard !waiters.isEmpty else {
            operationInProgress = false
            return
        }
        waiters.removeFirst().continuation.resume(returning: true)
    }

    private func withOfflineMode<T: Sendable>(
        _ offline: Bool,
        operation: () async throws -> T
    ) async throws -> T {
        let previous = operations.offlineMode.get()
        operations.offlineMode.set(offline)
        defer { operations.offlineMode.set(previous) }
        return try await operation()
    }
}
