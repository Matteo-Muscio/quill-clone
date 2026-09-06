import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
        case waitingForModel(pending: Int)
    }

    private var queue: [URL] = []
    private var inFlight: URL?
    private var draining = false
    private var reservedForUpdate = false
    private var waitingPendingCount: Int?
    private var engine: TranscriptionEngine?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?
    private let transcriptionEnabled: @Sendable () -> Bool
    private let selectedModel: @Sendable () -> TranscriptionModel
    private let isModelInstalled: @Sendable (TranscriptionModel) async throws -> Bool
    private let makeEngine: @Sendable (TranscriptionModel) -> TranscriptionEngine
    private let notification: @Sendable (String, String) -> Void
    private let onStop: @Sendable () -> String?

    init(
        transcriptionEnabled: @escaping @Sendable () -> Bool = {
            Config.transcriptionEnabled()
        },
        selectedModel: @escaping @Sendable () -> TranscriptionModel = {
            Config.transcriptionModel()
        },
        isModelInstalled: @escaping @Sendable (TranscriptionModel) async throws -> Bool = {
            try await ModelStore.shared.isInstalled($0)
        },
        makeEngine: @escaping @Sendable (TranscriptionModel) -> TranscriptionEngine = {
            ParakeetEngine(model: $0)
        },
        notification: @escaping @Sendable (String, String) -> Void = {
            notifyUser(title: $0, body: $1)
        },
        onStop: @escaping @Sendable () -> String? = { Config.onStop() }
    ) {
        self.transcriptionEnabled = transcriptionEnabled
        self.selectedModel = selectedModel
        self.isModelInstalled = isModelInstalled
        self.makeEngine = makeEngine
        self.notification = notification
        self.onStop = onStop
    }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Reserve an actually idle coordinator without an actor suspension point.
    /// Missing-model sessions are durable and recover on restart; active work
    /// and engine release must finish before the app can exit.
    func reserveForUpdate() -> Bool {
        guard !reservedForUpdate, inFlight == nil, !draining,
              queue.isEmpty || waitingPendingCount != nil else {
            return false
        }
        reservedForUpdate = true
        return true
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        // The session is already durable; restart recovery will pick it up.
        guard !reservedForUpdate else { return }
        if !draining { lastFailure = nil }
        queueIfPending(sessionDir)
        finishQueueUpdate()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard !reservedForUpdate, transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        if !draining { lastFailure = nil }
        let pending = entries.filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending {
            queueIfPending(dir)
        }
        finishQueueUpdate()
    }

    func modelDidActivate(root: URL) {
        resumePending(root: root)
    }

    // MARK: -

    /// Validate the completion marker instead of trusting mere file presence.
    /// Older versions could publish JSON before failing to write Markdown.
    private func queueIfPending(_ sessionDir: URL) {
        let dir = sessionDir.standardizedFileURL
        guard dir != inFlight, !queue.contains(dir) else { return }
        if let transcript = Transcript.read(from: dir) {
            do {
                let markdown = dir.appendingPathComponent("transcript.md")
                let isFile = try? markdown.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile
                if isFile != true {
                    try transcript.writeMarkdown(to: dir)
                    log(dir, "repaired readable transcript from canonical JSON")
                    if lastFailure == dir.lastPathComponent { lastFailure = nil }
                }
            } catch {
                reportFailure(dir, error)
            }
            return
        }
        queue.append(dir)
    }

    private func reportFailure(_ dir: URL, _ error: Error) {
        log(dir, "transcription failed: \(error)")
        lastFailure = dir.lastPathComponent
        notification(
            "quill — transcription failed",
            "\(dir.lastPathComponent) — see transcribe.log"
        )
    }

    private func finishQueueUpdate() {
        if !draining, queue.isEmpty {
            publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        }
        drainIfIdle()
    }

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let model = selectedModel()
            let installed = (try? await isModelInstalled(model)) == true
            guard model == selectedModel() else { continue }
            guard installed else {
                draining = false
                let pending = queue.count
                let startedWaiting = waitingPendingCount == nil
                if waitingPendingCount != pending {
                    waitingPendingCount = pending
                    publish(.waitingForModel(pending: queue.count))
                }
                if startedWaiting {
                    notification(
                        "quill — transcription waiting",
                        "\(queue.count) recording(s) waiting — open Settings to download a model"
                    )
                }
                return
            }

            waitingPendingCount = nil
            let dir = queue.removeFirst()
            inFlight = dir
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                let warning = try await transcribe(dir, model: model)
                let body = warning.map { "\(dir.lastPathComponent) — \($0)" }
                    ?? dir.lastPathComponent
                notification("quill — transcript ready", body)
                runHook(for: dir)
            } catch {
                reportFailure(dir, error)
            }
            inFlight = nil
        }
        await engine?.release()
        engine = nil
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    private func transcribe(_ dir: URL, model: TranscriptionModel) async throws -> String? {
        let meta = try SessionMeta.read(from: dir)
        let engine = try await preparedEngine(for: model)

        var merged: [Transcript.Segment] = []
        var successfulTracks = 0
        var failedTracks: [String] = []
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                failedTracks.append(track.file)
                continue
            }
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                failedTracks.append(track.file)
                continue
            }
            successfulTracks += 1
            let offset = TimeInterval(track.offsetMs) / 1000
            merged += segments.map {
                Transcript.Segment(
                    speaker: track.speaker,
                    start_ms: Int(($0.start + offset) * 1000),
                    end_ms: Int(($0.end + offset) * 1000),
                    text: $0.text
                )
            }
        }
        guard successfulTracks > 0 else {
            throw TranscriptionError.noSuccessfulTracks
        }
        merged.sort { $0.start_ms < $1.start_ms }
        var warnings: [String] = []
        if meta.microphonePartial {
            warnings.append("microphone capture was incomplete and some of the user's speech may be missing.")
        }
        if !failedTracks.isEmpty {
            warnings.append("audio could not be transcribed from: \(failedTracks.joined(separator: ", ")). Some speech may be missing.")
        }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            partial: !warnings.isEmpty,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: " "),
            segments: merged
        )
        try transcript.write(to: dir)
        log(dir, "done — \(merged.count) segments")
        if !failedTracks.isEmpty { return "audio is incomplete" }
        return meta.microphonePartial ? "microphone audio is incomplete" : nil
    }

    private enum TranscriptionError: Error, CustomStringConvertible {
        case noSuccessfulTracks

        var description: String {
            "no audio tracks were successfully transcribed; recording remains pending for retry"
        }
    }

    private func preparedEngine(for model: TranscriptionModel) async throws
        -> TranscriptionEngine
    {
        if let engine {
            if engine.model == model.provenance {
                return engine
            }
            self.engine = nil
            await engine.release()
        }
        let engine = makeEngine(model)
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
private struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let tracks: [Track]
    let microphonePartial: Bool

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, speaker: "them", offsetMs: offsets["system"] ?? 0))
        }
        let microphone = json["microphone"] as? [String: Any]
        let interruptions = microphone?["interruptions"] as? [[String: Any]] ?? []
        return SessionMeta(
            tracks: tracks,
            microphonePartial: (microphone?["partial"] as? Bool ?? false)
                || !interruptions.isEmpty
        )
    }
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized.
private struct Transcript: Codable {
    struct Segment: Codable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    let engine: String
    let model: String
    let created_at: String
    let partial: Bool
    let warning: String?
    let segments: [Segment]

    enum CodingKeys: String, CodingKey {
        case engine, model, created_at, partial, warning, segments
    }

    init(engine: String, model: String, created_at: String, partial: Bool,
         warning: String?, segments: [Segment]) {
        self.engine = engine
        self.model = model
        self.created_at = created_at
        self.partial = partial
        self.warning = warning
        self.segments = segments
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        engine = try values.decode(String.self, forKey: .engine)
        model = try values.decode(String.self, forKey: .model)
        created_at = try values.decode(String.self, forKey: .created_at)
        partial = try values.decodeIfPresent(Bool.self, forKey: .partial) ?? false
        warning = try values.decodeIfPresent(String.self, forKey: .warning)
        segments = try values.decode([Segment].self, forKey: .segments)
    }

    static func read(from dir: URL) -> Transcript? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    /// Publish Markdown first and the canonical completion marker last. A
    /// failed write leaves the session retryable; each file write is atomic.
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try writeMarkdown(to: dir)
        try data.write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
    }

    func writeMarkdown(to dir: URL) throws {
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", ""]
        if partial {
            lines += [
                "Warning: \(warning ?? "audio is incomplete and some speech may be missing.")",
                "",
            ]
        }
        lines += ["engine: \(engine) (\(model))", ""]
        for seg in segments {
            lines.append("**[\(Self.clock(seg.start_ms))] \(seg.speaker):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
