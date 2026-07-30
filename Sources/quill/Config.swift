import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": { "enabled": true, "engine": "parakeet" },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    enum ConfigError: Error, LocalizedError {
        case malformedJSON(URL)
        case invalidRoot(URL)
        case invalidTranscription(URL)

        var errorDescription: String? {
            switch self {
            case .malformedJSON(let url):
                "\(url.path) is not valid JSON"
            case .invalidRoot(let url):
                "\(url.path) must contain a JSON object"
            case .invalidTranscription(let url):
                "\(url.path) transcription must be a JSON object"
            }
        }
    }

    private enum LoadResult {
        case missing
        case loaded([String: Any])
        case invalid(ConfigError)
    }

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Selected local transcription model. Missing and unknown identifiers
    /// resolve to v3 without rewriting the configuration.
    static func transcriptionModel(at url: URL = path) -> TranscriptionModel {
        guard case .loaded(let root) = loadResult(at: url),
              let transcription = root["transcription"] as? [String: Any],
              let raw = transcription["model"] as? String,
              let model = TranscriptionModel(rawValue: raw)
        else { return .default }
        return model
    }

    static func setTranscriptionModel(
        _ model: TranscriptionModel,
        at url: URL = path
    ) throws {
        var root: [String: Any]
        switch loadResult(at: url) {
        case .missing:
            root = [:]
        case .loaded(let loaded):
            root = loaded
        case .invalid(let error):
            throw error
        }

        let existing = root["transcription"]
        guard existing == nil || existing is [String: Any] else {
            throw ConfigError.invalidTranscription(url)
        }
        var transcription = existing as? [String: Any] ?? [:]
        transcription["model"] = model.rawValue
        root["transcription"] = transcription

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    /// Compatibility for callers migrated in the coordinator integration.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "parakeet"
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        switch loadResult(at: path) {
        case .missing:
            return nil
        case .loaded(let root):
            return root
        case .invalid:
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
    }

    private static func loadResult(at url: URL) -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .invalid(.malformedJSON(url))
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .invalid(.malformedJSON(url))
        }
        guard let root = json as? [String: Any] else {
            return .invalid(.invalidRoot(url))
        }
        return .loaded(root)
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
