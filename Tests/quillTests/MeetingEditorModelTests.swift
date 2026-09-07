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
        document.participantCountHint = 2
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

    func testRepeatedNameCommitCreatesOnlyOneUndoEntry() throws {
        let (root, _, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MeetingEditorModel(root: root, modelProvider: { .default })
        model.open(document.id)
        model.rename("speaker-1", "Matteo")
        let renamed = model.document
        model.rename("speaker-1", "  Matteo  ")
        XCTAssertEqual(model.document, renamed)
        XCTAssertEqual(model.undoCount, 1)
        model.undo()
        XCTAssertEqual(model.document?.speakers.first?.name, "Speaker 1")
    }

    func testUnchangedTitleTranscriptAndNotesCommitsDoNotAddUndoEntries() throws {
        let (root, store, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = original
        meeting.regions = [.init(id: "one", start: 0, end: 0.5, speakerIDs: ["speaker-1"])]
        meeting.words = [.init(start: 0, end: 0.5, text: "Original words")]
        meeting.notes = .init(title: "Notes", summary: "Summary", keyTakeaways: [], actionItems: [], modelID: "test-local")
        try store.save(meeting)
        let model = MeetingEditorModel(root: root, modelProvider: { .default })
        model.open(meeting.id)
        model.renameTitle("  \(meeting.title)  ")
        model.updateText(regionID: "one", text: " Original   words \n")
        model.updateNotes { $0.summary = "Summary" }
        model.setNotes(try XCTUnwrap(meeting.notes))
        XCTAssertEqual(model.document, meeting)
        XCTAssertEqual(model.undoCount, 0)
        XCTAssertFalse(model.document?.hasTextCorrections ?? true)
        model.updateNotes { $0.summary = "Changed summary" }
        model.updateNotes { $0.summary = "Changed summary" }
        XCTAssertEqual(model.undoCount, 1)
        model.undo()
        XCTAssertEqual(model.document?.notes?.summary, "Summary")
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

    func testImportAutomaticallyTranscribesAndAddsDiscoveredSpeakers() async throws {
        let (root, store, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = MeetingTranscriptionProbe()
        let model = MeetingEditorModel(root: root, modelProvider: { .default }, transcriber: { _, count, _, _ in
            await probe.begin(count: count)
            return .init(words: [.init(start: 0, end: 0.2, text: "Hello")],
                         regions: [.init(start: 0, end: 0.5, speakerIDs: ["speaker-3"])], acousticEvidence: [])
        })
        model.importRecording(try store.audioURL(for: original))
        for _ in 0..<300 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.error)
        let counts = await probe.counts
        XCTAssertEqual(counts, [0], "A new import must use automatic speaker discovery")
        XCTAssertEqual(model.document?.speakers.map(\.id), ["speaker-3"])
        XCTAssertTrue(model.hasAnalysis)
        let saved = try store.load(id: XCTUnwrap(model.document?.id))
        XCTAssertEqual(saved.words.first?.text, "Hello")
    }

    func testWaveformHandoffKeepsNextOperationBusyAndCancellable() async throws {
        let (root, store, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = MeetingTranscriptionProbe()
        let model = MeetingEditorModel(root: root, modelProvider: { .default }, transcriber: { _, count, _, _ in
            await probe.begin(count: count)
            try await Task.sleep(for: .seconds(30))
            return .init(words: [], regions: [], acousticEvidence: [])
        })
        model.importRecording(try store.audioURL(for: original))
        for _ in 0..<300 {
            if !(await probe.counts).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let counts = await probe.counts
        XCTAssertEqual(counts, [0])
        XCTAssertTrue(model.isBusy, "Waveform completion must not clear the transcription task's busy state")
        model.cancel()
        for _ in 0..<300 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.hasAnalysis)
        XCTAssertTrue(model.status.contains("cancelled"))
    }

    func testAddingSpeakerAssignsOnlySelectedUnassignedRegionUnlessAllRequested() throws {
        let (root, store, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = original
        meeting.regions = [.init(id: "one", start: 0, end: 0.25, speakerIDs: [], isUncertain: true),
                           .init(id: "two", start: 0.25, end: 0.5, speakerIDs: [], isUncertain: true)]
        try store.save(meeting)
        let model = MeetingEditorModel(root: root, modelProvider: { .default })
        model.open(meeting.id)
        model.select("one")
        model.addSpeaker(name: "Guest")
        let assigned = try XCTUnwrap(model.document?.regions[0].speakerIDs.first)
        XCTAssertEqual(model.document?.regions[1].speakerIDs, [])
        XCTAssertFalse(model.removeSpeaker(assigned))
        model.participantCount = 1
        model.configureSpeakers()
        XCTAssertTrue(model.document?.speakers.contains(where: { $0.id == assigned }) == true)
        model.addSpeaker(name: "Another guest", assignAllUnknown: true)
        XCTAssertFalse(model.document?.regions[1].speakerIDs.isEmpty ?? true)
    }

    func testTextEditsInvalidateReviewWithoutConfirmingSpeakerAndNotesUseCorrectedSnapshot() async throws {
        let (root, store, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = original
        meeting.words = [.init(start: 0, end: 0.5, text: "Incorrect")]
        meeting.regions = [.init(id: "one", start: 0, end: 0.5, speakerIDs: ["speaker-1"])]
        try store.save(meeting)
        let model = MeetingEditorModel(root: root, modelProvider: { .default }, noteGenerator: { snapshot, _ in
            XCTAssertTrue(snapshot.transcriptMarkdown.contains("Corrected words"))
            return .init(title: "Meeting notes", summary: "Summary [00:00:00]", keyTakeaways: [], actionItems: [], modelID: "test-local")
        })
        model.open(meeting.id)
        model.markReviewed()
        XCTAssertNotNil(model.document?.reviewedAt)
        model.updateText(regionID: "one", text: "Corrected words")
        XCTAssertNil(model.document?.reviewedAt)
        XCTAssertFalse(model.document?.regions[0].isConfirmed ?? true)
        XCTAssertTrue(model.canGenerateNotes)
        model.generateNotes()
        for _ in 0..<300 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.error)
        XCTAssertNotNil(model.document?.notes?.sourceTranscriptHash)
        XCTAssertFalse(model.document?.notesAreStale ?? true)
        model.updateNotes { $0.summary = "My revised notes" }
        XCTAssertFalse(model.document?.notesAreStale ?? true)
        model.updateText(regionID: "one", text: "A later correction")
        XCTAssertTrue(model.document?.notesAreStale ?? false)
        XCTAssertEqual(model.document?.notes?.summary, "My revised notes")
        XCTAssertEqual(model.document?.words, meeting.words)
    }
}

private actor MeetingTranscriptionProbe {
    private(set) var counts: [Int] = []
    func begin(count: Int) { counts.append(count) }
}
