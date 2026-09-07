import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

typealias MeetingNoteGenerator = (MeetingDocument, @escaping @Sendable (MeetingAnalysisProgress) -> Void) async throws -> MeetingNotes
typealias MeetingTranscriber = @Sendable (URL, Int, TranscriptionModel, @escaping @Sendable (MeetingAnalysisProgress) -> Void) async throws -> MeetingAnalysisResult

@MainActor
final class MeetingEditorModel: ObservableObject {
    @Published var document: MeetingDocument?
    @Published var recent: [MeetingDocument] = []
    @Published var selectedID: String?
    @Published var playhead = 0.0
    @Published var isPlaying = false
    @Published var zoom = 1.0
    @Published var isBusy = false
    @Published var isExternallyLocked = false
    @Published var progress = 0.0
    @Published var status = "Drop a recording to begin"
    @Published var error: String?
    @Published var participantCount = 0
    @Published private(set) var undoCount = 0
    @Published private(set) var redoCount = 0
    private let store: MeetingStore
    private let modelProvider: () -> TranscriptionModel
    private let canAnalyze: () -> Bool
    private let onBusyChanged: (Bool) -> Void
    private let transcriber: MeetingTranscriber
    var noteGenerator: MeetingNoteGenerator?
    var onOpenNotesSettings: (() -> Void)?
    private var operation: Task<Void, Never>?
    private var analysisGeneration = UUID()
    private var player: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?
    private var hasUnsavedEdits = false
    private var undoStack: [MeetingDocument] = []
    private var redoStack: [MeetingDocument] = []

    init(root: URL, modelProvider: @escaping () -> TranscriptionModel,
         canAnalyze: @escaping () -> Bool = { true }, onBusyChanged: @escaping (Bool) -> Void = { _ in },
         noteGenerator: MeetingNoteGenerator? = nil,
         transcriber: @escaping MeetingTranscriber = { url, count, model, progress in
             try await MeetingAnalysis.shared.analyze(audioURL: url, participantCount: count, model: model, progress: progress)
         }) {
        store = MeetingStore(root: root)
        self.modelProvider = modelProvider
        self.canAnalyze = canAnalyze
        self.onBusyChanged = onBusyChanged
        self.noteGenerator = noteGenerator
        self.transcriber = transcriber
        refreshRecent()
    }

    var selected: MeetingRegion? { document?.regions.first { $0.id == selectedID } }
    var isInteractionBlocked: Bool { isBusy || isExternallyLocked }
    var hasAnalysis: Bool { !(document?.regions.isEmpty ?? true) }
    var isPlaybackAvailable: Bool { player != nil }
    var hasUnsavedChanges: Bool { hasUnsavedEdits }
    var transcriptText: String { document?.transcriptText ?? "" }
    var canGenerateNotes: Bool {
        noteGenerator != nil && !isInteractionBlocked
            && document.map { document in document.regions.contains { !document.text(for: $0).isEmpty } } == true
    }
    var selectedText: String { guard let document, let selected else { return "" }; return document.text(for: selected) }
    var canSplit: Bool { guard let selected else { return false }; return playhead > selected.start + 0.05 && playhead < selected.end - 0.05 }

    func chooseRecording() {
        guard !isInteractionBlocked else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import recording"
        if panel.runModal() == .OK, let url = panel.url { importRecording(url) }
    }

    func importRecording(_ url: URL) {
        guard !isInteractionBlocked, persist() else { return }
        pause()
        error = nil
        do {
            document = try store.importRecording(from: url)
            participantCount = 0
            refreshRecent()
            resetHistory()
            selectedID = nil
            playhead = 0
            zoom = 1
            preparePlayer()
            prepareWaveform(autoTranscribe: true)
        } catch { self.error = error.localizedDescription }
    }

    func open(_ id: String) {
        guard !isInteractionBlocked, persist() else { return }
        do {
            pause()
            document = try store.load(id: id)
            error = nil
            participantCount = document?.participantCountHint ?? 0
            selectedID = nil
            playhead = 0
            zoom = 1
            resetHistory()
            preparePlayer()
            status = "Saved on this Mac"
            if document?.waveform.isEmpty == true { prepareWaveform() }
        } catch { self.error = error.localizedDescription }
    }

    func configureSpeakers() {
        guard !isInteractionBlocked, document != nil else { return }
        let count = min(12, max(0, participantCount))
        participantCount = count
        edit { current in
            current.participantCountHint = count == 0 ? nil : count
            if count > 0 {
                while current.speakers.count < count { current.addSpeaker() }
                for speaker in current.speakers.reversed() where current.speakers.count > count {
                    _ = current.removeSpeaker(speaker.id)
                }
            }
            current.updatedAt = Date()
        }
    }

    func rename(_ id: String, _ name: String) {
        guard !isInteractionBlocked else { return }
        edit { _ = $0.renameSpeaker(id: id, name: name) }
    }

    func renameTitle(_ title: String) {
        guard !isInteractionBlocked else { return }
        edit { _ = $0.renameTitle(title) }
    }

    func updateText(regionID: String, text: String) {
        guard !isInteractionBlocked else { return }
        edit { _ = $0.replaceText(regionID: regionID, text: text) }
    }

    /// The caller presents explicit confirmation before discarding editorial text.
    func resetTextCorrections() {
        guard !isInteractionBlocked else { return }
        edit { $0.textCorrections = []; $0.updatedAt = Date() }
    }

    func markReviewed(_ reviewed: Bool = true) {
        guard !isInteractionBlocked else { return }
        edit { $0.reviewedAt = reviewed ? Date() : nil; $0.updatedAt = Date() }
    }

    func addSpeaker(name: String = "", assignAllUnknown: Bool = false) {
        guard !isInteractionBlocked else { return }
        let selectedID = selectedID
        edit { current in
            let id = current.addSpeaker(name: name)
            let targets = current.regions.filter {
                $0.speakerIDs.isEmpty && (assignAllUnknown || $0.id == selectedID)
            }.map(\.id)
            for target in targets { current.assign(regionID: target, to: [id]) }
        }
    }

    @discardableResult
    func removeSpeaker(_ id: String) -> Bool {
        guard !isInteractionBlocked else { return false }
        var removed = false
        edit { removed = $0.removeSpeaker(id) }
        if !removed { error = "This speaker still has segments. Reassign those segments before removing the speaker." }
        return removed
    }

    func setNotes(_ notes: MeetingNotes) {
        edit {
            guard $0.notes != notes else { return }
            $0.notes = notes
            $0.updatedAt = Date()
        }
    }

    func updateNotes(_ change: (inout MeetingNotes) -> Void) {
        guard !isInteractionBlocked else { return }
        edit { current in
            guard var notes = current.notes else { return }
            let original = notes
            change(&notes)
            guard notes != original else { return }
            current.notes = notes
            current.updatedAt = Date()
        }
    }

    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptText, forType: .string)
    }

    func exportTranscript() {
        guard let document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(document.title).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(document.transcriptMarkdown.utf8).write(to: url, options: .atomic) }
        catch { self.error = "Could not export the transcript: \(error.localizedDescription)" }
    }

    func generateNotes() {
        guard canGenerateNotes, let current = document, let noteGenerator else { return }
        guard canAnalyze() else { error = "Finish the current recording, transcription, or model preparation first."; return }
        setBusy(true)
        progress = 0
        error = nil
        status = "Preparing local meeting notes…"
        let generation = UUID()
        analysisGeneration = generation
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.setBusy(false); self.operation = nil }
            do {
                var notes = try await noteGenerator(current) { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, self.isBusy, self.analysisGeneration == generation, self.operation?.isCancelled == false else { return }
                        self.progress = update.fraction
                        self.status = update.message
                    }
                }
                try Task.checkCancellation()
                notes.sourceTranscriptHash = current.transcriptFingerprint
                self.setNotes(notes)
                self.status = "Notes ready · review and edit before sharing"
            } catch is CancellationError { self.status = "Notes cancelled · your transcript is saved" }
            catch { self.error = error.localizedDescription; self.status = "Could not generate meeting notes" }
        }
    }

    private func prepareWaveform(autoTranscribe: Bool = false) {
        guard let document else { return }
        guard let url = audioURL(document) else { return }
        setBusy(true)
        status = "Preparing waveform…"
        operation = Task { [weak self] in
            guard let self else { return }
            var startAnalysis = false
            do {
                let wave = try await MeetingAnalysis.shared.waveform(audioURL: url)
                try Task.checkCancellation()
                self.document?.duration = wave.duration
                self.document?.waveform = wave.peaks
                self.status = "Recording ready"
                startAnalysis = self.persist() && autoTranscribe
                self.refreshRecent()
            } catch is CancellationError { self.status = "Preparation cancelled. Reopen the session to retry." }
            catch { self.error = error.localizedDescription; self.status = "Could not prepare recording" }
            // Complete this task before installing the transcription task. A defer
            // from waveform preparation must never clear or unlock that next task.
            self.operation = nil
            self.setBusy(false)
            if startAnalysis { self.transcribe() }
        }
    }

    func transcribe() {
        guard !isInteractionBlocked, let current = document else { return }
        guard !current.hasTextCorrections else {
            error = "This transcript has text corrections. Reset those corrections before running transcription again; speaker refinement keeps them intact."
            return
        }
        guard canAnalyze() else { error = "Finish the current recording, transcription, or model preparation first."; return }
        guard let url = audioURL(current) else { return }
        let model = modelProvider()
        setBusy(true)
        error = nil
        progress = 0
        status = "Preparing local models. The first run may download model files…"
        let generation = UUID()
        analysisGeneration = generation
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.setBusy(false); self.operation = nil }
            do {
                let result = try await self.transcriber(url, current.participantCountHint ?? 0, model) { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, self.isBusy, self.analysisGeneration == generation, self.operation?.isCancelled == false else { return }
                        self.progress = update.fraction
                        self.status = update.message
                    }
                }
                try Task.checkCancellation()
                self.edit {
                    let discovered = Set(result.regions.flatMap(\.speakerIDs)).sorted {
                        $0.localizedStandardCompare($1) == .orderedAscending
                    }
                    for id in discovered where !$0.speakers.contains(where: { $0.id == id }) {
                        let number = id.replacingOccurrences(of: "speaker-", with: "")
                        $0.speakers.append(.init(id: id, name: "Speaker \(number)"))
                    }
                    $0.applyAnalysis(regions: result.regions, words: result.words)
                    $0.acousticEvidence = result.acousticEvidence
                }
                self.status = "Draft ready · select a segment to review its speaker"
            } catch is CancellationError { self.status = "Transcription cancelled · your recording is saved" }
            catch { self.error = error.localizedDescription; self.status = "Transcription failed · your recording is saved" }
        }
    }

    func refine() {
        guard !isInteractionBlocked, let current = document else { return }
        guard canAnalyze() else { error = "Finish the current recording or transcription first."; return }
        setBusy(true)
        status = "Refining unreviewed segments…"
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.setBusy(false); self.operation = nil }
            do {
                let regions = try await MeetingAnalysis.shared.refine(document: current)
                try Task.checkCancellation()
                self.edit { $0.applyAnalysis(regions: regions) }
                self.status = "Refined · confirmed segments preserved · undo available"
            } catch is CancellationError { self.status = "Refinement cancelled" }
            catch { self.error = error.localizedDescription; self.status = "Could not refine this recording" }
        }
    }

    func cancel() { operation?.cancel(); status = "Cancelling safely…" }
    private func setBusy(_ busy: Bool) { isBusy = busy; onBusyChanged(busy || hasUnsavedEdits) }
    private func refreshRecent() { do { recent = try store.recentSessions() } catch { self.error = error.localizedDescription } }

    @discardableResult func persist() -> Bool {
        guard let document else { return true }
        do {
            let warning = try store.save(document)
            hasUnsavedEdits = false
            onBusyChanged(isBusy)
            error = warning
            return true
        } catch { hasUnsavedEdits = true; onBusyChanged(true); self.error = "Could not save your edits: \(error.localizedDescription)"; return false }
    }

    func edit(_ change: (inout MeetingDocument) -> Void) {
        guard !isExternallyLocked, var current = document else { return }
        let before = current
        change(&current)
        guard before != current else { return }
        if before.regions != current.regions || before.words != current.words
            || before.speakers != current.speakers || before.textCorrections != current.textCorrections {
            current.reviewedAt = nil
        }
        undoStack.append(before)
        if undoStack.count > 80 { undoStack.removeFirst() }
        redoStack.removeAll()
        document = current
        updateHistoryCounts()
        persist()
    }
    func undo() {
        guard !isInteractionBlocked, let previous = undoStack.popLast(), let current = document else { return }
        redoStack.append(current); document = previous
        participantCount = previous.participantCountHint ?? 0
        updateHistoryCounts(); persist()
    }
    func redo() {
        guard !isInteractionBlocked, let next = redoStack.popLast(), let current = document else { return }
        undoStack.append(current); document = next
        participantCount = next.participantCountHint ?? 0
        updateHistoryCounts(); persist()
    }
    private func resetHistory() { undoStack.removeAll(); redoStack.removeAll(); updateHistoryCounts() }
    private func updateHistoryCounts() { undoCount = undoStack.count; redoCount = redoStack.count }
    func assign(_ speakerIDs: [String]) {
        guard !isInteractionBlocked, let selectedID else { return }
        edit { _ = $0.assign(regionID: selectedID, to: speakerIDs) }
    }
    func confirm() { guard !isInteractionBlocked, let selectedID else { return }; edit { _ = $0.confirm(regionID: selectedID) } }
    func unlock() { guard !isInteractionBlocked, let selectedID else { return }; edit { _ = $0.setUncertain(regionID: selectedID) } }
    func split() {
        guard !isInteractionBlocked, let selectedID, canSplit else { return }
        edit { _ = $0.split(regionID: selectedID, at: playhead) }
    }
    func setBounds(start: Double, end: Double) {
        guard !isInteractionBlocked, let selectedID else { return }
        edit { _ = $0.setBounds(regionID: selectedID, start: start, end: end) }
    }
    func select(_ id: String, seek: Bool = true) {
        selectedID = id
        if seek, let selected { self.seek(selected.start) }
    }
    func nextUncertain() {
        guard let regions = document?.regions.sorted(by: { $0.start < $1.start }) else { return }
        let candidates = regions.filter { !$0.isConfirmed && $0.isUncertain }
        if let next = candidates.first(where: { $0.start > playhead + 0.01 }) ?? candidates.first { select(next.id) }
        else { status = "No flagged sections. Automatic assignments can still need review." }
    }
    func seek(_ time: Double) {
        playhead = min(max(0, time), document?.duration ?? 0)
        player?.currentTime = playhead
    }
    func togglePlayback() {
        if isPlaying { pause(); return }
        guard let player else { return }
        if player.currentTime >= player.duration - 0.05 { seek(0) }
        isPlaying = player.play()
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let self else { return }
                self.playhead = self.player?.currentTime ?? 0
                if self.player?.isPlaying != true { self.isPlaying = false; return }
            }
        }
    }
    func pause() { player?.pause(); isPlaying = false; playbackTask?.cancel(); playbackTask = nil }
    private func preparePlayer() {
        player = nil
        guard let document else { return }
        do { player = try AVAudioPlayer(contentsOf: try store.audioURL(for: document)); player?.prepareToPlay() }
        catch { self.error = "Playback unavailable: \(error.localizedDescription)" }
    }
    private func audioURL(_ document: MeetingDocument) -> URL? {
        do { return try store.audioURL(for: document) }
        catch { self.error = error.localizedDescription; return nil }
    }
    func revealFiles() { guard let document, let url = audioURL(document) else { return }; NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

func meetingTime(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.isFinite ? seconds : 0))
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
}
