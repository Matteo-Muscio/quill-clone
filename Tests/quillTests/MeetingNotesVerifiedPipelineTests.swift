import Foundation
import XCTest
@testable import quill

final class MeetingNotesVerifiedPipelineTests: XCTestCase {
    typealias Pipeline = MeetingNotesVerifiedPipeline
    typealias Base = MeetingNotesEvidencePipeline

    private actor Worker {
        var outputs: [Data]
        var stages: [NotesGenerationStage] = []
        var prompts: [String] = []
        var cancelled: Bool
        init(_ outputs: [String], cancelled: Bool = false) {
            self.outputs = outputs.map { Data($0.utf8) }
            self.cancelled = cancelled
        }
        func complete(_ prompt: String, _ schema: String, _ stage: NotesGenerationStage) throws -> Data {
            stages.append(stage); prompts.append(prompt)
            if cancelled { throw CancellationError() }
            guard !outputs.isEmpty else { throw MeetingNotesError.invalidOutput }
            return outputs.removeFirst()
        }
        func runner() -> Base.Runner {
            .init(countTokens: { _ in 100 }, complete: { prompt, schema, stage in
                try await self.complete(prompt, schema, stage)
            })
        }
        func snapshot() -> ([NotesGenerationStage], [String]) { (stages, prompts) }
    }

    private let transcript = """
    [00:01] Alex: I will send the report tomorrow.
    [00:02] Bea: The quantity is unclear.
    """
    private let extraction = #"{"facts":[{"kind":"action","text":"Alex will send the report tomorrow.","spans":[{"sourceID":"line-1","quote":"I will send the report tomorrow."}],"actor":"Alex","date":"tomorrow","quantity":null,"uncertainFields":[]},{"kind":"observation","text":"The quantity is unclear.","spans":[{"sourceID":"line-2","quote":"The quantity is unclear."}],"actor":null,"date":null,"quantity":null,"uncertainFields":["quantity"]}]}"#
    private let factReview = #"{"verdicts":[{"id":"fact-1","verdict":"supported","sourceIDs":["line-1"],"reason":"Explicit commitment."},{"id":"fact-2","verdict":"unclear","sourceIDs":["line-2"],"reason":"The quantity remains unknown."}]}"#
    private let rendering = #"{"title":"Report planning","summary":[],"keyTakeaways":[{"text":"The quantity remains unclear.","factIDs":["fact-2"]}],"actionItems":[{"text":"Alex will send the report tomorrow.","factIDs":["fact-1"]}]}"#
    private let claimReview = #"{"verdicts":[{"id":"title","verdict":"supported","sourceIDs":["line-1"],"reason":"Neutral topic."},{"id":"keyTakeaway-0","verdict":"supported","sourceIDs":["line-2"],"reason":"Qualification reflects the source."},{"id":"actionItem-0","verdict":"supported","sourceIDs":["line-1"],"reason":"Explicit commitment."}]}"#

    func testCleanCommitmentAndQualifiedUncertaintySurviveBothChecks() async throws {
        let worker = Worker([extraction, factReview, rendering, claimReview])
        let notes = try await Pipeline(model: .qwen35_4B, language: "English", runner: await worker.runner())
            .generate(transcript: transcript, progress: { _ in })
        let (stages, prompts) = await worker.snapshot()
        XCTAssertEqual(stages, [.extraction, .verification, .rendering, .verification])
        XCTAssertEqual(notes.title, "Report planning")
        XCTAssertEqual(notes.actionItems, ["Alex will send the report tomorrow."])
        XCTAssertEqual(notes.keyTakeaways, ["The quantity remains unclear."])
        XCTAssertEqual(notes.sources?.map(\.id), ["line-1", "line-2"])
        XCTAssertTrue(prompts[1].contains("ORIGINAL SOURCES AND CONTEXT"))
        XCTAssertTrue(prompts[1].contains("I will send the report tomorrow."))
        XCTAssertTrue(prompts[2].contains("unclear"))
        XCTAssertTrue(prompts[3].contains("keyTakeaway-0"))
    }

    func testFabricatedSpansAndSourceIDsAreRejected() {
        let sources = Base.sources(in: transcript)
        let candidates = [
            Pipeline.Candidate(kind: .action, text: "A claim.", spans: [.init(sourceID: "line-1", quote: "I have already sent the report.")], uncertainFields: []),
            Pipeline.Candidate(kind: .action, text: "A claim.", spans: [.init(sourceID: "line-404", quote: "I will send the report tomorrow.")], uncertainFields: []),
            Pipeline.Candidate(kind: .action, text: "A claim.", spans: [.init(sourceID: "line-1", quote: "[00:01] Alex: ")], uncertainFields: [])
        ]
        XCTAssertEqual(Pipeline.validate(candidates, sources: sources, coreIDs: ["line-1"]).count, 0)
    }

    func testUnknownFieldsPreserveNarrowerTextAndUnsupportedOwnerIsNotTrusted() throws {
        let sources = Base.sources(in: transcript)
        let candidate = Pipeline.Candidate(kind: .action, text: "The report will be sent.",
            spans: [.init(sourceID: "line-1", quote: sources[0].text)], actor: "The manager", date: nil,
            quantity: "five copies", uncertainFields: [])
        let fact = try XCTUnwrap(Pipeline.validate([candidate], sources: sources, coreIDs: ["line-1"]).first)
        XCTAssertEqual(fact.text, "The report will be sent.")
        XCTAssertNil(fact.actor)
        XCTAssertNil(fact.date)
        XCTAssertNil(fact.quantity)
        XCTAssertTrue(fact.uncertainFields.contains(.actor))
        XCTAssertTrue(fact.uncertainFields.contains(.quantity))
        XCTAssertEqual(fact.spans.first?.quote, sources[0].spoken)
    }

    func testVerifierCannotInventVerdictIDsOrClaimSupportFromDifferentSources() throws {
        let sources = Base.sources(in: transcript)
        let extraction: Pipeline.Extraction = try Base.decode(Data(self.extraction.utf8))
        var fact = try XCTUnwrap(Pipeline.validate(extraction.facts, sources: sources, coreIDs: ["line-1", "line-2"]).first)
        fact.id = "fact-1"
        let target = Pipeline.target(fact)
        for decision in [
            Pipeline.Decision(id: "fact-404", verdict: .supported, sourceIDs: ["line-1"], reason: "Invented ID"),
            Pipeline.Decision(id: "fact-1", verdict: .supported, sourceIDs: ["line-404"], reason: "Invented source"),
            Pipeline.Decision(id: "fact-1", verdict: .supported, sourceIDs: ["line-2"], reason: "Different proposition"),
            Pipeline.Decision(id: "fact-1", verdict: .supported, sourceIDs: [], reason: "No evidence")
        ] {
            XCTAssertThrowsError(try Pipeline.validate(.init(verdicts: [decision]), targets: [target], sources: sources))
        }
        let contradiction = Pipeline.Decision(id: "fact-1", verdict: .contradicted, sourceIDs: ["line-2"], reason: "Nearby correction")
        XCTAssertNoThrow(try Pipeline.validate(.init(verdicts: [contradiction]), targets: [target], sources: sources))
        XCTAssertThrowsError(try Pipeline.validate(.init(verdicts: [contradiction, contradiction]), targets: [target], sources: sources))
    }

    func testLocalContextIncludesReplyAndCanBeDisabledForAblation() {
        let sources = Base.sources(in: "[00:01] Alex: Send it Friday.\n[00:02] Bea: No, Monday instead.\n[00:03] Alex: Agreed.")
        let runner = Base.Runner(countTokens: { _ in 0 }, complete: { _, _, _ in Data() })
        var pipeline = Pipeline(model: .qwen35_4B, runner: runner)
        XCTAssertEqual(pipeline.context(core: [sources[0]], all: sources).map(\.id), ["line-1", "line-2"])
        pipeline.options.includeContext = false
        XCTAssertEqual(pipeline.context(core: [sources[0]], all: sources).map(\.id), ["line-1"])
    }

    func testContradictedFactsDropAndUnclearFactsAreRetainedWithoutReplacement() throws {
        let sources = Base.sources(in: transcript)
        let extraction: Pipeline.Extraction = try Base.decode(Data(self.extraction.utf8))
        var facts = Pipeline.validate(extraction.facts, sources: sources, coreIDs: ["line-1", "line-2"])
        facts[0].id = "fact-1"; facts[1].id = "fact-2"
        let decisions = [Pipeline.Decision(id: "fact-1", verdict: .contradicted, sourceIDs: ["line-1"], reason: "Diagnostic text must not replace the fact."),
                         Pipeline.Decision(id: "fact-2", verdict: .unclear, sourceIDs: ["line-2"], reason: "Try a different quantity.")]
        let accepted = Pipeline.applying(decisions, to: facts)
        XCTAssertEqual(accepted.map(\.text), [facts[1].text])
        XCTAssertEqual(accepted.first?.spans, facts[1].spans)
        XCTAssertTrue(accepted[0].uncertainFields.contains(.meaning))
    }

    func testFinalCheckRemovesUnsupportedOwnerAndUsesNeutralTitle() {
        let draft = Base.Rendering(title: "Manager diagnosis", summary: [],
            keyTakeaways: [.init(text: "The quantity remains unclear.", factIDs: ["fact-2"])],
            actionItems: [.init(text: "The manager will send it.", factIDs: ["fact-1"])])
        let decisions = [Pipeline.Decision(id: "title", verdict: .unclear, sourceIDs: [], reason: "Unknown role."),
                         Pipeline.Decision(id: "keyTakeaway-0", verdict: .supported, sourceIDs: ["line-2"], reason: "Accurate uncertainty."),
                         Pipeline.Decision(id: "actionItem-0", verdict: .unclear, sourceIDs: ["line-1"], reason: "Unknown owner.")]
        let accepted = Pipeline.applying(decisions, to: draft, neutralTitle: "Meeting notes")
        XCTAssertEqual(accepted.title, "Meeting notes")
        XCTAssertEqual(accepted.actionItems.count, 0)
        XCTAssertEqual(accepted.keyTakeaways.map(\.text), ["The quantity remains unclear."])
    }

    func testUnclearActionDoesNotSuppressTheSameQualifiedTakeaway() throws {
        let fact = Pipeline.Fact(id: "fact-1", kind: .action, text: "The requested check is unclear.",
            spans: [.init(sourceID: "line-1", quote: "Please check the unclear part.")],
            uncertainFields: [.meaning], verdict: .unclear)
        let claim = Base.Claim(text: fact.text, factIDs: [fact.id])
        let draft = Base.Rendering(title: "Requested check", summary: [], keyTakeaways: [claim], actionItems: [claim])
        let accepted = try Pipeline.validate(draft, facts: [fact])
        XCTAssertTrue(accepted.actionItems.isEmpty)
        XCTAssertEqual(accepted.keyTakeaways.map(\.text), [fact.text])

        var oversized = draft
        oversized.actionItems = Array(repeating: claim, count: 7)
        XCTAssertThrowsError(try Pipeline.validate(oversized, facts: [fact]))
        var invalidTitle = draft
        invalidTitle.title = ""
        XCTAssertThrowsError(try Pipeline.validate(invalidTitle, facts: [fact]))
    }

    func testOldExtractionAndDisabledVerificationAreAvailableForAblation() async throws {
        let old = #"{"facts":[{"kind":"action","text":"Alex will send the report tomorrow.","sourceIDs":["line-1"]}]}"#
        let rendered = #"{"title":"Report","summary":[],"keyTakeaways":[],"actionItems":[{"text":"Alex will send the report tomorrow.","factIDs":["fact-1"]}]}"#
        let worker = Worker([old, rendered])
        let options = Pipeline.Options(atomicExtraction: false, verifyFacts: false, verifyClaims: false, includeContext: false)
        let notes = try await Pipeline(model: .qwen35_4B, language: "English", runner: await worker.runner(), options: options)
            .generate(transcript: transcript, progress: { _ in })
        let (stages, prompts) = await worker.snapshot()
        XCTAssertEqual(stages, [.extraction, .rendering])
        XCTAssertFalse(prompts[0].contains("atomic statements"))
        XCTAssertEqual(notes.actionItems, ["Alex will send the report tomorrow."])
    }

    func testCancelledExtractionStartsNoVerifier() async throws {
        let worker = Worker([], cancelled: true)
        do {
            _ = try await Pipeline(model: .qwen35_4B, runner: await worker.runner())
                .generate(transcript: transcript, progress: { _ in })
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertTrue(error is CancellationError) }
        let (stages, _) = await worker.snapshot()
        XCTAssertEqual(stages, [.extraction])
    }

    func testPartialAblationJSONRetainsDefaultExtractionAndContext() throws {
        let options = try JSONDecoder().decode(NotesGenerationOptions.self,
            from: Data(#"{"verification":{"verifyFacts":false,"verifyClaims":false}}"#.utf8))
        XCTAssertTrue(options.verification.atomicExtraction)
        XCTAssertTrue(options.verification.includeContext)
        XCTAssertFalse(options.verification.verifyFacts)
        XCTAssertFalse(options.verification.verifyClaims)
    }

    func testNumericPunctuationIsPreservedAndRepeatedSupportIsMerged() throws {
        let first = Pipeline.Fact(id: "fact-1", kind: .observation, text: "The amount is 1.5 units.",
            spans: [.init(sourceID: "line-1", quote: "The amount is 1.5 units.")], uncertainFields: [], verdict: .supported)
        var repeated = first
        repeated.id = "fact-2"
        repeated.text = "THE amount is 1.5 units."
        repeated.spans = [.init(sourceID: "line-2", quote: "I confirm the amount is 1.5 units.")]
        var distinct = first
        distinct.id = "fact-3"; distinct.text = "The amount is 15 units."
        distinct.spans = [.init(sourceID: "line-3", quote: "The amount is 15 units.")]
        let facts = Pipeline.deduplicated([first, repeated, distinct])
        XCTAssertEqual(facts.count, 2)
        XCTAssertEqual(facts[0].spans.count, 2)
        let draft = Base.Rendering(title: "Amounts", summary: [],
            keyTakeaways: [.init(text: first.text, factIDs: ["fact-1"]), .init(text: distinct.text, factIDs: ["fact-3"])], actionItems: [])
        XCTAssertEqual(try Pipeline.validate(draft, facts: facts).keyTakeaways.count, 2)
    }

    func testRepeatedSupportUsesBoundedBundlesWithoutLosingOriginalSpans() {
        let facts = (1...20).map { index in
            Pipeline.Fact(id: "fact-\(index)", kind: .observation, text: "The status remains unchanged.",
                spans: [.init(sourceID: "line-\(index)", quote: "Confirmation \(index): the status remains unchanged.")],
                uncertainFields: [], verdict: nil)
        }
        let bundles = Pipeline.deduplicated(facts)
        XCTAssertGreaterThan(bundles.count, 1)
        XCTAssertTrue(bundles.allSatisfy { $0.spans.count <= 8 && $0.sourceIDs.count <= 6 })
        XCTAssertEqual(bundles.flatMap(\.spans), facts.flatMap(\.spans))
        XCTAssertEqual(bundles.map(\.text), Array(repeating: facts[0].text, count: bundles.count))
    }

    func testDistinctSpansOnOneSourceAlsoRespectTheEightSpanLimit() {
        let facts = (1...17).map { index in
            Pipeline.Fact(id: "fact-\(index)", kind: .observation, text: "The status remains unchanged.",
                spans: [.init(sourceID: "line-1", quote: "Confirmation \(index).")], uncertainFields: [], verdict: nil)
        }
        let bundles = Pipeline.deduplicated(facts)
        XCTAssertEqual(bundles.map { $0.spans.count }, [8, 8, 1])
        XCTAssertEqual(bundles.flatMap(\.spans), facts.flatMap(\.spans))
    }

    func testLongNeighborDoesNotPreventExtractionPackingAndReviewUsesExactWindow() async throws {
        let tail = "The report is due tomorrow."
        let transcript = "[00:01] Alex: A short opening.\n[00:02] Bea: " + String(repeating: "Some earlier discussion. ", count: 500) + tail
        let sources = Base.sources(in: transcript)
        let runner = Base.Runner(countTokens: { $0.utf8.count }, complete: { _, _, _ in Data() })
        let pipeline = Pipeline(model: .qwen35_4B, runner: runner, maximumPromptTokens: 4500)
        let context = pipeline.context(core: [sources[0]], all: sources)
        XCTAssertLessThanOrEqual(context[1].spoken.count, 512)
        let helper = Base(model: .qwen35_4B, runner: runner, maximumPromptTokens: 4500)
        let groups = try await helper.fitting(sources, prompt: { try pipeline.extractionPrompt(core: $0, all: sources) },
                                             splitSingle: Base.splitSource)
        XCTAssertGreaterThan(groups.count, 1)
        for group in groups { XCTAssertLessThanOrEqual(try pipeline.extractionPrompt(core: group, all: sources).utf8.count, 4500) }
        let fact = Pipeline.Fact(id: "fact-1", kind: .observation, text: tail,
            spans: [.init(sourceID: "line-2", quote: tail)], uncertainFields: [], verdict: nil)
        let reviewed = pipeline.reviewSources([Pipeline.target(fact)], all: sources)
        let excerpt = try XCTUnwrap(reviewed.first(where: { $0.id == "line-2" }))
        XCTAssertTrue(excerpt.text.contains(tail))
        XCTAssertLessThan(excerpt.spoken.count, 400)
    }

    func testOversizedTitleFallsBackWithoutDroppingUsefulCheckedClaims() async throws {
        let claims = #"{"verdicts":[{"id":"keyTakeaway-0","verdict":"supported","sourceIDs":["line-2"],"reason":"Accurate uncertainty."},{"id":"actionItem-0","verdict":"supported","sourceIDs":["line-1"],"reason":"Explicit task."}]}"#
        let worker = Worker([extraction, factReview, rendering, claims])
        var runner = await worker.runner()
        runner.countTokens = { prompt in prompt.contains(#""section":"title""#) ? 100_000 : 100 }
        let notes = try await Pipeline(model: .qwen35_4B, language: "English", runner: runner)
            .generate(transcript: transcript, progress: { _ in })
        XCTAssertEqual(notes.title, "Meeting notes")
        XCTAssertEqual(notes.actionItems, ["Alex will send the report tomorrow."])
        XCTAssertEqual(notes.keyTakeaways, ["The quantity remains unclear."])
    }

    func testSelectionRetainsFieldUncertaintyAndVerdictMetadata() throws {
        let fact = Pipeline.Fact(id: "fact-1", kind: .suggestion, text: "The amount is uncertain.",
            spans: [.init(sourceID: "line-1", quote: "The amount is unclear.")], actor: "Alex", date: "Friday", quantity: nil,
            uncertainFields: [.quantity], verdict: .unclear)
        let runner = Base.Runner(countTokens: { _ in 0 }, complete: { _, _, _ in Data() })
        let prompt = try Pipeline(model: .qwen35_4B, runner: runner).selectionPrompt([fact])
        for value in ["sourceIDs", "line-1", "Alex", "Friday", "uncertainFields", "quantity", "verdict", "unclear"] {
            XCTAssertTrue(prompt.contains(value))
        }
        XCTAssertFalse(prompt.contains("The amount is unclear."))
    }

}
