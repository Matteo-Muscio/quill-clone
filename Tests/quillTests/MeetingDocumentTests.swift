import XCTest
@testable import quill

final class MeetingDocumentTests: XCTestCase {
    private func document() -> MeetingDocument {
        MeetingDocument(title: "Lunch", audioFilename: "original.m4a", duration: 20,
                        speakers: [.init(id: "a", name: "Matteo"), .init(id: "b", name: "Guest")],
                        regions: [.init(id: "first", start: 0, end: 10, speakerIDs: ["a"]),
                                  .init(id: "second", start: 10, end: 20, speakerIDs: ["b"])],
                        words: [.init(start: 4, end: 6, text: "crossing"), .init(start: 8, end: 9, text: "later")])
    }

    func testSplitAndReassignPreserveTimeAndGiveBoundaryWordOneOwner() throws {
        var meeting = document()
        let rightID = try XCTUnwrap(meeting.split(regionID: "first", at: 5))
        XCTAssertTrue(meeting.assign(regionID: rightID, to: ["b"]))
        XCTAssertEqual(meeting.regions.map(\.start), [0, 5, 10])
        XCTAssertEqual(meeting.regions.map(\.end), [5, 10, 20])
        XCTAssertEqual(meeting.text(for: meeting.regions[0]), "")
        XCTAssertEqual(meeting.text(for: meeting.regions[1]), "crossing later")
        XCTAssertTrue(meeting.regions[0].isConfirmed)
        XCTAssertTrue(meeting.regions[1].isConfirmed)
        try meeting.validate()
    }

    func testInvalidEditsDoNotModifyDocument() {
        var meeting = document()
        let original = meeting
        XCTAssertNil(meeting.split(regionID: "first", at: .nan))
        XCTAssertNil(meeting.split(regionID: "first", at: 0))
        XCTAssertNil(meeting.split(regionID: "first", at: 10))
        XCTAssertFalse(meeting.assign(regionID: "first", to: ["missing"]))
        XCTAssertFalse(meeting.setBounds(regionID: "first", start: 0, end: .infinity))
        XCTAssertFalse(meeting.setBounds(regionID: "first", start: 0, end: 20))
        XCTAssertFalse(meeting.setBounds(regionID: "first", start: 7, end: 2))
        XCTAssertEqual(meeting, original)
    }

    func testBoundsClampAndConfirmWithoutMovingAudio() {
        var meeting = document()
        XCTAssertTrue(meeting.setBounds(regionID: "first", start: -10, end: 8))
        XCTAssertEqual(meeting.regions[0].start, 0)
        XCTAssertEqual(meeting.regions[0].end, 8)
        XCTAssertTrue(meeting.regions[0].isConfirmed)
        XCTAssertEqual(meeting.audioFilename, "original.m4a")
        XCTAssertEqual(meeting.duration, 20)
        XCTAssertEqual(meeting.regions[1].start, 8)
        XCTAssertTrue(meeting.regions[1].isConfirmed)
    }

    func testSharedBoundaryMovesBothNeighboursAndRetainsEveryWord() throws {
        var meeting = document()
        meeting.words = [.init(start: 8, end: 9, text: "before"), .init(start: 10, end: 11, text: "after")]
        XCTAssertTrue(meeting.setBounds(regionID: "first", start: 0, end: 12))
        XCTAssertEqual(meeting.regions.map(\.start), [0, 12])
        XCTAssertEqual(meeting.regions.map(\.end), [12, 20])
        XCTAssertEqual(meeting.regions.map { meeting.text(for: $0) }.joined(separator: " ").trimmingCharacters(in: .whitespaces), "before after")
        XCTAssertTrue(meeting.regions.allSatisfy(\.isConfirmed))
        XCTAssertTrue(meeting.setBounds(regionID: "second", start: 7, end: 20))
        XCTAssertEqual(meeting.regions[0].end, 7)
        XCTAssertEqual(meeting.regions[1].start, 7)
        XCTAssertEqual(meeting.text(for: meeting.regions[1]), "before after")
        try meeting.validate()
    }

    func testShrinkingIsolatedRegionRetainsVacatedAudioAsUncertain() throws {
        var meeting = document()
        meeting.regions = [.init(id: "only", start: 2, end: 12, speakerIDs: ["a"])]
        XCTAssertTrue(meeting.setBounds(regionID: "only", start: 4, end: 10))
        XCTAssertEqual(meeting.regions.map(\.start), [2, 4, 10])
        XCTAssertEqual(meeting.regions.map(\.end), [4, 10, 12])
        XCTAssertTrue(meeting.regions[0].isUncertain)
        XCTAssertTrue(meeting.regions[2].isUncertain)
        try meeting.validate()
    }

    func testRefinementPreservesConfirmedRegionsAndClipsCrossingProposal() throws {
        var meeting = document()
        meeting.regions = [.init(id: "fixed", start: 5, end: 10, speakerIDs: ["a", "b"], isConfirmed: true)]
        let fixed = meeting.regions[0]
        meeting.applyAnalysis(regions: [.init(start: -2, end: 25, speakerIDs: ["b"], isUncertain: true)])
        XCTAssertEqual(meeting.regions.count, 3)
        XCTAssertEqual(meeting.regions[1], fixed)
        XCTAssertEqual(meeting.regions.map(\.start), [0, 5, 10])
        XCTAssertEqual(meeting.regions.map(\.end), [5, 10, 20])
        XCTAssertFalse(meeting.regions[0].isConfirmed)
        XCTAssertTrue(meeting.regions[0].isUncertain)
        try meeting.validate()
    }

    func testConfirmedOtherSurvivesRefinementAndUncertainCanBeReviewedAgain() {
        var meeting = document()
        XCTAssertTrue(meeting.assign(regionID: "first", to: []))
        let fixed = meeting.regions[0]
        meeting.applyAnalysis(regions: [.init(start: 0, end: 20, speakerIDs: ["b"])])
        XCTAssertEqual(meeting.regions[0], fixed)
        XCTAssertEqual(meeting.speakerName(for: fixed), "Other")
        XCTAssertTrue(meeting.setUncertain(regionID: fixed.id))
        XCTAssertFalse(meeting.regions[0].isConfirmed)
        XCTAssertEqual(meeting.speakerName(for: meeting.regions[0]), "Uncertain")
    }

    func testRenameAndOverlapReflectInTranscriptLabels() {
        var meeting = document()
        XCTAssertTrue(meeting.assign(regionID: "first", to: ["a", "b", "a"]))
        XCTAssertEqual(meeting.regions[0].speakerIDs, ["a", "b"])
        XCTAssertTrue(meeting.renameSpeaker(id: "b", name: "  Elena  "))
        XCTAssertEqual(meeting.speakerName(for: meeting.regions[0]), "Matteo + Elena")
        XCTAssertFalse(meeting.renameSpeaker(id: "b", name: " \n "))
    }

    func testValidationRejectsMalformedRangesAndUnknownSpeakers() {
        var meeting = document()
        meeting.regions[0].end = .nan
        XCTAssertThrowsError(try meeting.validate())
        meeting = document()
        meeting.regions[0].speakerIDs = ["unknown"]
        XCTAssertThrowsError(try meeting.validate())
        meeting = document()
        meeting.waveform = [.infinity]
        XCTAssertThrowsError(try meeting.validate())
        meeting = document()
        meeting.audioFilename = "../secret.m4a"
        XCTAssertThrowsError(try meeting.validate())
        meeting = document()
        meeting.regions[1].start = 9
        XCTAssertThrowsError(try meeting.validate())
    }
}
