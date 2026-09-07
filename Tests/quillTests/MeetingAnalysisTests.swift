import AVFoundation
import FluidAudio
import XCTest
@testable import quill

final class MeetingAnalysisTests: XCTestCase {
    func testMeetingConfigurationRetainsOverlapsAndShortReplies() {
        let config = MeetingAnalysis.diarizerConfiguration(participantCount: 3)
        XCTAssertFalse(config.exclusiveSegments)
        XCTAssertEqual(config.minSegmentDuration, 0.3)
        XCTAssertTrue(config.embedding.excludeOverlap, "Reference embeddings should still mask overlapping speech")
        XCTAssertTrue(config.exposeChunkEmbeddings)
        XCTAssertEqual(config.clustering.maxSpeakers, 4)
    }

    func testAlignmentPreservesOverlapAndUnmatchedWords() {
        let turns = [
            MeetingDiarizedTurn(start: 0, end: 3, speakerID: "A", quality: 1),
            MeetingDiarizedTurn(start: 2, end: 4, speakerID: "B", quality: 1),
        ]
        let words = [MeetingWord(start: 5, end: 6, text: "Unmatched")]
        let regions = MeetingAnalysis.alignedRegions(turns: turns, words: words, mapping: ["A": "one", "B": "two"])
        XCTAssertEqual(regions.count, 4)
        XCTAssertEqual(regions[1].start, 2)
        XCTAssertEqual(regions[1].end, 3)
        XCTAssertEqual(regions[1].speakerIDs, ["one", "two"])
        XCTAssertTrue(regions[1].isUncertain)
        XCTAssertEqual(regions[3].speakerIDs, [])
        XCTAssertEqual(regions[3].start, 5)
        XCTAssertTrue(regions[3].isUncertain)
    }

    func testIncidentalVoiceDoesNotConsumeParticipantSlot() {
        let turns = [
            MeetingDiarizedTurn(start: 0, end: 1, speakerID: "waiter", quality: 1),
            MeetingDiarizedTurn(start: 1, end: 20, speakerID: "guest", quality: 1),
            MeetingDiarizedTurn(start: 20, end: 45, speakerID: "host", quality: 1),
        ]
        let map = MeetingAnalysis.speakerMapping(turns: turns, participantCount: 2)
        XCTAssertNil(map["waiter"])
        XCTAssertEqual(map["guest"], "speaker-1")
        XCTAssertEqual(map["host"], "speaker-2")
    }

    func testModelTimestampsAreClippedToExactAudioDuration() {
        let duration = 2.000_001
        let words = MeetingAnalysis.normalizedWords([
            MeetingWord(start: -0.1, end: 0.4, text: "Beginning"),
            MeetingWord(start: 1.9, end: 2.01, text: "End"),
            MeetingWord(start: 3, end: 4, text: "Padding"),
            MeetingWord(start: .nan, end: 1, text: "Invalid"),
        ], duration: duration)
        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0].start, 0)
        XCTAssertEqual(words[1].end, duration)
        let turns = MeetingAnalysis.normalizedTurns([
            MeetingDiarizedTurn(start: 1.8, end: Double(Float(duration)), speakerID: "A", quality: .nan),
            MeetingDiarizedTurn(start: 4, end: 3, speakerID: "B", quality: 1),
        ], duration: duration)
        XCTAssertEqual(turns.count, 1)
        XCTAssertLessThanOrEqual(turns[0].end, duration)
        XCTAssertEqual(turns[0].quality, 0)
    }

    func testRefinementUsesCorrectedExamplesAndPreservesManualBoundsAndOverlap() throws {
        var document = fixture()
        let overlap = MeetingRegion(start: 8, end: 9, speakerIDs: ["one", "two"], isConfirmed: true)
        document.regions.append(overlap)
        let refined = try MeetingRefinement.refine(document: document)
        XCTAssertEqual(Array(refined.prefix(2)), Array(document.regions.prefix(2)))
        XCTAssertEqual(refined.last, overlap)
        XCTAssertEqual(refined[2].speakerIDs, ["two"], "Acoustics, not the original cluster name, must drive reassignment")
        XCTAssertEqual(refined[2].start, document.regions[2].start)
        XCTAssertEqual(refined[2].end, document.regions[2].end)
        XCTAssertFalse(refined[2].isConfirmed)
        XCTAssertEqual(refined[3].speakerIDs, ["one"])
        XCTAssertTrue(refined[3].isUncertain, "Tied similarity must flag the existing attribution without asserting a new identity")
        document.regions = refined
        XCTAssertEqual(try MeetingRefinement.refine(document: document), refined, "Refining twice must retain the same acoustic association")
    }

    func testRefinementPreservesUnsupportedDraftLaneAndLeavesUnknownUnknown() throws {
        var document = fixture()
        document.regions.append(MeetingRegion(start: 8, end: 9, speakerIDs: ["one"]))
        document.regions.append(MeetingRegion(start: 9, end: 10, speakerIDs: [], isUncertain: true))
        let refined = try MeetingRefinement.refine(document: document)
        XCTAssertEqual(refined[4].id, document.regions[4].id)
        XCTAssertEqual(refined[4].speakerIDs, ["one"])
        XCTAssertTrue(refined[4].isUncertain)
        XCTAssertEqual(refined[5].speakerIDs, [])
        XCTAssertTrue(refined[5].isUncertain)
    }

    func testTinyPartialCorrectionIsNotAcceptedAsCleanTrainingEvidence() {
        var document = fixture()
        document.regions[0].end = 0.1
        XCTAssertThrowsError(try MeetingRefinement.refine(document: document))
    }

    func testMissingThirdSpeakerReferencesCannotForceTheirVoiceIntoKnownSpeakers() {
        var document = fixture()
        document.regions.append(MeetingRegion(start: 8, end: 9, speakerIDs: ["three"]))
        XCTAssertThrowsError(try MeetingRefinement.refine(document: document))
    }

    func testReferenceRequiresCoverageOfEntireOriginalMaskedWindow() {
        var document = fixture()
        document.acousticEvidence[0].windowID = "shared-window"
        document.acousticEvidence.append(MeetingAcousticEvidence(start: 8, end: 10,
            sourceSpeakerID: "one", embedding: [1, 0], windowID: "shared-window"))
        // Confirming only the 0...2 fragment covers half the original window's
        // speech. The second 8...10 fragment has not been reviewed.
        XCTAssertThrowsError(try MeetingRefinement.refine(document: document))
    }

    func testInvalidAndSilentVectorsCannotProduceConfidentMatches() {
        XCTAssertNil(MeetingRefinement.cosine([0, 0], [1, 0]))
        XCTAssertNil(MeetingRefinement.cosine([.nan, 0], [1, 0]))
        XCTAssertNil(MeetingRefinement.cosine([1], [1, 0]))
        XCTAssertEqual(MeetingRefinement.average([([0, 0], 1)]), [])
    }

    func testCancellationReachesDetachedAudioReads() throws {
        let cancellation = MeetingAudioCancellation()
        let source = MeetingAudioCancellableSource(source: ArrayAudioSampleSource(samples: [0.25, 0.5]),
                                                   cancellation: cancellation)
        var destination: [Float] = [0, 0]
        try destination.withUnsafeMutableBufferPointer {
            try source.copySamples(into: $0.baseAddress!, offset: 0, count: 2)
        }
        XCTAssertEqual(destination, [0.25, 0.5])
        cancellation.cancel()
        XCTAssertThrowsError(try destination.withUnsafeMutableBufferPointer {
            try source.copySamples(into: $0.baseAddress!, offset: 0, count: 2)
        }) { XCTAssertTrue($0 is CancellationError) }
    }

    func testWaveformReadsAudioInBoundedBins() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        for frame in 0..<16_000 { buffer.floatChannelData![0][frame] = frame < 8000 ? 0.25 : 0.75 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let waveform = try await MeetingAnalysis.shared.waveform(audioURL: url, maximumPeaks: 20)
        XCTAssertEqual(waveform.duration, 1, accuracy: 0.001)
        XCTAssertEqual(waveform.peaks.count, 20)
        XCTAssertEqual(waveform.peaks[0], 0.25, accuracy: 0.001)
        XCTAssertEqual(waveform.peaks[19], 0.75, accuracy: 0.001)
    }

    private func fixture() -> MeetingDocument {
        MeetingDocument(title: "Synthetic", audioFilename: "synthetic.wav", duration: 10,
            speakers: [MeetingSpeaker(id: "one", name: "One"), MeetingSpeaker(id: "two", name: "Two")],
            regions: [
                MeetingRegion(start: 0, end: 2, speakerIDs: ["one"], isConfirmed: true),
                MeetingRegion(start: 2, end: 4, speakerIDs: ["two"], isConfirmed: true),
                MeetingRegion(start: 4, end: 6, speakerIDs: ["one"]),
                MeetingRegion(start: 6, end: 8, speakerIDs: ["one"]),
            ], acousticEvidence: [
                MeetingAcousticEvidence(start: 0, end: 2, sourceSpeakerID: "wrong-original-name", embedding: [1, 0]),
                MeetingAcousticEvidence(start: 2, end: 4, sourceSpeakerID: "two", embedding: [0, 1]),
                MeetingAcousticEvidence(start: 4, end: 6, sourceSpeakerID: "one", embedding: [0.05, 0.95]),
                MeetingAcousticEvidence(start: 6, end: 8, sourceSpeakerID: "one", embedding: [0.7, 0.7]),
            ])
    }
}
