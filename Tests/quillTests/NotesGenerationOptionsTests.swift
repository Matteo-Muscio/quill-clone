import Foundation
import XCTest
@testable import quill

final class NotesGenerationOptionsTests: XCTestCase {
    func testPartialExperimentJSONPreservesUnspecifiedProductionDefaults() throws {
        let options = try JSONDecoder().decode(NotesGenerationOptions.self, from: Data(
            #"{"stageOverrides":{"verification":{"temperature":0.2,"thinkingBudget":512}}}"#.utf8))
        XCTAssertEqual(options.contextTokens, 8192)
        XCTAssertEqual(options.outputTokens, 2200)
        XCTAssertEqual(options.seed, 42)
        XCTAssertEqual(options.options(for: .direct), NotesCompletionOptions())
        XCTAssertEqual(options.options(for: .verification).temperature, 0.2)
        XCTAssertEqual(options.options(for: .verification).thinkingBudget, 512)
        XCTAssertNoThrow(try options.validate(for: .qwen35_4B))
        let roundtrip = try JSONDecoder().decode(NotesGenerationOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(roundtrip.options(for: .verification), options.options(for: .verification))
    }

    func testStageSamplingOverridesMergeWithoutChangingOtherStages() {
        let options = NotesGenerationOptions(seed: 99,
            defaultCompletion: .init(temperature: 0.4, topP: 0.9, topK: 30, thinkingBudget: 512),
            stageOverrides: ["rendering": .init(temperature: 0.1, seed: 7)])
        XCTAssertEqual(options.options(for: .extraction).thinkingBudget, 512)
        let rendering = options.options(for: .rendering)
        XCTAssertEqual(rendering.temperature, 0.1)
        XCTAssertEqual(rendering.topP, 0.9)
        XCTAssertEqual(rendering.topK, 30)
        XCTAssertEqual(rendering.seed, 7)
        XCTAssertEqual(rendering.thinkingBudget, 0)
        XCTAssertEqual(value("--seed", in: arguments(options, stage: .extraction)), "99")
        XCTAssertEqual(value("--seed", in: arguments(options, stage: .rendering)), "7")
    }

    func testPackingReservesLargestStageThinkingAndEntireFinalOutput() {
        let options = NotesGenerationOptions(contextTokens: 12288, outputTokens: 3000,
            stageOverrides: ["extraction": .init(thinkingBudget: 512), "verification": .init(thinkingBudget: 2048)])
        XCTAssertEqual(options.maximumPromptTokens, 12288 - 3000 - 2048 - 200)
        XCTAssertEqual(NotesGenerationOptions.defaults.maximumPromptTokens, 5792)
    }

    func testRejectsUnsafeBudgetsSamplingAndUnsupportedThinkingModels() {
        for options in [
            NotesGenerationOptions(contextTokens: 1024, outputTokens: 2200),
            NotesGenerationOptions(defaultCompletion: .init(thinkingBudget: -1)),
            NotesGenerationOptions(defaultCompletion: .init(thinkingBudget: Int.max)),
            NotesGenerationOptions(defaultCompletion: .init(thinkingBudget: 500)),
            NotesGenerationOptions(defaultCompletion: .init(temperature: .nan)),
            NotesGenerationOptions(defaultCompletion: .init(topP: 0)),
            NotesGenerationOptions(defaultCompletion: .init(topK: -1)),
            NotesGenerationOptions(stageOverrides: ["typo": .init()]),
        ] {
            XCTAssertThrowsError(try options.validate(for: .qwen35_4B))
        }
        let thinking = NotesGenerationOptions(defaultCompletion: .init(thinkingBudget: 512))
        XCTAssertThrowsError(try thinking.validate(for: .qwen35_2B))
        XCTAssertThrowsError(try thinking.validate(for: .smolLM3_3B))
        XCTAssertNoThrow(try NotesGenerationOptions.defaults.validate(for: .smolLM3_3B))
    }

    func testRejectsRandomSeedSentinelAtEveryOverrideLevel() throws {
        for options in [
            NotesGenerationOptions(seed: UInt32.max),
            NotesGenerationOptions(defaultCompletion: .init(seed: UInt32.max)),
            NotesGenerationOptions(stageOverrides: ["verification": .init(seed: UInt32.max)]),
        ] {
            XCTAssertThrowsError(try options.validate(for: .qwen35_4B))
        }
        for seed in [UInt32(0), UInt32(42), UInt32.max - 1] {
            XCTAssertNoThrow(try NotesGenerationOptions(seed: seed,
                defaultCompletion: .init(seed: seed),
                stageOverrides: ["verification": .init(seed: seed)]).validate(for: .qwen35_4B))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(NotesGenerationOptions.self, from: Data(#"{"seed":-1}"#.utf8)))
    }

    func testThinkingPassHasHardGenerationCapAndNoJSONGrammarUntilFinalPass() {
        for budget in [512, 2048] {
            let options = NotesGenerationOptions(defaultCompletion: .init(temperature: 0.3, thinkingBudget: budget))
            let thinking = arguments(options, thinking: true)
            XCTAssertEqual(value("--predict", in: thinking), String(budget))
            XCTAssertEqual(value("--reverse-prompt", in: thinking), "</think>")
            XCTAssertEqual(value("--temp", in: thinking), "0.3")
            XCTAssertTrue(thinking.contains("--special"))
            XCTAssertTrue(thinking.contains("--offline"))
            XCTAssertTrue(thinking.contains("--no-context-shift"))
            XCTAssertFalse(thinking.contains("--json-schema-file"))
            XCTAssertFalse(thinking.contains("--reasoning-budget"))
            let final = arguments(options)
            XCTAssertEqual(value("--predict", in: final), "2200")
            XCTAssertTrue(final.contains("--json-schema-file"))
            XCTAssertFalse(final.contains("--reverse-prompt"))
            XCTAssertFalse(final.contains("--special"))
        }
    }

    func testOmittedOptionsPreserveExactBaselineArguments() {
        let args = arguments(.defaults)
        XCTAssertEqual(args, ["-m", "/model.gguf", "-f", "/prompt.txt",
            "--ctx-size", "8192", "--predict", "2200", "--threads", "4", "--batch-size", "512",
            "--ubatch-size", "128", "--gpu-layers", "all", "--seed", "42", "--no-conversation",
            "--no-display-prompt", "--no-escape", "--no-context-shift", "--no-warmup", "--simple-io", "--offline",
            "--json-schema-file", "/schema.json"] + NotesPromptFormat.samplingArguments(for: .qwen35_4B))
    }

    private func arguments(_ options: NotesGenerationOptions, stage: NotesGenerationStage = .direct,
                           thinking: Bool = false) -> [String] {
        MeetingNotesEngine.arguments(modelURL: URL(fileURLWithPath: "/model.gguf"),
            promptURL: URL(fileURLWithPath: "/prompt.txt"), schemaURL: URL(fileURLWithPath: "/schema.json"),
            model: .qwen35_4B, options: options, stage: stage, thinkingPass: thinking)
    }

    private func value(_ key: String, in args: [String]) -> String? {
        args.firstIndex(of: key).map { args[$0 + 1] }
    }
}
