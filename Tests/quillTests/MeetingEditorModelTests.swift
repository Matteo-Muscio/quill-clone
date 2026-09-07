import AVFoundation
import XCTest
@testable import quill

@MainActor
final class MeetingEditorModelTests: XCTestCase {
    private func fixture() throws -> (URL, MeetingStore, MeetingDocument) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Meeting.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<8_000 { samples[index] = 0 }
        }
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            try file.write(from: buffer)
        }
        let store = MeetingStore(root: root)
        var document = try store.importRecording(from: source)
        document.duration = 0.5
        document.waveform = [0]
        document.speakers = [.init(id: "speaker-1", name: "Speaker 1"), .init(id: "speaker-2", name: "Speaker 2")]
        try store.save(document)
        return (root, store, document)
    }

    func testParticipantCountChangesAndUndoKeepDocumentInSync() throws {
        let (root, _, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MeetingEditorModel(root: root, modelProvider: { .default })
        model.open(document.id)
        model.rename("speaker-1", "Matteo")
        model.participantCount = 3
        model.configureSpeakers()
        XCTAssertEqual(model.document?.speakers.count, 3)
        model.undo()
        XCTAssertEqual(model.participantCount, 2)
        XCTAssertEqual(model.document?.speakers.count, 2)
        XCTAssertEqual(model.document?.speakers.first?.name, "Matteo")
        model.redo()
        XCTAssertEqual(model.participantCount, 3)
        XCTAssertEqual(model.document?.speakers.count, 3)
        model.undo()
        model.undo()
        XCTAssertEqual(model.document?.speakers.first?.name, "Speaker 1")
        XCTAssertEqual(model.participantCount, model.document?.speakers.count)
    }

    func testUnreadableNextRecordingDoesNotKeepPreviousPlayer() throws {
        let (root, store, first) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var second = try store.importRecording(from: store.audioURL(for: first))
        second.duration = first.duration
        second.waveform = [0]
        try store.save(second)
        let secondAudio = try store.audioURL(for: second)
        try Data("not an audio file".utf8).write(to: secondAudio)
        let model = MeetingEditorModel(root: root, modelProvider: { .default })
        model.open(first.id)
        XCTAssertTrue(model.isPlaybackAvailable)
        model.open(second.id)
        XCTAssertEqual(model.document?.id, second.id)
        XCTAssertFalse(model.isPlaybackAvailable)
        model.togglePlayback()
        XCTAssertFalse(model.isPlaying)
        XCTAssertTrue(model.error?.contains("Playback unavailable") == true)
    }

    func testSuccessfulOpenClearsPreviousFailure() throws {
        let (root, _, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MeetingEditorModel(root: root, modelProvider: { .default })
        model.importRecording(root.appendingPathComponent("missing.m4a"))
        XCTAssertNotNil(model.error)
        model.open(document.id)
        XCTAssertEqual(model.document?.id, document.id)
        XCTAssertTrue(model.isPlaybackAvailable)
        XCTAssertNil(model.error)
    }

    func testRetrySaveRetainsExportWarningUntilExportActuallySucceeds() throws {
        let (root, store, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MeetingEditorModel(root: root, modelProvider: { .default })
        model.open(document.id)
        let markdown = try store.sessionURL(id: document.id).appendingPathComponent("transcript.md")
        try FileManager.default.removeItem(at: markdown)
        try FileManager.default.createDirectory(at: markdown, withIntermediateDirectories: false)
        model.rename("speaker-1", "Matteo")
        XCTAssertTrue(model.error?.contains("Meeting saved") == true)
        XCTAssertTrue(model.persist(), "The canonical session is saved even when an export fails")
        XCTAssertTrue(model.error?.contains("Meeting saved") == true)
        try FileManager.default.removeItem(at: markdown)
        XCTAssertTrue(model.persist())
        XCTAssertNil(model.error)
        XCTAssertEqual(try store.load(id: document.id).speakers.first?.name, "Matteo")
    }

    func testUpdateReservationFreezesImportsAndEditsBeforeTermination() throws {
        let (root, store, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MeetingEditorModel(root: root, modelProvider: { .default })
        model.open(document.id)
        let before = model.document
        model.isExternallyLocked = true
        model.rename("speaker-1", "Changed during update")
        model.participantCount = 3
        model.configureSpeakers()
        model.importRecording(try store.audioURL(for: document))
        model.edit { $0.title = "Changed during update" }
        XCTAssertEqual(model.document, before)
        XCTAssertEqual(try store.recentSessions().count, 1)
        XCTAssertEqual(model.undoCount, 0)
        model.isExternallyLocked = false
        model.rename("speaker-1", "Matteo")
        XCTAssertEqual(model.document?.speakers.first?.name, "Matteo")
    }

    func testUnsavedEditsBlockSessionSwitchUntilSaveRecovers() throws {
        let (root, store, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let second = try store.importRecording(from: store.audioURL(for: document))
        var reportedBusy = false
        let model = MeetingEditorModel(root: root, modelProvider: { .default }, onBusyChanged: { reportedBusy = $0 })
        model.open(document.id)
        let audio = try store.audioURL(for: document)
        let original = try Data(contentsOf: audio)
        try FileManager.default.removeItem(at: audio)
        model.rename("speaker-1", "Matteo")
        XCTAssertTrue(reportedBusy)
        model.open(second.id)
        XCTAssertEqual(model.document?.id, document.id)
        XCTAssertEqual(model.document?.speakers.first?.name, "Matteo")
        try original.write(to: audio)
        XCTAssertTrue(model.persist())
        XCTAssertFalse(reportedBusy)
        XCTAssertNil(model.error)
    }
}
