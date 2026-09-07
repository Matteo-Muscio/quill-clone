import XCTest
@testable import quill

final class MeetingStoreTests: XCTestCase {
    private func fixture() throws -> (URL, MeetingStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("Lunch.m4a")
        try Data("original audio bytes".utf8).write(to: source)
        return (directory, MeetingStore(root: directory.appendingPathComponent("recordings")), source)
    }

    func testImportCopiesOriginalAndReopenSurvivesSourceRemoval() throws {
        let (directory, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: source)
        let imported = try store.importRecording(from: source)
        try FileManager.default.removeItem(at: source)
        let reopened = try store.load(id: imported.id)
        XCTAssertEqual(reopened, imported)
        XCTAssertEqual(try Data(contentsOf: store.audioURL(for: reopened)), original)
        XCTAssertEqual(try store.recentSessions().map(\.id), [imported.id])
        let session = try store.sessionURL(id: imported.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent("meta.json").path))
    }

    func testImportUnderPrivateTmpAliasWithExistingRoot() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("quill-meeting-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(root: directory.appendingPathComponent("recordings", isDirectory: true))
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("Lunch.m4a")
        let bytes = Data("original audio bytes".utf8)
        try bytes.write(to: source)
        let imported = try store.importRecording(from: source)
        XCTAssertEqual(try store.load(id: imported.id), imported)
        XCTAssertEqual(try Data(contentsOf: store.audioURL(for: imported)), bytes)
        let audio = try store.audioURL(for: imported)
        try FileManager.default.removeItem(at: audio)
        try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: source)
        XCTAssertThrowsError(try store.load(id: imported.id), "Alias normalization must still reject audio escaping its session")
    }

    func testSaveCorrectedSpeakersUpdatesExportsWithoutChangingAudio() throws {
        let (directory, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var meeting = try store.importRecording(from: source)
        let bytes = try Data(contentsOf: store.audioURL(for: meeting))
        meeting.duration = 10
        meeting.speakers = [.init(id: "a", name: "Matteo"), .init(id: "b", name: "Elena")]
        meeting.words = [.init(start: 1, end: 2, text: "Hello")]
        meeting.regions = [.init(id: "r", start: 0, end: 10, speakerIDs: ["a"])]
        XCTAssertTrue(meeting.assign(regionID: "r", to: ["b"]))
        XCTAssertNil(try store.save(meeting))
        let session = try store.sessionURL(id: meeting.id)
        let markdown = try String(contentsOf: session.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("Elena: Hello"))
        XCTAssertFalse(markdown.contains("Matteo:"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: session.appendingPathComponent("transcript.json"))) as? [String: Any])
        let segments = try XCTUnwrap(json["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.first?["speaker"] as? String, "Elena")
        XCTAssertEqual(try store.load(id: meeting.id), meeting)
        XCTAssertEqual(try Data(contentsOf: store.audioURL(for: meeting)), bytes)
    }

    func testRejectsTraversalAndSymlinkAudioEscape() throws {
        let (directory, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var meeting = try store.importRecording(from: source)
        XCTAssertThrowsError(try store.load(id: "../outside"))
        let audio = try store.audioURL(for: meeting)
        try FileManager.default.removeItem(at: audio)
        try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: source)
        XCTAssertThrowsError(try store.load(id: meeting.id))
        meeting.audioFilename = "../Lunch.m4a"
        XCTAssertThrowsError(try store.save(meeting))
    }

    func testInvalidCanonicalDocumentIsSkippedWithoutHidingValidSession() throws {
        let (directory, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = try store.importRecording(from: source)
        let invalid = try store.importRecording(from: source)
        let invalidURL = try store.sessionURL(id: invalid.id).appendingPathComponent("session.json")
        try Data("{bad json".utf8).write(to: invalidURL)
        XCTAssertEqual(try store.recentSessions().map(\.id), [valid.id])
        XCTAssertThrowsError(try store.load(id: invalid.id))
    }

    func testExportFailureReportsSavedCanonicalDocument() throws {
        let (directory, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var meeting = try store.importRecording(from: source)
        let markdown = try store.sessionURL(id: meeting.id).appendingPathComponent("transcript.md")
        try FileManager.default.removeItem(at: markdown)
        try FileManager.default.createDirectory(at: markdown, withIntermediateDirectories: false)
        meeting.title = "Updated title"
        let warning = try XCTUnwrap(store.save(meeting))
        XCTAssertTrue(warning.contains("Meeting saved"))
        XCTAssertEqual(try store.load(id: meeting.id).title, "Updated title")
    }

    func testCorrectionsNotesAndReviewPersistAndExportWithoutReplacingRecognizedWords() throws {
        let (directory, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var meeting = try store.importRecording(from: source)
        meeting.duration = 10
        meeting.speakers = [.init(id: "a", name: "Matteo")]
        meeting.regions = [.init(id: "r", start: 0, end: 10, speakerIDs: ["a"])]
        meeting.words = [.init(start: 1, end: 2, text: "Mistake")]
        meeting.replaceText(regionID: "r", text: "Corrected fact")
        meeting.reviewedAt = Date()
        meeting.notes = .init(title: "Agreed title", summary: "Corrected fact [00:00:00]", keyTakeaways: ["A takeaway"],
                              actionItems: ["Matteo to follow up"], modelID: "local-test", sourceTranscriptHash: meeting.transcriptFingerprint)
        XCTAssertNil(try store.save(meeting))
        let loaded = try store.load(id: meeting.id)
        XCTAssertEqual(loaded, meeting)
        XCTAssertEqual(loaded.words[0].text, "Mistake")
        let session = try store.sessionURL(id: meeting.id)
        let markdown = try String(contentsOf: session.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertEqual(markdown, meeting.transcriptMarkdown)
        XCTAssertTrue(markdown.contains("Corrected fact"))
        let notes = try String(contentsOf: session.appendingPathComponent("notes.md"), encoding: .utf8)
        XCTAssertTrue(notes.contains("Corrected fact [00:00:00]"))
        meeting.notes = nil
        XCTAssertNil(try store.save(meeting))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent("notes.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent("notes.json").path))
    }
}
