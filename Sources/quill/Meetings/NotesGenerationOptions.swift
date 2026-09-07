import Foundation

enum NotesGenerationStage: String, Codable, CaseIterable, Sendable {
    case extraction, verification, selection, rendering, direct
}

/// Internal experiment inputs, never persisted as application settings.
struct NotesCompletionOptions: Codable, Sendable, Equatable {
    var temperature: Double? = nil
    var topP: Double? = nil
    var topK: Int? = nil
    var seed: UInt32? = nil
    var thinkingBudget: Int = 0

    init(temperature: Double? = nil, topP: Double? = nil, topK: Int? = nil,
         seed: UInt32? = nil, thinkingBudget: Int = 0) {
        self.temperature = temperature; self.topP = topP; self.topK = topK
        self.seed = seed; self.thinkingBudget = thinkingBudget
    }

    private enum CodingKeys: String, CodingKey { case temperature, topP, topK, seed, thinkingBudget }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        temperature = try values.decodeIfPresent(Double.self, forKey: .temperature)
        topP = try values.decodeIfPresent(Double.self, forKey: .topP)
        topK = try values.decodeIfPresent(Int.self, forKey: .topK)
        seed = try values.decodeIfPresent(UInt32.self, forKey: .seed)
        thinkingBudget = try values.decodeIfPresent(Int.self, forKey: .thinkingBudget) ?? 0
    }
}

struct NotesGenerationOptions: Codable, Sendable {
    var contextTokens: Int = 8192
    var outputTokens: Int = 2200
    var seed: UInt32 = 42
    var defaultCompletion = NotesCompletionOptions()
    /// String keys keep experiment JSON readable; validation rejects unknown stages.
    var stageOverrides: [String: NotesCompletionOptions] = [:]
    var verification = MeetingNotesVerifiedPipeline.Options()

    static let defaults = NotesGenerationOptions()

    init(contextTokens: Int = 8192, outputTokens: Int = 2200, seed: UInt32 = 42,
         defaultCompletion: NotesCompletionOptions = .init(),
         stageOverrides: [String: NotesCompletionOptions] = [:],
         verification: MeetingNotesVerifiedPipeline.Options = .init()) {
        self.contextTokens = contextTokens; self.outputTokens = outputTokens; self.seed = seed
        self.defaultCompletion = defaultCompletion; self.stageOverrides = stageOverrides
        self.verification = verification
    }

    private enum CodingKeys: String, CodingKey {
        case contextTokens, outputTokens, seed, defaultCompletion, stageOverrides, verification
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        contextTokens = try values.decodeIfPresent(Int.self, forKey: .contextTokens) ?? 8192
        outputTokens = try values.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 2200
        seed = try values.decodeIfPresent(UInt32.self, forKey: .seed) ?? 42
        defaultCompletion = try values.decodeIfPresent(NotesCompletionOptions.self, forKey: .defaultCompletion) ?? .init()
        stageOverrides = try values.decodeIfPresent([String: NotesCompletionOptions].self, forKey: .stageOverrides) ?? [:]
        verification = try values.decodeIfPresent(MeetingNotesVerifiedPipeline.Options.self, forKey: .verification) ?? .init()
    }

    func options(for stage: NotesGenerationStage) -> NotesCompletionOptions {
        guard let override = stageOverrides[stage.rawValue] else { return defaultCompletion }
        return NotesCompletionOptions(
            temperature: override.temperature ?? defaultCompletion.temperature,
            topP: override.topP ?? defaultCompletion.topP,
            topK: override.topK ?? defaultCompletion.topK,
            seed: override.seed ?? defaultCompletion.seed,
            thinkingBudget: override.thinkingBudget)
    }

    var maximumThinkingTokens: Int {
        NotesGenerationStage.allCases.map { options(for: $0).thinkingBudget }.max() ?? 0
    }

    /// Reserve reasoning, the complete final answer, and delimiter/tokenizer slack.
    /// The same conservative limit applies to every pipeline packing operation.
    var maximumPromptTokens: Int { contextTokens - outputTokens - maximumThinkingTokens - 200 }

    func validate(for model: NotesModel) throws {
        guard (1024...32768).contains(contextTokens), (128...8192).contains(outputTokens),
              seed != UInt32.max,
              stageOverrides.keys.allSatisfy({ NotesGenerationStage(rawValue: $0) != nil }) else {
            throw MeetingNotesError.invalidGenerationOptions
        }
        for value in [defaultCompletion] + Array(stageOverrides.values) {
            // b10837 LLAMA_DEFAULT_SEED (0xFFFFFFFF) requests random seeding,
            // rather than a reproducible explicit seed for the comparison.
            guard [0, 512, 2048].contains(value.thinkingBudget),
                  value.seed != UInt32.max,
                  value.thinkingBudget == 0 || model == .qwen35_4B,
                  value.temperature.map({ $0.isFinite && (0...2).contains($0) }) ?? true,
                  value.topP.map({ $0.isFinite && $0 > 0 && $0 <= 1 }) ?? true,
                  value.topK.map({ (0...1000).contains($0) }) ?? true else {
                throw MeetingNotesError.invalidGenerationOptions
            }
        }
        guard maximumPromptTokens >= 256 else { throw MeetingNotesError.invalidGenerationOptions }
    }
}
