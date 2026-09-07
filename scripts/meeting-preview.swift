// Developer verification harness. Audio and output stay in the isolated root.
// Usage: QuillMeetingPreview [analyze AUDIO_PATH PARTICIPANTS]
// QUILL_MEETING_TEST_ROOT selects the persistent test root.
import AppKit
import CryptoKit
import Foundation
@testable import quill

@main
struct MeetingPreviewEntry {
    @MainActor static func main() {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["QUILL_MEETING_TEST_ROOT"]
            ?? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("recordings").path)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "notes", arguments.count == 5 {
            Task.detached {
                do {
                    guard let model = NotesModel(rawValue: arguments[2]),
                          let strategy = MeetingNotesEngine.Strategy(rawValue: arguments[3]) else {
                        throw NSError(domain: "MeetingPreview", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "Unknown notes model or strategy"])
                    }
                    try await generateNotes(source: URL(fileURLWithPath: arguments[1]), model: model,
                                            strategy: strategy, output: URL(fileURLWithPath: arguments[4]))
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("Notes verification failed: \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
            dispatchMain()
        }
        if arguments.first == "analyze", arguments.count == 3 {
            Task.detached {
                do {
                    try await analyze(root: root, source: URL(fileURLWithPath: arguments[1]),
                                      participants: Int(arguments[2]) ?? 3)
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("Verification failed: \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
            dispatchMain()
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem(title: "Quill Meeting Preview", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        let transcriptionModels = ModelManager()
        let notesModels = NotesModelManager.shared
        let settings = SettingsWindowController(modelManager: transcriptionModels, notesManager: notesModels)
        let actions = PreviewActions(settings: settings)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(PreviewActions.showSettings), keyEquivalent: ",")
        settingsItem.target = actions
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        app.mainMenu = menu
        let editor = MeetingWindowController(root: root, modelProvider: { transcriptionModels.activeModel },
            canAnalyze: { !transcriptionModels.isPreparingModel && !notesModels.isPreparingModel },
            onBusyChanged: { busy in
                transcriptionModels.actionsLocked = busy
                notesModels.actionsLocked = busy
            })
        editor.model.noteGenerator = { document, progress in
            let selectedModel = NotesModelManager.shared.activeModel
            return try await MeetingNotesEngine.shared.generate(
                transcript: document.transcriptMarkdown, model: selectedModel, progress: progress)
        }
        editor.model.onOpenNotesSettings = { settings.show() }
        editor.model.shouldGenerateNotesAutomatically = {
            notesModels.state(for: notesModels.activeModel) == .active
        }
        editor.show()
        withExtendedLifetime((editor, settings, actions)) { app.run() }
    }

    static func analyze(root: URL, source: URL, participants: Int) async throws {
        let started = Date()
        let store = MeetingStore(root: root)
        var document = try store.importRecording(from: source)
        let waveform = try await MeetingAnalysis.shared.waveform(audioURL: store.audioURL(for: document))
        document.duration = waveform.duration
        document.waveform = waveform.peaks
        document.speakers = participants > 0
            ? (1...participants).map { MeetingSpeaker(id: "speaker-\($0)", name: "Speaker \($0)") } : []
        _ = try store.save(document)
        let result = try await MeetingAnalysis.shared.analyze(
            audioURL: store.audioURL(for: document), participantCount: participants, model: .parakeetV3
        ) { progress in
            FileHandle.standardError.write(Data("\(Int(progress.fraction * 100))% \(progress.message)\n".utf8))
        }
        document.words = result.words
        document.regions = result.regions
        for id in Set(result.regions.flatMap(\.speakerIDs)).sorted() where !document.speakers.contains(where: { $0.id == id }) {
            document.speakers.append(MeetingSpeaker(id: id, name: "Speaker \(document.speakers.count + 1)"))
        }
        document.acousticEvidence = result.acousticEvidence
        document.provenance = "Parakeet v3 + FluidAudio offline diarization"
        // Keep failed integration output local for investigating bounds and
        // labels; never print meeting content into tool logs.
        try JSONEncoder().encode(document).write(to: root.appendingPathComponent("analysis-result.json"), options: .atomic)
        try document.validate()
        _ = try store.save(document)
        let restored = try store.load(id: document.id)
        guard restored == document else {
            throw NSError(domain: "MeetingPreview", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Saved session differs after reload"])
        }
        let summary: [String: Any] = [
            "sessionID": document.id,
            "durationSeconds": document.duration,
            "processingSeconds": Date().timeIntervalSince(started),
            "wordCount": document.words.count,
            "regionCount": document.regions.count,
            "speakerIDs": Array(Set(document.regions.flatMap(\.speakerIDs))).sorted(),
            "uncertainRegions": document.regions.filter(\.isUncertain).count,
            "overlapRegions": document.regions.filter { $0.speakerIDs.count > 1 }.count,
            "acousticEvidenceCount": document.acousticEvidence.count,
            "reloadVerified": true
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("verification-summary.json"), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
    }

    /// Bounded evaluation uses the same engine as the UI. Gold checklists never
    /// enter the prompt; the harness reads only an explicitly supplied transcript.
    static func generateNotes(source: URL, model: NotesModel, strategy: MeetingNotesEngine.Strategy,
                              output: URL) async throws {
        let transcript = try String(contentsOf: source, encoding: .utf8)
        let started = Date()
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        var notes = try await MeetingNotesEngine.shared.generate(transcript: transcript, model: model, strategy: strategy,
            trace: { stage, data in
                try? data.write(to: output.deletingLastPathComponent().appendingPathComponent("trace-\(stage)-\(UUID().uuidString).txt"), options: .atomic)
            })
        let elapsed = Date().timeIntervalSince(started)
        notes.sourceTranscriptHash = SHA256.hash(data: Data(transcript.utf8)).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(notes).write(to: output, options: .atomic)
        let metrics: [String: Any] = ["model": model.rawValue, "strategy": strategy.rawValue,
                                     "elapsedSeconds": elapsed, "sourceSHA256": notes.sourceTranscriptHash ?? "",
                                     "outputLanguage": MeetingNotesEngine.languageName(in: notes.title + "\n" + notes.summary) ?? "undetermined"]
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathExtension("metrics.json"), options: .atomic)
        print("\(model.rawValue) · \(strategy.rawValue) · \(String(format: "%.2f", elapsed)) seconds · saved \(output.path)")
    }
}

@MainActor
private final class PreviewActions: NSObject {
    let settings: SettingsWindowController
    init(settings: SettingsWindowController) { self.settings = settings }
    @objc func showSettings() { settings.show() }
}
