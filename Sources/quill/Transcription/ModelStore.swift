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
    struct Operations: Sendable {
        var isInstalled: @Sendable (TranscriptionModel) -> Bool
        var loadCached:
            @Sendable (TranscriptionModel, Bool) async throws -> AsrModels
        var downloadAndVerify:
            @Sendable (
                TranscriptionModel,
                Bool,
                @escaping ProgressHandler,
                @escaping @Sendable () -> Void
            ) async throws -> Void

        static let live = Self(
            isInstalled: { model in
                let version = model.fluidVersion
                let cache = AsrModels.defaultCacheDirectory(for: version)
                return AsrModels.modelsExist(at: cache, version: version)
            },
            loadCached: { model, _ in
                let version = model.fluidVersion
                let cache = AsrModels.defaultCacheDirectory(for: version)
                guard AsrModels.modelsExist(at: cache, version: version) else {
                    throw ModelStoreError.notInstalled(model)
                }
                return try await AsrModels.load(from: cache, version: version)
            },
            downloadAndVerify: { model, _, progress, verifying in
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
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(operations: Operations = .live) {
        self.operations = operations
    }

    func isInstalled(_ model: TranscriptionModel) async -> Bool {
        await acquire()
        defer { release() }
        return operations.isInstalled(model)
    }

    func loadCached(_ model: TranscriptionModel) async throws -> AsrModels {
        await acquire()
        defer { release() }
        return try await withOfflineMode(true) {
            try await operations.loadCached(model, true)
        }
    }

    func downloadAndVerify(
        _ model: TranscriptionModel,
        progress: @escaping ProgressHandler,
        verifying: @escaping @Sendable () -> Void
    ) async throws {
        await acquire()
        defer { release() }
        try await withOfflineMode(false) {
            try await operations.downloadAndVerify(model, true, progress, verifying)
        }
    }

    private func acquire() async {
        guard operationInProgress else {
            operationInProgress = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        guard !waiters.isEmpty else {
            operationInProgress = false
            return
        }
        waiters.removeFirst().resume()
    }

    private func withOfflineMode<T: Sendable>(
        _ offline: Bool,
        operation: () async throws -> T
    ) async throws -> T {
        let previous = ModelHub.offlineMode
        ModelHub.offlineMode = offline
        defer { ModelHub.offlineMode = previous }
        return try await operation()
    }
}
