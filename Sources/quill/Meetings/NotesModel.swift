import Combine
import Foundation

enum NotesModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case qwen35_2B = "qwen3.5-2b-q4_k_m"
    case smolLM3_3B = "smollm3-3b-q4_k_m"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .qwen35_2B: "Qwen3.5 2B"
        case .smolLM3_3B: "SmolLM3 3B"
        }
    }
    var detail: String { "Q4_K_M · local meeting notes" }
    var downloadBytes: Int64 { artifact.bytes }
    var downloadSize: String { ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .file) }

    /// Immutable GGUF revisions and LFS SHA-256 values verified against each
    /// quantization publisher's Hugging Face API on 2026-09-07. Both model
    /// licenses are Apache-2.0. The Qwen quant is published by the LM Studio
    /// team; using it does not require or install LM Studio.
    var artifact: NotesArtifact {
        switch self {
        case .qwen35_2B:
            NotesArtifact(
                url: URL(string: "https://huggingface.co/lmstudio-community/Qwen3.5-2B-GGUF/resolve/bb84e11355a036e28f080c7793fa6d22b7c4e344/Qwen3.5-2B-Q4_K_M.gguf")!,
                filename: "Qwen3.5-2B-Q4_K_M.gguf", bytes: 1_270_808_032,
                sha256: "0bfe35afc9f05b7fac3fa04925e051ac7939a42a8a17ea11afc99701bea826cc")
        case .smolLM3_3B:
            NotesArtifact(
                url: URL(string: "https://huggingface.co/ggml-org/SmolLM3-3B-GGUF/resolve/4965cb60b150737b68a0408c36aeefb65078f894/SmolLM3-Q4_K_M.gguf")!,
                filename: "SmolLM3-Q4_K_M.gguf", bytes: 1_915_305_312,
                sha256: "8334b850b7bd46238c16b0c550df2138f0889bf433809008cc17a8b05761863e")
        }
    }
    var sourceURL: URL {
        switch self {
        case .qwen35_2B: URL(string: "https://huggingface.co/lmstudio-community/Qwen3.5-2B-GGUF")!
        case .smolLM3_3B: URL(string: "https://huggingface.co/ggml-org/SmolLM3-3B-GGUF")!
        }
    }
}

struct NotesArtifact: Sendable {
    let url: URL
    let filename: String
    let bytes: Int64
    let sha256: String
}

enum NotesModelSettings {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("quill/notes", isDirectory: true)
    }

    static func selectedModel() -> NotesModel {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("selection.json")),
              let model = try? JSONDecoder().decode(NotesModel.self, from: data) else { return .qwen35_2B }
        return model
    }

    static func select(_ model: NotesModel) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(model).write(to: root.appendingPathComponent("selection.json"), options: .atomic)
    }
}

@MainActor
final class NotesModelManager: ObservableObject {
    static let shared = NotesModelManager()

    struct Operations: Sendable {
        var isInstalled: @Sendable (NotesModel) async -> Bool
        var download: @Sendable (NotesModel, @escaping @Sendable (Double) -> Void,
                                 @escaping @Sendable () -> Void) async throws -> Void
        var persist: @MainActor @Sendable (NotesModel) throws -> Void

        static let live = Operations(
            isInstalled: { await NotesArtifactStore.shared.isInstalled($0) },
            download: { model, progress, verifying in
                try await NotesArtifactStore.shared.download(model, progress: progress, verifying: verifying)
            },
            persist: { try NotesModelSettings.select($0) })
    }

    @Published private(set) var activeModel: NotesModel
    @Published private(set) var states: [NotesModel: ModelState]
    @Published private(set) var isPreparingModel = false
    @Published var actionsLocked: Bool
    private let operations: Operations
    private let onActivation: @MainActor @Sendable () -> Void
    private var downloadTask: Task<Void, Never>?
    private var operationID: UUID?
    private var stateVersions: [NotesModel: Int]

    init(activeModel: NotesModel = NotesModelSettings.selectedModel(), actionsLocked: Bool = false,
         operations: Operations = .live, onActivation: @escaping @MainActor @Sendable () -> Void = {}) {
        self.activeModel = activeModel
        self.actionsLocked = actionsLocked
        self.operations = operations
        self.onActivation = onActivation
        states = Dictionary(uniqueKeysWithValues: NotesModel.allCases.map { ($0, .notInstalled) })
        stateVersions = Dictionary(uniqueKeysWithValues: NotesModel.allCases.map { ($0, 0) })
        Task { [weak self] in await self?.refreshInstallationStates() }
    }

    func state(for model: NotesModel) -> ModelState { states[model] ?? .notInstalled }

    func refreshInstallationStates() async {
        guard !isPreparingModel else { return }
        for model in NotesModel.allCases {
            let version = stateVersions[model]
            let installed = await operations.isInstalled(model)
            guard !isPreparingModel else { return }
            guard stateVersions[model] == version else { continue }
            setState(installed ? (model == activeModel ? .active : .installed) : .notInstalled, for: model)
        }
    }

    func downloadAndUse(_ model: NotesModel) async {
        guard !actionsLocked, downloadTask == nil else { return }
        let previous = state(for: model)
        let id = UUID()
        operationID = id
        isPreparingModel = true
        setState(.downloading(0), for: model)
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.isPreparingModel = false; self.downloadTask = nil; self.operationID = nil }
            do {
                try await self.operations.download(model, { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.isPreparingModel, self.operationID == id else { return }
                        guard case .downloading(let previous) = self.state(for: model) else { return }
                        self.setState(.downloading(max(previous, min(1, max(0, fraction)))), for: model)
                    }
                }, { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.isPreparingModel, self.operationID == id else { return }
                        self.setState(.verifying, for: model)
                    }
                })
                try Task.checkCancellation()
                self.setState(.installed, for: model)
                do {
                    try self.operations.persist(model)
                    self.finishActivation(model)
                } catch { self.setState(.activationFailed(error.localizedDescription), for: model) }
            } catch is CancellationError {
                self.setState(previous, for: model)
            } catch { self.setState(.failed(error.localizedDescription), for: model) }
        }
        downloadTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func cancel() { downloadTask?.cancel() }

    func activate(_ model: NotesModel) {
        guard !actionsLocked, !isPreparingModel else { return }
        switch state(for: model) {
        case .installed, .activationFailed: break
        default: return
        }
        do {
            try operations.persist(model)
            finishActivation(model)
        } catch { setState(.activationFailed(error.localizedDescription), for: model) }
    }

    private func finishActivation(_ model: NotesModel) {
        if activeModel != model, states[activeModel] == .active { setState(.installed, for: activeModel) }
        activeModel = model
        setState(.active, for: model)
        onActivation()
    }

    private func setState(_ state: ModelState, for model: NotesModel) {
        states[model] = state
        stateVersions[model, default: 0] += 1
    }
}
