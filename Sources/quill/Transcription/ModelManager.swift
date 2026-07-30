import Combine
import Foundation

enum ModelState: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case verifying
    case installed
    case active
    case failed(String)
    case activationFailed(String)
}

@MainActor
final class ModelManager: ObservableObject {
    struct Operations: Sendable {
        var isInstalled: @Sendable (TranscriptionModel) async throws -> Bool
        var downloadAndVerify:
            @Sendable (
                TranscriptionModel,
                @escaping @Sendable (Double) -> Void,
                @escaping @Sendable () -> Void
            ) async throws -> Void
        var persist: @MainActor @Sendable (TranscriptionModel) throws -> Void

        static let live = Operations(
            isInstalled: { try await ModelStore.shared.isInstalled($0) },
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
    private var stateVersions: [TranscriptionModel: Int]
    private var resolvedModels: Set<TranscriptionModel> = []

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

        self.states = Dictionary(
            uniqueKeysWithValues: TranscriptionModel.allCases.map { ($0, .notInstalled) }
        )
        self.stateVersions = Dictionary(
            uniqueKeysWithValues: TranscriptionModel.allCases.map { ($0, 0) }
        )

        Task { [weak self] in
            await self?.refreshInstallationStates()
        }
    }

    func state(for model: TranscriptionModel) -> ModelState {
        states[model] ?? .notInstalled
    }

    func refreshInstallationStates() async {
        for model in TranscriptionModel.allCases {
            await refreshInstallationState(for: model)
        }
    }

    func downloadAndUse(_ model: TranscriptionModel) async {
        guard !actionsLocked, downloadTask == nil else { return }

        let previousState = state(for: model)
        let wasResolved = resolvedModels.contains(model)
        let id = UUID()
        operationID = id
        isPreparingModel = true
        setState(.downloading(0), for: model)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performDownload(
                model,
                previousState: previousState,
                wasResolved: wasResolved,
                id: id
            )
        }
        downloadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancel() {
        downloadTask?.cancel()
    }

    func activate(_ model: TranscriptionModel) {
        guard !actionsLocked, !isPreparingModel else {
            return
        }
        switch state(for: model) {
        case .installed, .activationFailed:
            break
        default:
            return
        }

        do {
            try operations.persist(model)
            finishActivation(model)
        } catch {
            setState(.activationFailed(error.localizedDescription), for: model)
        }
    }

    private func performDownload(
        _ model: TranscriptionModel,
        previousState: ModelState,
        wasResolved: Bool,
        id: UUID
    ) async {
        var shouldRefresh = false
        var verificationSucceeded = false
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
            verificationSucceeded = true
        } catch is CancellationError {
            if operationID == id {
                setState(restoredState(previousState), for: model)
                if case .failed = previousState {
                    shouldRefresh = true
                } else {
                    shouldRefresh = !wasResolved
                }
            }
        } catch {
            if operationID == id {
                setState(.failed(error.localizedDescription), for: model)
            }
        }

        if verificationSucceeded, operationID == id {
            do {
                try operations.persist(model)
                finishActivation(model)
            } catch {
                setState(.activationFailed(error.localizedDescription), for: model)
            }
        }

        if operationID == id {
            operationID = nil
            downloadTask = nil
            isPreparingModel = false
        }
        if shouldRefresh {
            let refreshTask = Task {
                await refreshInstallationState(for: model)
            }
            await refreshTask.value
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
        setState(.downloading(max(current, min(max(incoming, 0), 1))), for: model)
    }

    private func beginVerification(for model: TranscriptionModel, id: UUID) {
        guard operationID == id, case .downloading = state(for: model) else { return }
        setState(.verifying, for: model)
    }

    private func finishActivation(_ model: TranscriptionModel) {
        if model != activeModel {
            if state(for: activeModel) == .active {
                setState(.installed, for: activeModel)
            }
        }
        activeModel = model
        setState(.active, for: model)
        onActivation()
    }

    private func restoredState(_ previousState: ModelState) -> ModelState {
        switch previousState {
        case .installed, .active:
            return previousState
        case .activationFailed:
            return .installed
        default:
            return .notInstalled
        }
    }

    private func refreshInstallationState(for model: TranscriptionModel) async {
        guard isPassive(state(for: model)) else { return }
        let version = stateVersions[model, default: 0]
        let installed: Bool
        do {
            installed = try await operations.isInstalled(model)
        } catch {
            return
        }
        guard stateVersions[model, default: 0] == version,
              isPassive(state(for: model))
        else { return }
        setState(
            installed ? (model == activeModel ? .active : .installed) : .notInstalled,
            for: model
        )
        resolvedModels.insert(model)
    }

    private func isPassive(_ state: ModelState) -> Bool {
        switch state {
        case .notInstalled, .installed, .active:
            true
        case .downloading, .verifying, .failed, .activationFailed:
            false
        }
    }

    private func setState(_ state: ModelState, for model: TranscriptionModel) {
        stateVersions[model, default: 0] += 1
        states[model] = state
    }
}
