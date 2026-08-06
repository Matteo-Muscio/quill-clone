@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Synchronization

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

struct InputDescription: Equatable, Sendable {
    let name: String
    let uid: String
    let sampleRate: Double
    let channelCount: UInt32
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
    private let hasCapturedUsefulAudio = Atomic<Bool>(false)
    private let acceptsTapWrites = Atomic<Bool>(false)
    private let firstBufferAtBits = Atomic<UInt64>(0)
    private let lastBufferAtBits = Atomic<UInt64>(0)
    private let awaitingRecoveryBuffer = Atomic<Bool>(false)
    private let generationBits = Atomic<UInt64>(0)
    private(set) var isRecording = false
    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    private(set) var firstBufferAt: Date?
    private(set) var recoveryState = MicRecoveryState()
    private(set) var initialInput: InputDescription?
    var onHealthChange: (@MainActor @Sendable (MicCaptureHealth) -> Void)?

    private var activeInput: InputDescription?
    private var recordingStartedAt: Date?
    private var recoveryGapStartedAt: Date?
    private var recoveryDeadline: Date?
    private var recoveryGeneration = 0
    private var configurationObserver: NSObjectProtocol?
    private var watchdog: Timer?

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
        recoveryGeneration &+= 1
        generationBits.store(UInt64(bitPattern: Int64(recoveryGeneration)), ordering: .releasing)
        recoveryState = MicRecoveryState()
        initialInput = nil
        activeInput = nil
        recordingStartedAt = Date()
        recoveryGapStartedAt = nil
        recoveryDeadline = nil
        firstBufferAt = nil
        firstBufferAtBits.store(0, ordering: .releasing)
        lastBufferAtBits.store(0, ordering: .releasing)
        hasCapturedUsefulAudio.store(false, ordering: .releasing)
        awaitingRecoveryBuffer.store(false, ordering: .releasing)
        engine = AVAudioEngine()
        do {
            try createFile(for: engine.inputNode.outputFormat(forBus: 0))
            try attach(voiceProcessing: Config.micVoiceProcessing())
            isRecording = true
            startWatchdog()
        } catch {
            tearDownEngine()
            file = nil
            throw error
        }
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        recoveryGeneration &+= 1
        generationBits.store(UInt64(bitPattern: Int64(recoveryGeneration)), ordering: .releasing)
        watchdog?.invalidate()
        watchdog = nil
        acceptsTapWrites.store(false, ordering: .releasing)
        recoveryState.finish(at: Date())
        tearDownEngine()
        file = nil
        silenceWrittenThrough = nil
        hasCapturedUsefulAudio.store(false, ordering: .releasing)
        awaitingRecoveryBuffer.store(false, ordering: .releasing)
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

        acceptsTapWrites.store(false, ordering: .releasing)
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
        let inputDescription = Self.defaultInputDescription()
        if initialInput == nil { initialInput = inputDescription }
        activeInput = inputDescription

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
        observeConfigurationChanges(for: engine)
        do {
            try engine.start()
        } catch {
            removeConfigurationObserver()
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
        acceptsTapWrites.store(true, ordering: .releasing)

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
            guard let self,
                  self.acceptsTapWrites.load(ordering: .acquiring),
                  let file = self.file else { return }
            let capturedAtBits = Self.currentDateBits()
            self.lastBufferAtBits.store(capturedAtBits, ordering: .releasing)
            self.recordFirstBufferIfNeeded(at: capturedAtBits)
            self.recordRecoveryBufferIfNeeded(at: capturedAtBits)

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
                    self.hasCapturedUsefulAudio.store(true, ordering: .releasing)
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
            guard let self,
                  self.acceptsTapWrites.load(ordering: .acquiring),
                  let file = self.file else { return }
            let capturedAtBits = Self.currentDateBits()
            self.lastBufferAtBits.store(capturedAtBits, ordering: .releasing)
            self.recordFirstBufferIfNeeded(at: capturedAtBits)
            self.recordRecoveryBufferIfNeeded(at: capturedAtBits)
            do {
                try self.write(buffer, with: converter, into: output, to: file)
                self.hasCapturedUsefulAudio.store(true, ordering: .releasing)
            } catch {
                FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
            }
        }
    }

    // MARK: - Route recovery

    private func observeConfigurationChanges(for observedEngine: AVAudioEngine) {
        removeConfigurationObserver()
        let generation = recoveryGeneration
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: observedEngine,
            queue: nil
        ) { [weak self] _ in
            // Apple can deliver this while the engine owns an internal graph
            // lock. Deferring all teardown prevents releasing the engine from
            // inside that callback.
            DispatchQueue.main.async {
                self?.engineConfigurationChanged(generation: generation)
            }
        }
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    private func startWatchdog() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.watchdog?.invalidate()
            let watchdog = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                self?.watchdogFired()
            }
            RunLoop.main.add(watchdog, forMode: .common)
            self.watchdog = watchdog
        }
    }

    private func watchdogFired() {
        guard isRecording else { return }
        let now = Date()

        if recoveryState.health == .failed {
            if Self.inputRouteChanged(from: activeInput, to: Self.defaultInputDescription()) {
                beginRecovery(at: recoveryGapStartedAt ?? now, retryingFailedRecovery: true)
            }
            return
        }

        if recoveryState.health == .reconnecting {
            if let recoveryDeadline, now >= recoveryDeadline {
                failRecovery(generation: recoveryGeneration)
            }
            return
        }

        let lastBuffer = lastBufferAtBits.load(ordering: .acquiring)
        let lastBufferAt = Self.date(from: lastBuffer)
        if !engine.isRunning || Self.captureIsStale(
            startedAt: recordingStartedAt ?? now,
            lastBufferAt: lastBufferAt,
            now: now,
            timeout: 2
        ) {
            beginRecovery(at: Self.date(from: lastBuffer) ?? recordingStartedAt ?? now)
        }
    }

    private func engineConfigurationChanged(generation: Int) {
        guard isRecording, generation == recoveryGeneration else { return }
        guard recoveryState.health != .reconnecting else { return }
        beginRecovery(
            at: Self.date(from: lastBufferAtBits.load(ordering: .acquiring))
                ?? recordingStartedAt
                ?? Date(),
            retryingFailedRecovery: recoveryState.health == .failed
        )
    }

    private func beginRecovery(at gapStart: Date, retryingFailedRecovery: Bool = false) {
        guard isRecording else { return }
        if retryingFailedRecovery {
            guard recoveryState.health == .failed else { return }
            recoveryState.retryRecovery()
        } else {
            guard recoveryState.health == .healthy else { return }
            recoveryState.captureLost(at: gapStart)
        }
        recoveryGapStartedAt = recoveryGapStartedAt ?? gapStart
        recoveryDeadline = Date().addingTimeInterval(3)
        recoveryGeneration &+= 1
        generationBits.store(UInt64(bitPattern: Int64(recoveryGeneration)), ordering: .releasing)
        let generation = recoveryGeneration
        emitHealthChange(generation: generation)
        acceptsTapWrites.store(false, ordering: .releasing)
        awaitingRecoveryBuffer.store(true, ordering: .releasing)
        tearDownEngine()
        scheduleRecoveryDeadline(generation: generation)

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.attachRecovery(generation: generation) else { return }
            self.scheduleRecoveryRetry(generation: generation)
        }
    }

    private func scheduleRecoveryRetry(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            guard let self,
                  self.isRecording,
                  self.recoveryGeneration == generation,
                  self.recoveryState.health == .reconnecting else { return }
            _ = self.attachRecovery(generation: generation)
        }
    }

    private func scheduleRecoveryDeadline(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(3)) { [weak self] in
            self?.failRecovery(generation: generation)
        }
    }

    private func failRecovery(generation: Int) {
        guard isRecording,
              recoveryGeneration == generation,
              recoveryState.health == .reconnecting else { return }
        recoveryState.recoveryTimedOut()
        emitHealthChange(generation: generation)
        awaitingRecoveryBuffer.store(false, ordering: .releasing)
        acceptsTapWrites.store(false, ordering: .releasing)
        tearDownEngine()
    }

    @discardableResult
    private func attachRecovery(generation: Int) -> Bool {
        guard isRecording,
              recoveryGeneration == generation,
              recoveryState.health == .reconnecting else { return false }
        engine = AVAudioEngine()
        do {
            let gap = DateInterval(start: recoveryGapStartedAt ?? Date(), end: Date())
            try attach(
                voiceProcessing: Config.micVoiceProcessing(),
                writingRecoverySilenceFor: gap
            )
            return true
        } catch {
            tearDownEngine()
            FileHandle.standardError.write(Data("mic route recovery attempt failed: \(error)\n".utf8))
            return false
        }
    }

    private func tearDownEngine() {
        acceptsTapWrites.store(false, ordering: .releasing)
        removeConfigurationObserver()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    private func recordFirstBufferIfNeeded(at bits: UInt64) {
        guard firstBufferAtBits.compareExchange(
            expected: 0,
            desired: bits,
            ordering: .acquiringAndReleasing
        ).exchanged else { return }
        let generation = generationBits.load(ordering: .acquiring)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isRecording,
                  self.generationBits.load(ordering: .acquiring) == generation,
                  self.firstBufferAt == nil else { return }
            self.firstBufferAt = Self.date(from: bits)
        }
    }

    private func recordRecoveryBufferIfNeeded(at bits: UInt64) {
        guard awaitingRecoveryBuffer.compareExchange(
            expected: true,
            desired: false,
            ordering: .acquiringAndReleasing
        ).exchanged else { return }
        let generation = generationBits.load(ordering: .acquiring)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isRecording,
                  self.generationBits.load(ordering: .acquiring) == generation,
                  self.recoveryState.health == .reconnecting else { return }
            guard let capturedAt = Self.date(from: bits) else { return }
            self.recoveryState.captureResumed(at: capturedAt)
            self.recoveryDeadline = nil
            self.recoveryGapStartedAt = nil
            self.emitHealthChange()
        }
    }

    private func emitHealthChange(generation: Int? = nil) {
        let callback = onHealthChange
        let health = recoveryState.health
        let expectedGeneration = generation ?? recoveryGeneration
        Task { @MainActor [weak self] in
            guard let self,
                  self.isRecording,
                  self.recoveryGeneration == expectedGeneration else { return }
            callback?(health)
        }
    }

    private static func currentDateBits() -> UInt64 {
        Date().timeIntervalSinceReferenceDate.bitPattern
    }

    static func captureIsStale(
        startedAt: Date,
        lastBufferAt: Date?,
        now: Date,
        timeout: TimeInterval
    ) -> Bool {
        now.timeIntervalSince(lastBufferAt ?? startedAt) >= timeout
    }

    static func inputRouteChanged(from active: InputDescription?, to current: InputDescription?) -> Bool {
        guard let active, let current else { return false }
        return active != current
    }

    private static func date(from bits: UInt64) -> Date? {
        guard bits != 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
    }

    private static func defaultInputDescription() -> InputDescription? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceAddress,
            0,
            nil,
            &deviceSize,
            &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }

        func stringProperty(_ selector: AudioObjectPropertySelector) -> String? {
            var value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
                return nil
            }
            return value?.takeUnretainedValue() as String?
        }

        guard let name = stringProperty(kAudioObjectPropertyName),
              let uid = stringProperty(kAudioDevicePropertyDeviceUID) else { return nil }
        var nominalSampleRate: Float64 = 0
        var sampleRateSize = UInt32(MemoryLayout<Float64>.size)
        var sampleRateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            deviceID,
            &sampleRateAddress,
            0,
            nil,
            &sampleRateSize,
            &nominalSampleRate
        ) == noErr else { return nil }

        var streamFormat = AudioStreamBasicDescription()
        var streamFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var streamFormatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            deviceID,
            &streamFormatAddress,
            0,
            nil,
            &streamFormatSize,
            &streamFormat
        ) == noErr else { return nil }
        return InputDescription(
            name: name,
            uid: uid,
            sampleRate: nominalSampleRate,
            channelCount: streamFormat.mChannelsPerFrame
        )
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
        tearDownEngine()
        let recreateFile = !hasCapturedUsefulAudio.load(ordering: .acquiring)
        if recreateFile {
            file = nil
            firstBufferAt = nil
            firstBufferAtBits.store(0, ordering: .releasing)
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
