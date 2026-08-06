@preconcurrency import AVFoundation
import Foundation

enum MicCaptureHealth: String, Codable, Equatable, Sendable {
    case healthy
    case reconnecting
    case failed
}

struct MicInterruption: Codable, Equatable, Sendable {
    let startedAt: Date
    var endedAt: Date?
}

struct MicRecoveryState: Equatable, Sendable {
    private(set) var health: MicCaptureHealth = .healthy
    private(set) var interruptions: [MicInterruption] = []

    mutating func captureLost(at date: Date) {
        guard interruptions.last?.endedAt != nil || interruptions.isEmpty else {
            health = .reconnecting
            return
        }
        interruptions.append(.init(startedAt: date, endedAt: nil))
        health = .reconnecting
    }

    mutating func recoveryTimedOut() {
        guard health == .reconnecting, interruptions.last?.endedAt == nil else { return }
        health = .failed
    }
    mutating func retryRecovery() { health = .reconnecting }

    mutating func captureResumed(at date: Date) {
        closeOpenInterruption(at: date)
        health = .healthy
    }

    mutating func finish(at date: Date) {
        closeOpenInterruption(at: date)
    }

    private mutating func closeOpenInterruption(at date: Date) {
        guard let index = interruptions.indices.last,
              interruptions[index].endedAt == nil else { return }
        interruptions[index].endedAt = date
    }
}

/// Records the default input device to a file via AVAudioEngine, encoding AAC
/// mono. Buffers stream straight to disk — nothing is held in memory, so
/// session length is unbounded.
///
/// With voice processing on (the default), Apple's echo canceller subtracts
/// speaker playback from the mic so the system track doesn't bleed into the
/// mic track. VoiceProcessingIO is a duplex unit, not an input effect: it
/// needs a rendered output path and one explicit mono client format on both
/// sides, or it silently delivers zeroed buffers (rca-001). A first-second
/// liveness check catches routes where even the correct graph stays silent
/// and restarts capture raw.
final class MicRecorder: @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case engineStartFailed(Error)
        case fileCreationFailed(Error)
        case formatUnsupported(AVAudioFormat)

        var description: String {
            switch self {
            case .engineStartFailed(let e): return "mic engine start failed: \(e)"
            case .fileCreationFailed(let e): return "mic file creation failed: \(e)"
            case .formatUnsupported(let f): return "can't downmix mic format \(f)"
            }
        }
    }

    private var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var url: URL?
    private var silenceWrittenThrough: Date?
    private var hasCapturedUsefulAudio = false
    private var acceptsTapWrites = false
    private(set) var isRecording = false
    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    private(set) var firstBufferAt: Date?

    // Liveness check state (voice-processing path only). Written from the tap
    // callback, read on main when deciding to fall back.
    private var livenessFrames = 0
    private var livenessPeak: Float = 0
    private var livenessSettled = false

    /// Start capturing the mic, encoding AAC into `url` (use a .caf extension
    /// — CAF needs no finalization pass, so a crash loses nothing written).
    func start(writingTo url: URL) throws {
        guard !isRecording else { return }
        self.url = url
        engine = AVAudioEngine()
        do {
            try createFile(for: engine.inputNode.outputFormat(forBus: 0))
            try attach(voiceProcessing: Config.micVoiceProcessing())
            isRecording = true
        } catch {
            file = nil
            throw error
        }
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        acceptsTapWrites = false
        isRecording = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        file = nil
        silenceWrittenThrough = nil
        hasCapturedUsefulAudio = false
    }

    // MARK: -

    /// Creates the session's one stable output format. Later engine
    /// attachments always convert their current route format into this file.
    private func createFile(for inputFormat: AVAudioFormat) throws {
        guard let url else { return }
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: monoFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: monoFormat.commonFormat,
                interleaved: monoFormat.isInterleaved
            )
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }
    }

    /// Build the engine graph and attach it to the already-open microphone
    /// file. This is reusable after an input route changes without truncating
    /// audio that has already been captured.
    private func attach(
        voiceProcessing: Bool,
        writingRecoverySilenceFor gap: DateInterval? = nil
    ) throws {
        let input = engine.inputNode
        guard let outputFormat = file?.processingFormat else { return }

        acceptsTapWrites = false
        var voice = voiceProcessing
        if voice {
            do {
                try input.setVoiceProcessingEnabled(true)
                // The live voice unit makes macOS treat the session like a
                // call and duck all other audio — meetings played through the
                // speakers would get quieter the moment recording starts.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: mic voice processing unavailable (\(error)) — recording raw mic\n".utf8
                ))
                voice = false
            }
        }
        let inputFormat = input.outputFormat(forBus: 0)

        // One explicit mono client format. With voice processing this is the
        // Voice I/O boundary format on both sides of the duplex unit — never
        // accept the inherited multichannel route format (a 9-channel device
        // yielded digital silence). Raw capture downmixes to the same shape;
        // speech models want one channel anyway.
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }

        if voice {
            // Complete the duplex graph: VoiceProcessingIO must render to an
            // output device or the input side never produces audio. The mixer
            // has no sources — nothing is monitored or played — its connection
            // exists solely to give the unit a formatted output path.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: monoFormat)
            livenessFrames = 0
            livenessPeak = 0
            livenessSettled = false
            try installVoiceTap(on: input, tapFormat: monoFormat, outputFormat: outputFormat)
        } else {
            try installRawTap(on: input, inputFormat: inputFormat, outputFormat: outputFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineStartFailed(error)
        }

        do {
            if let gap {
                try writeSilence(for: gap)
            }
        } catch {
            engine.stop()
            input.removeTap(onBus: 0)
            throw error
        }
        acceptsTapWrites = true

        let report = "mic: voiceProcessing=\(input.isVoiceProcessingEnabled) "
            + "input=\(input.outputFormat(forBus: 0)) tap=\(monoFormat) output=\(outputFormat)\n"
        FileHandle.standardError.write(Data(report.utf8))
    }

    /// Voice-processing path: the unit converts to the mono client format
    /// itself. The resulting buffers still pass through a converter because
    /// the stable file format may belong to a previous hardware route.
    private func installVoiceTap(
        on input: AVAudioInputNode,
        tapFormat: AVAudioFormat,
        outputFormat: AVAudioFormat
    ) throws {
        guard let converter = AVAudioConverter(from: tapFormat, to: outputFormat) else {
            throw RecorderError.formatUnsupported(tapFormat)
        }
        let tapBufferSize: AVAudioFrameCount = 4_096
        let outputCapacity = Self.convertedFrameCapacity(
            inputFrames: tapBufferSize,
            inputRate: tapFormat.sampleRate,
            outputRate: outputFormat.sampleRate
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            throw RecorderError.formatUnsupported(outputFormat)
        }
        let checkFrames = Int(tapFormat.sampleRate)
        input.installTap(onBus: 0, bufferSize: tapBufferSize, format: tapFormat) { [weak self] buffer, _ in
            guard let self, self.acceptsTapWrites, let file = self.file else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }

            if !self.livenessSettled {
                let frames = Int(buffer.frameLength)
                if let data = buffer.floatChannelData?[0] {
                    for i in 0..<frames {
                        self.livenessPeak = max(self.livenessPeak, abs(data[i]))
                    }
                }
                self.livenessFrames += frames
                if self.livenessFrames >= checkFrames {
                    self.livenessSettled = true
                    if self.livenessPeak == 0 {
                        DispatchQueue.main.async { self.fallBackToRaw() }
                        return
                    }
                    self.hasCapturedUsefulAudio = true
                }
            }

            do {
                try self.write(buffer, with: converter, into: output, to: file)
            } catch {
                FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
            }
        }
    }

    /// Raw path: tap at the device's native format and convert it to the
    /// stable file format, downmixing and resampling in the same operation.
    private func installRawTap(
        on input: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat
    ) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }
        let tapBufferSize: AVAudioFrameCount = 4_096
        let outputCapacity = Self.convertedFrameCapacity(
            inputFrames: tapBufferSize,
            inputRate: inputFormat.sampleRate,
            outputRate: outputFormat.sampleRate
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            throw RecorderError.formatUnsupported(outputFormat)
        }
        input.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self, self.acceptsTapWrites, let file = self.file else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            do {
                try self.write(buffer, with: converter, into: output, to: file)
                self.hasCapturedUsefulAudio = true
            } catch {
                FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
            }
        }
    }

    private func write(
        _ input: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        into output: AVAudioPCMBuffer,
        to file: AVAudioFile
    ) throws {
        let status = try Self.convert(input, with: converter, to: output)
        guard status == .haveData || status == .inputRanDry else { return }
        guard output.frameLength > 0 else { return }
        try file.write(from: output)
    }

    static func convert(
        _ input: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to output: AVAudioPCMBuffer
    ) throws -> AVAudioConverterOutputStatus {
        output.frameLength = 0
        if converter.primeMethod != .none {
            converter.primeMethod = .none
        }

        // AVAudioConverter invokes this provider synchronously during convert.
        nonisolated(unsafe) var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        if let conversionError {
            throw conversionError
        }
        return status
    }

    static func convertedFrameCapacity(
        inputFrames: AVAudioFrameCount,
        inputRate: Double,
        outputRate: Double
    ) -> AVAudioFrameCount {
        guard inputRate > 0, outputRate > 0 else { return 0 }
        return AVAudioFrameCount(ceil(Double(inputFrames) * outputRate / inputRate))
    }

    static func silenceFrameCount(seconds: TimeInterval, sampleRate: Double) -> AVAudioFrameCount {
        AVAudioFrameCount(max(0, (seconds * sampleRate).rounded()))
    }

    /// Materializes a recovered wall-clock gap into the stable file format.
    /// Chunks are capped at one second so a long disconnection never requires
    /// a large temporary PCM allocation. Repeated recovery attempts resume at
    /// `silenceWrittenThrough` instead of writing the same gap twice.
    private func writeSilence(for gap: DateInterval) throws {
        guard let file else { return }
        let format = file.processingFormat
        guard format.sampleRate > 0 else { return }

        let start = max(gap.start, silenceWrittenThrough ?? gap.start)
        guard gap.end > start else { return }

        var remaining = Self.silenceFrameCount(
            seconds: gap.end.timeIntervalSince(start),
            sampleRate: format.sampleRate
        )
        let maxChunkFrames = max(1, AVAudioFrameCount(format.sampleRate.rounded(.down)))
        var writtenThrough = start

        while remaining > 0 {
            let frames = min(remaining, maxChunkFrames)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw RecorderError.formatUnsupported(format)
            }
            buffer.frameLength = frames
            for channel in 0..<Int(format.channelCount) {
                buffer.floatChannelData?[channel].update(repeating: 0, count: Int(frames))
            }
            try file.write(from: buffer)
            remaining -= frames
            writtenThrough = writtenThrough.addingTimeInterval(Double(frames) / format.sampleRate)
            silenceWrittenThrough = writtenThrough
        }

        silenceWrittenThrough = gap.end
    }

    /// The voice-processing route delivered a full second of digital silence:
    /// tear the engine down and restart raw, discarding the silent prefix so
    /// the track's timestamps start at real audio.
    private func fallBackToRaw() {
        guard isRecording else { return }
        FileHandle.standardError.write(Data(
            "warning: voice processing delivered silence — restarting mic raw\n".utf8
        ))
        acceptsTapWrites = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        let recreateFile = !hasCapturedUsefulAudio
        if recreateFile {
            file = nil
            firstBufferAt = nil
            silenceWrittenThrough = nil
            if let url {
                try? FileManager.default.removeItem(at: url)
            }
        }
        engine = AVAudioEngine()
        do {
            if recreateFile {
                try createFile(for: engine.inputNode.outputFormat(forBus: 0))
            }
            try attach(voiceProcessing: false)
        } catch {
            FileHandle.standardError.write(Data(
                "mic raw fallback failed: \(error) — session continues without mic track\n".utf8
            ))
            if recreateFile { file = nil }
        }
    }
}
