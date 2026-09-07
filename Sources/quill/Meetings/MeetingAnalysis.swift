import AVFoundation
import FluidAudio
import Foundation

struct MeetingAnalysisProgress: Sendable {
    var fraction: Double
    var message: String
}

struct MeetingAnalysisResult: Sendable {
    var words: [MeetingWord]
    var regions: [MeetingRegion]
    var acousticEvidence: [MeetingAcousticEvidence]
}

struct MeetingWaveform: Sendable {
    var duration: Double
    var peaks: [Float]
}

enum MeetingAnalysisError: Error, LocalizedError {
    case unreadableAudio
    case invalidParticipants
    case noReferenceExamples
    case noAcousticEvidence

    var errorDescription: String? {
        switch self {
        case .unreadableAudio: "This recording contains no readable audio."
        case .invalidParticipants: "Choose between 1 and 12 participants."
        case .noReferenceExamples:
            "Confirm clear, single-speaker sections for each active participant before refining (at least two). Longer sections provide better reference examples."
        case .noAcousticEvidence:
            "Analyze this recording first to prepare the speaker evidence needed for refinement."
        }
    }
}

/// Imported recordings are decoded and analyzed away from the main actor.
/// Audio stays on this Mac; only model artifacts may be downloaded.
actor MeetingAnalysis {
    static let shared = MeetingAnalysis()

    func waveform(audioURL: URL, maximumPeaks: Int = 2400) async throws -> MeetingWaveform {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)
        else { throw MeetingAnalysisError.unreadableAudio }
        let peakCount = min(max(1, maximumPeaks), 20_000, Int(file.length))
        var peaks = [Float](repeating: 0, count: peakCount)
        var offset: AVAudioFramePosition = 0
        while offset < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, file.length - offset)))
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for frame in 0..<Int(buffer.frameLength) {
                let bin = min(peakCount - 1, Int(Double(offset + Int64(frame)) / Double(file.length) * Double(peakCount)))
                var peak: Float = 0
                for channel in 0..<Int(format.channelCount) {
                    let sample = abs(channels[channel][frame])
                    if sample.isFinite { peak = max(peak, min(1, sample)) }
                }
                peaks[bin] = max(peaks[bin], peak)
            }
            offset += Int64(buffer.frameLength)
        }
        guard offset > 0 else { throw MeetingAnalysisError.unreadableAudio }
        return MeetingWaveform(duration: Double(file.length) / format.sampleRate, peaks: peaks)
    }

    func analyze(
        audioURL: URL,
        participantCount: Int,
        model: TranscriptionModel,
        progress: @escaping @Sendable (MeetingAnalysisProgress) -> Void = { _ in }
    ) async throws -> MeetingAnalysisResult {
        guard (1...12).contains(participantCount) else { throw MeetingAnalysisError.invalidParticipants }
        try Task.checkCancellation()
        let audioFile = try AVAudioFile(forReading: audioURL)
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { throw MeetingAnalysisError.unreadableAudio }
        progress(.init(fraction: 0.02, message: "Loading transcription model"))
        let engine = ParakeetEngine(model: model)
        let words: [MeetingWord]
        do {
            try await engine.prepare()
            try Task.checkCancellation()
            progress(.init(fraction: 0.08, message: "Transcribing on this Mac"))
            let rawWords = try await engine.transcribeWords(audioURL).map {
                MeetingWord(start: $0.startTime, end: $0.endTime, text: $0.word)
            }
            words = Self.normalizedWords(rawWords, duration: duration)
            await engine.release()
        } catch {
            await engine.release()
            throw error
        }
        try Task.checkCancellation()
        progress(.init(fraction: 0.45, message: "Preparing speaker models · first use may download models"))
        let models = try await ModelStore.shared.loadMeetingDiarizerModels()
        try Task.checkCancellation()
        // Participant count is a ceiling plus one background voice, not a
        // requirement that every audible voice belongs to a named participant.
        let config = Self.diarizerConfiguration(participantCount: participantCount)
        let diarizer = OfflineDiarizerManager(config: config)
        diarizer.initialize(models: models)
        progress(.init(fraction: 0.52, message: "Distinguishing speakers"))
        let (source, loadingSeconds) = try AudioSourceFactory().makeDiskBackedSource(
            from: audioURL, targetSampleRate: config.segmentation.sampleRate)
        defer { source.cleanup() }
        let cancellation = MeetingAudioCancellation()
        let cancellableSource = MeetingAudioCancellableSource(source: source, cancellation: cancellation)
        let result: DiarizationResult
        do {
            result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await diarizer.process(audioSource: cancellableSource, audioLoadingSeconds: loadingSeconds) { completed, total in
                    progress(.init(
                        fraction: 0.52 + 0.35 * min(1, Double(completed) / Double(max(1, total))),
                        message: "Distinguishing speakers · \(min(completed, total))/\(total) audio sections"
                    ))
                }
            } onCancel: {
                cancellation.cancel()
            }
        } catch OfflineDiarizationError.noSpeechDetected {
            try Task.checkCancellation()
            // Keep any words ASR recovered even when the speaker model cannot
            // establish a voice. The timeline explicitly leaves them uncertain.
            progress(.init(fraction: 1, message: "Ready to review · speakers could not be distinguished"))
            return MeetingAnalysisResult(words: words,
                regions: Self.alignedRegions(turns: [], words: words, mapping: [:]), acousticEvidence: [])
        }
        // In-flight Core ML predictions finish before cancellation can propagate.
        // A cancelled task never applies its result to the document.
        try Task.checkCancellation()
        progress(.init(fraction: 0.92, message: "Aligning the speaker timeline"))
        let turns = Self.normalizedTurns(result.segments.map {
            MeetingDiarizedTurn(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds),
                                speakerID: $0.speakerId, quality: Double($0.qualityScore))
        }, duration: duration)
        let mapping = Self.speakerMapping(turns: turns, participantCount: participantCount)
        let regions = Self.alignedRegions(turns: turns, words: words, mapping: mapping)
        // Chunk embeddings contain acoustics from a masked speaker slot rather
        // than the cluster centroid. Retain that finer evidence, clipped to the
        // actual speech turn so simultaneous slots are not accidentally pooled.
        let evidence = (result.chunkEmbeddings ?? []).flatMap { chunk in
            turns.compactMap { turn -> MeetingAcousticEvidence? in
                guard turn.speakerID == chunk.speakerId,
                      chunk.startTimeSeconds.isFinite, chunk.endTimeSeconds.isFinite,
                      chunk.embedding256.allSatisfy(\.isFinite) else { return nil }
                let start = max(turn.start, chunk.startTimeSeconds)
                let end = min(turn.end, chunk.endTimeSeconds)
                guard end - start >= 0.25, !chunk.embedding256.isEmpty else { return nil }
                return MeetingAcousticEvidence(start: start, end: end,
                    sourceSpeakerID: mapping[chunk.speakerId] ?? "", embedding: chunk.embedding256,
                    windowID: "\(chunk.chunkIndex)-\(chunk.speakerIndex)")
            }
        }
        try Task.checkCancellation()
        progress(.init(fraction: 1, message: "Ready to review"))
        return MeetingAnalysisResult(words: words, regions: regions, acousticEvidence: evidence)
    }

    func refine(document: MeetingDocument) async throws -> [MeetingRegion] {
        try Task.checkCancellation()
        return try MeetingRefinement.refine(document: document)
    }

    nonisolated static func diarizerConfiguration(participantCount: Int) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default.withSpeakers(min: 1, max: participantCount + 1)
        config.exposeChunkEmbeddings = true
        // The SDK's default trims away overlapping speakers and drops every
        // reconstructed turn shorter than a second. Meetings need interruptions
        // and short replies retained. Embedding extraction and post-filtering
        // share this setting in the pinned SDK; reference selection separately
        // requires at least 0.75 seconds plus whole-window confirmed coverage.
        config.exclusiveSegments = false
        config.minSegmentDuration = 0.3
        return config
    }

    nonisolated static func normalizedWords(_ words: [MeetingWord], duration: Double) -> [MeetingWord] {
        guard duration.isFinite, duration > 0 else { return [] }
        return words.compactMap { word in
            guard word.start.isFinite, word.end.isFinite, word.end > word.start else { return nil }
            let start = max(0, min(duration, word.start)), end = max(0, min(duration, word.end))
            guard end > start else { return nil }
            return MeetingWord(start: start, end: end, text: word.text)
        }.sorted { $0.start < $1.start }
    }

    nonisolated static func normalizedTurns(_ turns: [MeetingDiarizedTurn], duration: Double) -> [MeetingDiarizedTurn] {
        guard duration.isFinite, duration > 0 else { return [] }
        return turns.compactMap { turn in
            guard turn.start.isFinite, turn.end.isFinite, turn.end > turn.start else { return nil }
            let start = max(0, min(duration, turn.start)), end = max(0, min(duration, turn.end))
            guard end > start else { return nil }
            return MeetingDiarizedTurn(start: start, end: end, speakerID: turn.speakerID,
                quality: turn.quality.isFinite ? max(0, min(1, turn.quality)) : 0)
        }.sorted { $0.start < $1.start }
    }

    nonisolated static func speakerMapping(turns: [MeetingDiarizedTurn], participantCount: Int) -> [String: String] {
        let duration = Dictionary(grouping: turns, by: \.speakerID).mapValues {
            $0.reduce(0) { $0 + max(0, $1.end - $1.start) }
        }
        let primary = Set(duration.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(participantCount).map(\.key))
        var mapping: [String: String] = [:]
        for turn in turns.sorted(by: { $0.start < $1.start }) where primary.contains(turn.speakerID) {
            if mapping[turn.speakerID] == nil { mapping[turn.speakerID] = "speaker-\(mapping.count + 1)" }
        }
        return mapping
    }

    /// Divide at actual diarization boundaries, preserving simultaneous speech.
    /// ASR words falling outside detected turns remain visible as uncertain.
    nonisolated static func alignedRegions(
        turns: [MeetingDiarizedTurn], words: [MeetingWord], mapping: [String: String]
    ) -> [MeetingRegion] {
        let valid = turns.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        let validWords = words.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var boundaries = Set(valid.flatMap { [$0.start, $0.end] })
        for word in validWords {
            boundaries.insert(word.start)
            boundaries.insert(word.end)
        }
        let ordered = boundaries.sorted()
        guard ordered.count > 1 else { return [] }
        var regions: [MeetingRegion] = []
        var turnIndex = 0, wordIndex = 0
        var active: [MeetingDiarizedTurn] = []
        var activeWordEnds: [Double] = []
        for (start, end) in zip(ordered, ordered.dropFirst()) {
            let midpoint = (start + end) / 2
            while turnIndex < valid.count, valid[turnIndex].start <= midpoint {
                active.append(valid[turnIndex])
                turnIndex += 1
            }
            active.removeAll { $0.end <= midpoint }
            while wordIndex < validWords.count, validWords[wordIndex].start <= midpoint {
                activeWordEnds.append(validWords[wordIndex].end)
                wordIndex += 1
            }
            activeWordEnds.removeAll { $0 <= midpoint }
            let hasWord = !activeWordEnds.isEmpty
            guard !active.isEmpty || hasWord else { continue }
            let speakers = Array(Set(active.compactMap { mapping[$0.speakerID] })).sorted()
            let uncertain = active.isEmpty || active.contains { mapping[$0.speakerID] == nil || $0.quality < 0.5 }
                || speakers.count > 1
            if let previous = regions.last, previous.speakerIDs == speakers, previous.isUncertain == uncertain,
               abs(previous.end - start) < 0.0001 {
                regions[regions.count - 1].end = end
            } else {
                regions.append(MeetingRegion(start: start, end: end, speakerIDs: speakers, isUncertain: uncertain))
            }
        }
        return regions
    }
}

struct MeetingDiarizedTurn: Sendable {
    var start: Double
    var end: Double
    var speakerID: String
    var quality: Double
}
