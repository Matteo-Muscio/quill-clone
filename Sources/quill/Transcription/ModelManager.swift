import Combine
import Foundation

enum ModelState: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case verifying
    case installed
    case active
    case failed(String)
}

@MainActor
final class ModelManager: ObservableObject {
    struct Operations: Sendable {
        var isInstalled: @Sendable (TranscriptionModel) -> Bool
        var downloadAndVerify:
            @Sendable (
                TranscriptionModel,
                @escaping @Sendable (Double) -> Void,
                @escaping @Sendable () -> Void
            ) async throws -> Void
        var persist: @MainActor @Sendable (TranscriptionModel) throws -> Void

        static let live = Operations(
            isInstalled: { ModelStore.shared.isInstalled($0) },
            downloadAndVerify: { model, progress, verifying in
                try await ModelStore.shared.downloadAndVerify(
                    model,
                    progress: { snapshot in
                        progress(snapshot.fractionCompleted)
                    },
                    verifying: verifying
                )
            },
            persist: { model in
                try Config.setTranscriptionModel(model)
            }
        )
    }

    @Published private(set) var states: [TranscriptionModel: ModelState]
    @Published private(set) var activeModel: TranscriptionModel
    @Published var actionsLocked: Bool
    @Published var pendingCount: Int
    @Published private(set) var isPreparingModel = false

    private let operations: Operations
    private let onActivation: @MainActor @Sendable () -> Void
    private var downloadTask: Task<Void, Never>?
    private var operationID: UUID?

    init(
        activeModel: TranscriptionModel = Config.transcriptionModel(),
        actionsLocked: Bool = false,
        pendingCount: Int = 0,
        operations: Operations = .live,
        onActivation: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.activeModel = activeModel
        self.actionsLocked = actionsLocked
        self.pendingCount = pendingCount
        self.operations = operations
        self.onActivation = onActivation

        var states: [TranscriptionModel: ModelState] = [:]
        for model in TranscriptionModel.allCases {
            states[model] = operations.isInstalled(model) ? .installed : .notInstalled
        }
        if states[activeModel] == .installed {
            states[activeModel] = .active
        }
        self.states = states
    }

    func state(for model: TranscriptionModel) -> ModelState {
        states[model] ?? .notInstalled
    }

    func downloadAndUse(_ model: TranscriptionModel) async {
        guard !actionsLocked, downloadTask == nil else { return }

        let previousState = state(for: model)
        let id = UUID()
        operationID = id
        isPreparingModel = true
        states[model] = .downloading(0)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performDownload(model, previousState: previousState, id: id)
        }
        downloadTask = task
        await task.value
    }

    func cancel() {
        downloadTask?.cancel()
    }

    func activate(_ model: TranscriptionModel) {
        guard !actionsLocked, !isPreparingModel, state(for: model) == .installed else {
            return
        }

        do {
            try operations.persist(model)
            finishActivation(model)
        } catch {
            states[model] = .failed(error.localizedDescription)
        }
    }

    private func performDownload(
        _ model: TranscriptionModel,
        previousState: ModelState,
        id: UUID
    ) async {
        do {
            try await operations.downloadAndVerify(
                model,
                { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.receiveProgress(progress, for: model, id: id)
                    }
                },
                { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.beginVerification(for: model, id: id)
                    }
                }
            )
            try Task.checkCancellation()
            try operations.persist(model)
            guard operationID == id else { return }
            finishActivation(model)
        } catch is CancellationError {
            if operationID == id {
                states[model] = restoredState(previousState, for: model)
            }
        } catch {
            if operationID == id {
                states[model] = .failed(error.localizedDescription)
            }
        }

        if operationID == id {
            operationID = nil
            downloadTask = nil
            isPreparingModel = false
        }
    }

    private func receiveProgress(
        _ incoming: Double,
        for model: TranscriptionModel,
        id: UUID
    ) {
        guard operationID == id, case .downloading(let current) = state(for: model) else {
            return
        }
        states[model] = .downloading(max(current, min(max(incoming, 0), 1)))
    }

    private func beginVerification(for model: TranscriptionModel, id: UUID) {
        guard operationID == id, case .downloading = state(for: model) else { return }
        states[model] = .verifying
    }

    private func finishActivation(_ model: TranscriptionModel) {
        if model != activeModel {
            states[activeModel] = operations.isInstalled(activeModel)
                ? .installed
                : .notInstalled
        }
        activeModel = model
        states[model] = .active
        onActivation()
    }

    private func restoredState(
        _ previousState: ModelState,
        for model: TranscriptionModel
    ) -> ModelState {
        switch previousState {
        case .installed, .active:
            return previousState
        default:
            return operations.isInstalled(model) ? .installed : .notInstalled
        }
    }
}
