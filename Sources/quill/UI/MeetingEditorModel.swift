import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

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
    @Published var participantCount = 2
    @Published private(set) var undoCount = 0
    @Published private(set) var redoCount = 0
    private let store: MeetingStore
    private let modelProvider: () -> TranscriptionModel
    private let canAnalyze: () -> Bool
    private let onBusyChanged: (Bool) -> Void
    private var operation: Task<Void, Never>?
    private var analysisGeneration = UUID()
    private var player: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?
    private var hasUnsavedEdits = false
    private var undoStack: [MeetingDocument] = []
    private var redoStack: [MeetingDocument] = []

    init(root: URL, modelProvider: @escaping () -> TranscriptionModel,
         canAnalyze: @escaping () -> Bool = { true }, onBusyChanged: @escaping (Bool) -> Void = { _ in }) {
        store = MeetingStore(root: root)
        self.modelProvider = modelProvider
        self.canAnalyze = canAnalyze
        self.onBusyChanged = onBusyChanged
        refreshRecent()
    }

    var selected: MeetingRegion? { document?.regions.first { $0.id == selectedID } }
    var isInteractionBlocked: Bool { isBusy || isExternallyLocked }
    var hasAnalysis: Bool { !(document?.regions.isEmpty ?? true) }
    var isPlaybackAvailable: Bool { player != nil }
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
            participantCount = 2
            configureSpeakers()
            refreshRecent()
            resetHistory()
            selectedID = nil
            playhead = 0
            zoom = 1
            preparePlayer()
            prepareWaveform()
        } catch { self.error = error.localizedDescription }
    }

    func open(_ id: String) {
        guard !isInteractionBlocked, persist() else { return }
        do {
            pause()
            document = try store.load(id: id)
            error = nil
            participantCount = max(1, document?.speakers.count ?? 2)
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
        guard !isInteractionBlocked, document != nil, !hasAnalysis else { return }
        let count = min(9, max(1, participantCount))
        participantCount = count
        edit { current in
            let speakers = (0..<count).map { index in
                current.speakers.first { $0.id == "speaker-\(index + 1)" }
                    ?? MeetingSpeaker(id: "speaker-\(index + 1)", name: "Speaker \(index + 1)")
            }
            if speakers != current.speakers {
                current.speakers = speakers
                current.updatedAt = Date()
            }
        }
    }

    func rename(_ id: String, _ name: String) {
        edit { _ = $0.renameSpeaker(id: id, name: name) }
    }

    private func prepareWaveform() {
        guard let document else { return }
        guard let url = audioURL(document) else { return }
        setBusy(true)
        status = "Preparing waveform…"
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.setBusy(false); self.operation = nil }
            do {
                let wave = try await MeetingAnalysis.shared.waveform(audioURL: url)
                try Task.checkCancellation()
                self.document?.duration = wave.duration
                self.document?.waveform = wave.peaks
                self.status = "Ready · choose participants, then transcribe"
                self.persist()
                self.refreshRecent()
            } catch is CancellationError { self.status = "Preparation cancelled. Reopen the session to retry." }
            catch { self.error = error.localizedDescription; self.status = "Could not prepare recording" }
        }
    }

    func transcribe() {
        guard !isInteractionBlocked, let current = document else { return }
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
                let result = try await MeetingAnalysis.shared.analyze(audioURL: url, participantCount: current.speakers.count, model: model) { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, self.isBusy, self.analysisGeneration == generation, self.operation?.isCancelled == false else { return }
                        self.progress = update.fraction
                        self.status = update.message
                    }
                }
                try Task.checkCancellation()
                self.edit {
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
        participantCount = max(1, previous.speakers.count)
        updateHistoryCounts(); persist()
    }
    func redo() {
        guard !isInteractionBlocked, let next = redoStack.popLast(), let current = document else { return }
        undoStack.append(current); document = next
        participantCount = max(1, next.speakers.count)
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
