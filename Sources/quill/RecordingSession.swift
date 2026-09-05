import Foundation

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus a meta.json written on clean stop. Tracks
/// are separate on purpose — whisper does better on clean single-source audio,
/// and two tracks give free two-party diarization.
final class RecordingSession {
    let dir: URL
    let startedAt = Date()
    private(set) var endedAt: Date?
    private var finalizedMetadata: Data?

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()

    var onMicHealthChange: (@MainActor @Sendable (MicCaptureHealth) -> Void)? {
        didSet { mic.onHealthChange = onMicHealthChange }
    }

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy.MM.dd-HHmm, suffixed on
    /// collision) without starting capture yet.
    init(root: URL) throws {
        let base = Self.folderFormat.string(from: startedAt)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
    }

    /// Start both tracks. If the mic fails after the system tap started, the
    /// tap is torn down so we never run half a session silently.
    func start() throws {
        try system.start(writingTo: dir.appendingPathComponent("system.caf"))
        do {
            try mic.start(writingTo: dir.appendingPathComponent("mic.caf"))
        } catch {
            system.stop()
            throw error
        }
    }

    /// Stop capture once, then save atomically. A failed save can be retried
    /// without changing the recording's end time or losing its capture metadata.
    func stop() throws {
        if endedAt == nil {
            mic.stop()
            system.stop()
            endedAt = Date()
        }
        if finalizedMetadata == nil {
            let meta = Self.makeMetadata(
                startedAt: startedAt,
                endedAt: endedAt!,
                micFirstBufferAt: mic.firstBufferAt,
                systemFirstBufferAt: system.firstBufferAt,
                recoveryState: mic.recoveryState,
                initialInput: mic.initialInput
            )
            finalizedMetadata = try JSONSerialization.data(
                withJSONObject: meta,
                options: [.prettyPrinted, .sortedKeys]
            )
        }
        try finalizedMetadata!.write(
            to: dir.appendingPathComponent("meta.json"), options: .atomic
        )
    }

    static func makeMetadata(
        startedAt: Date,
        endedAt: Date,
        micFirstBufferAt: Date?,
        systemFirstBufferAt: Date?,
        recoveryState: MicRecoveryState,
        initialInput: InputDescription?
    ) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let micStart = micFirstBufferAt ?? startedAt
        let systemStart = systemFirstBufferAt ?? startedAt
        let earliest = min(micStart, systemStart)
        let finalStatus: MicCaptureHealth = micFirstBufferAt == nil || recoveryState.health != .healthy
            ? .failed
            : .healthy

        var microphone: [String: Any] = [
            "partial": micFirstBufferAt == nil || finalStatus == .failed
                || !recoveryState.interruptions.isEmpty,
            "final_status": finalStatus.rawValue,
            "interruptions": recoveryState.interruptions.map { interruption in
                [
                    "started": iso.string(from: interruption.startedAt),
                    "ended": iso.string(from: interruption.endedAt ?? endedAt),
                ]
            },
        ]
        if let initialInput {
            microphone["initial_device"] = [
                "name": initialInput.name,
                "uid": initialInput.uid,
                "sample_rate": initialInput.sampleRate,
                "channels": initialInput.channelCount,
            ]
        }

        return [
            "started": iso.string(from: startedAt),
            "ended": iso.string(from: endedAt),
            "duration_seconds": Int(endedAt.timeIntervalSince(startedAt)),
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": [
                "mic": Int(micStart.timeIntervalSince(earliest) * 1000),
                "system": Int(systemStart.timeIntervalSince(earliest) * 1000),
            ],
            "microphone": microphone,
        ]
    }
}
