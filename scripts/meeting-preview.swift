// Developer verification harness. Audio and output stay in the isolated root.
// Usage: QuillMeetingPreview [analyze AUDIO_PATH PARTICIPANTS]
// QUILL_MEETING_TEST_ROOT selects the persistent test root.
import AppKit
import Foundation
@testable import quill

@main
struct MeetingPreviewEntry {
    @MainActor static func main() {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["QUILL_MEETING_TEST_ROOT"]
            ?? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("recordings").path)
        let arguments = Array(CommandLine.arguments.dropFirst())
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
        appMenu.addItem(withTitle: "Quit Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        app.mainMenu = menu
        let editor = MeetingWindowController(root: root, modelProvider: { .parakeetV3 })
        editor.show()
        withExtendedLifetime(editor) { app.run() }
    }

    static func analyze(root: URL, source: URL, participants: Int) async throws {
        let started = Date()
        let store = MeetingStore(root: root)
        var document = try store.importRecording(from: source)
        let waveform = try await MeetingAnalysis.shared.waveform(audioURL: store.audioURL(for: document))
        document.duration = waveform.duration
        document.waveform = waveform.peaks
        document.speakers = (1...participants).map { MeetingSpeaker(id: "speaker-\($0)", name: "Speaker \($0)") }
        _ = try store.save(document)
        let result = try await MeetingAnalysis.shared.analyze(
            audioURL: store.audioURL(for: document), participantCount: participants, model: .parakeetV3
        ) { progress in
            FileHandle.standardError.write(Data("\(Int(progress.fraction * 100))% \(progress.message)\n".utf8))
        }
        document.words = result.words
        document.regions = result.regions
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
}
