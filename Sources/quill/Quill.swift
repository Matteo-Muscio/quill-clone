import AppKit
import ArgumentParser
import Combine
import Foundation

@main
struct Quill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self, Install.self, Update.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = AppController(root: root)
        controller.observeUpdateRequests()

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            "quill up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

enum RecordingIndicator: Equatable {
    case idle
    case recording
    case microphoneFailed
}

struct AppBusyState {
    var isRecording = false
    var isTranscribing = false
    var isPreparingModel = false
    var isPreparingNotesModel = false
    var hasUnsavedRecording = false
    var isPreparingUpdate = false
    var isProcessingMeeting = false
    var micHealth: MicCaptureHealth = .healthy

    var recordingIndicator: RecordingIndicator {
        guard isRecording else { return .idle }
        return micHealth == .failed ? .microphoneFailed : .recording
    }

    var modelActionsLocked: Bool {
        isRecording || isTranscribing || isPreparingUpdate || isProcessingMeeting || isPreparingNotesModel
    }

    var canStartRecording: Bool {
        !isPreparingModel && !isPreparingNotesModel && !hasUnsavedRecording && !isPreparingUpdate && !isProcessingMeeting
    }

    var canRetryTranscription: Bool {
        !isPreparingModel && !isPreparingNotesModel && !isTranscribing && !hasUnsavedRecording && !isPreparingUpdate
            && !isProcessingMeeting
    }

    var canPrepareUpdate: Bool {
        !isRecording && !isTranscribing && !isPreparingModel && !isPreparingNotesModel
            && !hasUnsavedRecording && !isPreparingUpdate && !isProcessingMeeting
    }

    mutating func finishRecording(transcriptionEnabled: Bool) {
        isRecording = false
        isTranscribing = isTranscribing || transcriptionEnabled
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let root: URL
    private let menuBar = MenuBarController()
    private let transcription: TranscriptionCoordinator
    private let modelManager: ModelManager
    private let notesManager: NotesModelManager
    private let settingsWindow: SettingsWindowController
    private var session: RecordingSession?
    private var pendingSave: RecordingSession?
    private var ticker: Timer?
    private var busyState = AppBusyState()
    private var hasNotifiedMicrophoneFailure = false
    private var cancellables: Set<AnyCancellable> = []
    private var statusTask: Task<Void, Never>?
    private let submittedWork = SubmittedCoordinatorWork()
    private var updateHandoff: UpdateHandoff?
    private var meetingWindow: MeetingWindowController?

    init(root: URL) {
        self.root = root
        let transcription = TranscriptionCoordinator()
        self.transcription = transcription
        let submittedWork = self.submittedWork
        let modelManager = ModelManager(onActivation: { [transcription, root, submittedWork] in
            submittedWork.submit { await transcription.modelDidActivate(root: root) }
        })
        self.modelManager = modelManager
        let notesManager = NotesModelManager.shared
        self.notesManager = notesManager
        self.settingsWindow = SettingsWindowController(modelManager: modelManager, notesManager: notesManager)

        let (statuses, statusContinuation) =
            AsyncStream<TranscriptionCoordinator.Status>.makeStream()
        statusTask = Task { @MainActor [weak self] in
            for await status in statuses {
                guard let self else { return }
                showTranscription(status)
            }
        }

        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
        menuBar.onOpenMeetingEditor = { [weak self] in self?.showMeetingEditor() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.onOpenSoundSettings = { [weak self] in self?.openSoundSettings() }
        menuBar.onRetrySave = { [weak self] in self?.retrySave() }
        menuBar.onRetryTranscription = { [weak self] in self?.retryTranscription() }
        menuBar.update(indicator: .idle, elapsed: nil)

        modelManager.$isPreparingModel
            .sink { [weak self] (isPreparing: Bool) in
                MainActor.assumeIsolated {
                    self?.busyState.isPreparingModel = isPreparing
                    self?.syncBusyState()
                }
            }
            .store(in: &cancellables)

        notesManager.$isPreparingModel
            .sink { [weak self] isPreparing in
                MainActor.assumeIsolated {
                    self?.busyState.isPreparingNotesModel = isPreparing
                    self?.syncBusyState()
                }
            }
            .store(in: &cancellables)

        submittedWork.submit { [transcription, root] in
            await transcription.setStatusHandler { status in
                statusContinuation.yield(status)
            }
            await transcription.resumePending(root: root)
        }
    }

    func observeUpdateRequests() {
        guard updateHandoff == nil else { return }
        updateHandoff = UpdateHandoff(
            beginReservation: { [weak self] in
                guard let self, busyState.canPrepareUpdate,
                      submittedWork.pendingCount == 0 else { return false }
                busyState.isPreparingUpdate = true
                syncBusyState()
                return true
            },
            reserveCoordinator: { @MainActor [weak self] in
                guard let self else { return false }
                return await self.transcription.reserveForUpdate()
            },
            releaseReservation: { [weak self] in
                self?.busyState.isPreparingUpdate = false
                self?.syncBusyState()
            },
            terminate: { [weak self] in
                self?.statusTask?.cancel()
                NSApp.terminate(nil)
            }
        )
        updateHandoff?.startObserving()
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        guard !busyState.isProcessingMeeting else {
            meetingWindow?.show()
            notifyUser(
                title: "quill — meeting editor is busy",
                body: "Finish or cancel the current operation and save your edits before quitting."
            )
            return
        }
        stopSession()
        guard pendingSave == nil else {
            notifyUser(
                title: "quill — recording not saved",
                body: "Use Retry saving recording before quitting. Check disk space and folder access."
            )
            return
        }
        statusTask?.cancel()
        NSApp.terminate(nil)
    }

    private func toggle() {
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    private func startSession() {
        guard busyState.canStartRecording else { return }
        do {
            busyState.micHealth = .healthy
            hasNotifiedMicrophoneFailure = false
            let newSession = try RecordingSession(root: root)
            newSession.onMicHealthChange = { [weak self] health in
                self?.handleMicHealthChange(health)
            }
            try newSession.start()
            session = newSession
            busyState.isRecording = true
            syncBusyState()
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "quill — recording failed", body: "\(error)")
            return
        }

        menuBar.update(indicator: busyState.recordingIndicator, elapsed: "0:00")
        ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Keep elapsed time current while an NSMenu is tracking input.
        if let ticker { RunLoop.main.add(ticker, forMode: .common) }
    }

    private func stopSession() {
        guard let session else { return }
        session.onMicHealthChange = nil
        let saved = save(session)
        let elapsed = Self.format((session.endedAt ?? Date()).timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        busyState.micHealth = .healthy
        hasNotifiedMicrophoneFailure = false
        busyState.finishRecording(
            transcriptionEnabled: saved && Config.transcriptionEnabled()
        )
        syncBusyState()
        ticker?.invalidate()
        ticker = nil
        menuBar.update(indicator: busyState.recordingIndicator, elapsed: nil)

        if saved {
            let dir = session.dir
            submittedWork.submit { [transcription] in await transcription.enqueue(dir) }
        }
    }

    /// Keep the stopped session alive until its metadata is safely on disk.
    private func save(_ recording: RecordingSession) -> Bool {
        do {
            try recording.stop()
            pendingSave = nil
            busyState.hasUnsavedRecording = false
            return true
        } catch {
            pendingSave = recording
            busyState.hasUnsavedRecording = true
            FileHandle.standardError.write(Data(
                "recording metadata save failed · \(recording.dir.path): \(error)\n".utf8
            ))
            notifyUser(
                title: "quill — recording not saved",
                body: "Audio capture has stopped. Check disk space and folder access, then choose Retry saving recording."
            )
            return false
        }
    }

    private func retrySave() {
        guard let pendingSave else { return }
        let saved = save(pendingSave)
        if saved {
            busyState.finishRecording(transcriptionEnabled: Config.transcriptionEnabled())
            let dir = pendingSave.dir
            submittedWork.submit { [transcription] in await transcription.enqueue(dir) }
        }
        syncBusyState()
    }

    private func retryTranscription() {
        guard busyState.canRetryTranscription, Config.transcriptionEnabled() else { return }
        submittedWork.submit { [transcription, root] in await transcription.resumePending(root: root) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            busyState.isTranscribing = false
            modelManager.pendingCount = 0
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            busyState.isTranscribing = true
            modelManager.pendingCount = 0
            menuBar.updateTranscription(
                queued > 0 ? "Transcribing \(name) · \(queued) queued" : "Transcribing \(name)"
            )
        case .failed(let name):
            busyState.isTranscribing = false
            modelManager.pendingCount = 0
            menuBar.updateTranscription("Transcription failed · \(name)")
        case .waitingForModel(let pending):
            busyState.isTranscribing = false
            modelManager.pendingCount = pending
            menuBar.updateTranscription(
                pending == 1
                    ? "1 recording waiting for a model"
                    : "\(pending) recordings waiting for a model",
                needsModel: true
            )
        }
        syncBusyState()
    }

    private func syncBusyState() {
        // Freeze new edits before the updater yields to the transcription
        // coordinator; no import/save can race the final cooperative exit.
        meetingWindow?.model.isExternallyLocked = busyState.isPreparingUpdate
        modelManager.actionsLocked = busyState.modelActionsLocked
        notesManager.actionsLocked = busyState.isRecording || busyState.isTranscribing
            || busyState.isPreparingModel || busyState.isPreparingUpdate || busyState.isProcessingMeeting
        menuBar.updateModelPreparation(
            busyState.isPreparingModel || busyState.isPreparingNotesModel || busyState.isProcessingMeeting,
            recording: busyState.isRecording,
            hasUnsavedRecording: busyState.hasUnsavedRecording
        )
        menuBar.updatePendingSave(pendingSave?.dir.lastPathComponent)
        menuBar.updateRetryTranscription(
            enabled: busyState.canRetryTranscription && Config.transcriptionEnabled()
        )
    }

    private func tick() {
        guard let session else { return }
        menuBar.update(
            indicator: busyState.recordingIndicator,
            elapsed: Self.format(Date().timeIntervalSince(session.startedAt))
        )
    }

    private func handleMicHealthChange(_ health: MicCaptureHealth) {
        let wasFailed = busyState.micHealth == .failed
        busyState.micHealth = health
        menuBar.update(
            indicator: busyState.recordingIndicator,
            elapsed: session.map { Self.format(Date().timeIntervalSince($0.startedAt)) }
        )
        if health == .failed && !wasFailed && !hasNotifiedMicrophoneFailure {
            hasNotifiedMicrophoneFailure = true
            notifyUser(
                title: "quill - microphone unavailable",
                body: "System audio is still recording. Choose a microphone in Sound Settings."
            )
        }
    }

    private func openSoundSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") else {
            FileHandle.standardError.write(Data("sound settings URL is invalid\n".utf8))
            return
        }
        if !NSWorkspace.shared.open(url) {
            FileHandle.standardError.write(Data("failed to open Sound Settings\n".utf8))
        }
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private func showMeetingEditor() {
        guard !busyState.isPreparingUpdate else { return }
        if meetingWindow == nil {
            meetingWindow = MeetingWindowController(
                root: root,
                modelProvider: { Config.transcriptionModel() },
                canAnalyze: { [weak self] in
                    guard let self else { return false }
                    return busyState.canPrepareUpdate && submittedWork.pendingCount == 0
                },
                onBusyChanged: { [weak self] busy in
                    self?.busyState.isProcessingMeeting = busy
                    self?.syncBusyState()
                }
            )
            meetingWindow?.model.noteGenerator = { [weak self] document, progress in
                guard let self else { throw CancellationError() }
                return try await MeetingNotesEngine.shared.generate(
                    transcript: document.transcriptMarkdown,
                    model: self.notesManager.activeModel,
                    progress: progress
                )
            }
            meetingWindow?.model.onOpenNotesSettings = { [weak self] in self?.settingsWindow.show() }
        }
        meetingWindow?.show()
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
