import Foundation

enum MeetingStoreError: Error, LocalizedError {
    case invalidDocument(String)
    case invalidAudio
    case missingAudio

    var errorDescription: String? {
        switch self {
        case .invalidDocument(let reason): return "This meeting cannot be opened. \(reason)"
        case .invalidAudio: return "Choose an audio file such as a Voice Memos .m4a recording."
        case .missingAudio: return "The original recording for this meeting is missing or outside its session folder."
        }
    }
}

/// Imported meetings deliberately live outside the ordinary meta.json transcription queue.
/// session.json is canonical; transcripts are disposable exports regenerated on every save.
struct MeetingStore: Sendable {
    let root: URL

    init(root: URL = Config.recordingsDir() ?? Config.defaultRoot) {
        self.root = root.appendingPathComponent("Imported Meetings", isDirectory: true)
    }

    func importRecording(from source: URL) throws -> MeetingDocument {
        let resource = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let ext = source.pathExtension.lowercased()
        guard resource.isRegularFile == true, (resource.fileSize ?? 0) > 0,
              ["m4a", "mp3", "wav", "aiff", "aif", "caf", "mp4", "aac", "flac"].contains(ext)
        else { throw MeetingStoreError.invalidAudio }
        let title = source.deletingPathExtension().lastPathComponent
        let document = MeetingDocument(title: title.isEmpty ? "Imported meeting" : title, audioFilename: "original.\(ext)")
        let directory = try sessionURL(id: document.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(document.audioFilename))
            _ = try save(document)
            return document
        } catch {
            // Only our newly-created, uniquely-owned session is removed on failed import.
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func load(id: String) throws -> MeetingDocument {
        let directory = try sessionURL(id: id)
        let documentURL = directory.appendingPathComponent("session.json")
        try ensureContained(documentURL, in: directory)
        let document = try JSONDecoder().decode(MeetingDocument.self, from: Data(contentsOf: documentURL))
        guard document.id == id else { throw MeetingStoreError.invalidDocument("The meeting identifier does not match its folder.") }
        try document.validate()
        _ = try audioURL(for: document)
        return document
    }

    /// A returned warning means the canonical session was saved, but derived exports failed.
    /// A thrown error means the session was not successfully saved.
    @discardableResult
    func save(_ document: MeetingDocument) throws -> String? {
        try document.validate()
        let directory = try sessionURL(id: document.id)
        _ = try audioURL(for: document)
        let destination = directory.appendingPathComponent("session.json")
        try ensureContained(destination, in: directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: destination, options: .atomic)
        do {
            try export(document, directory: directory, encoder: encoder)
            return nil
        } catch {
            return "Meeting saved. Transcript export could not be updated: \(error.localizedDescription)"
        }
    }

    func audioURL(for document: MeetingDocument) throws -> URL {
        guard MeetingDocument.safeComponent(document.audioFilename), document.audioFilename.hasPrefix("original.")
        else { throw MeetingStoreError.missingAudio }
        let directory = try sessionURL(id: document.id)
        let audio = directory.appendingPathComponent(document.audioFilename)
        try ensureContained(audio, in: directory)
        guard (try? audio.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { throw MeetingStoreError.missingAudio }
        return audio
    }

    func recentSessions() throws -> [MeetingDocument] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { try? load(id: $0.lastPathComponent) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func sessionURL(id: String) throws -> URL {
        guard MeetingDocument.safeComponent(id) else { throw MeetingStoreError.invalidDocument("Invalid meeting folder.") }
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try ensureContained(directory, in: root)
        return directory
    }

    private func ensureContained(_ url: URL, in directory: URL) throws {
        let expectedParent = directory.resolvingSymlinksInPath().standardizedFileURL
        // Resolve the item first to catch an existing symlink escape, then resolve
        // its parent again: Foundation can retain /private/tmp for a not-yet-created
        // child while canonicalizing the existing parent as /tmp.
        let actualParent = url.resolvingSymlinksInPath().standardizedFileURL
            .deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        // URL equality also compares directory hints/trailing slashes; containment
        // compares canonical filesystem paths instead.
        guard actualParent.path == expectedParent.path else {
            throw MeetingStoreError.invalidDocument("A meeting path points outside its session folder.")
        }
    }

    private struct TranscriptExport: Encodable {
        let title: String
        let duration: Double
        let segments: [Segment]

        struct Segment: Encodable {
            let start: Double
            let end: Double
            let speakerIDs: [String]
            let speaker: String
            let text: String
            let confirmed: Bool
            let uncertain: Bool
        }
    }

    private func export(_ document: MeetingDocument, directory: URL, encoder: JSONEncoder) throws {
        let segments = document.regions.sorted { $0.start < $1.start }.map { region in
            TranscriptExport.Segment(start: region.start, end: region.end, speakerIDs: region.speakerIDs,
                                     speaker: document.speakerName(for: region), text: document.text(for: region),
                                     confirmed: region.isConfirmed, uncertain: region.isUncertain)
        }
        let jsonURL = directory.appendingPathComponent("transcript.json")
        let markdownURL = directory.appendingPathComponent("transcript.md")
        try ensureContained(jsonURL, in: directory)
        try ensureContained(markdownURL, in: directory)
        try encoder.encode(TranscriptExport(title: document.title, duration: document.duration, segments: segments))
            .write(to: jsonURL, options: .atomic)
        try Data(document.transcriptMarkdown.utf8).write(to: markdownURL, options: .atomic)
        let notesJSON = directory.appendingPathComponent("notes.json")
        let notesMarkdown = directory.appendingPathComponent("notes.md")
        try ensureContained(notesJSON, in: directory)
        try ensureContained(notesMarkdown, in: directory)
        if let notes = document.notes {
            try encoder.encode(notes).write(to: notesJSON, options: .atomic)
            let sections = ["# \(notes.title)", notes.summary,
                            "## Key takeaways\n\n" + notes.keyTakeaways.map { "- \($0)" }.joined(separator: "\n"),
                            "## Action items\n\n" + notes.actionItems.map { "- \($0)" }.joined(separator: "\n")]
            try Data(sections.joined(separator: "\n\n").utf8).write(to: notesMarkdown, options: .atomic)
        } else {
            // Undoing note generation must not leave a stale export looking current.
            for url in [notesJSON, notesMarkdown] where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}
