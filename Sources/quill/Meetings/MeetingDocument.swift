import Foundation
import CryptoKit

struct MeetingSpeaker: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
}

struct MeetingWord: Codable, Sendable, Equatable {
    var start: Double
    var end: Double
    var text: String
}

/// These are annotations on the original audio, never isolated or movable audio clips.
struct MeetingRegion: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var start: Double
    var end: Double
    var speakerIDs: [String]
    var isConfirmed: Bool = false
    var isUncertain: Bool = false
}

struct MeetingAcousticEvidence: Codable, Sendable, Equatable {
    var start: Double
    var end: Double
    var sourceSpeakerID: String
    var embedding: [Float]
    var windowID: String? = nil
}

/// An editorial replacement anchored to audio time, independent of speaker labels.
/// The ASR words remain intact so the recognized text can always be inspected.
struct MeetingTextCorrection: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var start: Double
    var end: Double
    var text: String
}

enum MeetingNotesSection: String, Codable, Sendable, Equatable {
    case summary, keyTakeaway, actionItem
}

/// Exact excerpts from the exported transcript used for a generation.
struct MeetingNotesSource: Codable, Sendable, Equatable {
    var id: String
    var start: Double
    var text: String
}

struct MeetingNotesCitation: Codable, Sendable, Equatable {
    var section: MeetingNotesSection
    var index: Int
    var sourceIDs: [String]
}

struct MeetingNotesSourceGroup: Sendable, Equatable {
    var citation: MeetingNotesCitation
    var sources: [MeetingNotesSource]
}

struct MeetingNotes: Codable, Sendable, Equatable {
    var title: String
    var summary: String
    var keyTakeaways: [String]
    var actionItems: [String]
    var modelID: String
    var generatedAt: Date = Date()
    var sourceTranscriptHash: String? = nil
    var sources: [MeetingNotesSource]? = nil
    var citations: [MeetingNotesCitation]? = nil
}

struct MeetingTranscriptParagraph: Sendable, Equatable, Identifiable {
    var id: String
    var start: Double
    var end: Double
    var speakerIDs: [String]
    var text: String
}

struct MeetingDocument: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var title: String
    var audioFilename: String
    var duration: Double = 0
    var speakers: [MeetingSpeaker] = []
    var regions: [MeetingRegion] = []
    var words: [MeetingWord] = []
    var waveform: [Float] = []
    var acousticEvidence: [MeetingAcousticEvidence] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var provenance: String = "Imported recording"
    var textCorrections: [MeetingTextCorrection] = []
    var reviewedAt: Date? = nil
    var notes: MeetingNotes? = nil
    /// nil means automatic speaker discovery. Lane identities are independent.
    var participantCountHint: Int? = nil

    var hasTextCorrections: Bool { !textCorrections.isEmpty }
    var transcriptMarkdown: String { transcriptText }
    var transcriptFingerprint: String {
        SHA256.hash(data: Data(transcriptMarkdown.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var notesAreStale: Bool {
        guard let source = notes?.sourceTranscriptHash else { return false }
        return source != transcriptFingerprint
    }

    /// Source inspection is optional. Invalid or outdated references never seek
    /// to unrelated audio, and do not make an otherwise usable meeting unreadable.
    func noteSources(for citation: MeetingNotesCitation) -> [MeetingNotesSource] {
        resolvedNoteSources().groups.first { $0.citation == citation }?.sources ?? []
    }

    /// Resolve every citation against one freshness check; transcript hashing is
    /// deliberately outside the per-citation work and the playback render loop.
    func resolvedNoteSources() -> (areStale: Bool, groups: [MeetingNotesSourceGroup]) {
        let stale = notesAreStale
        guard let notes, !stale else { return (stale, []) }
        let groups = (notes.citations ?? []).compactMap { citation -> MeetingNotesSourceGroup? in
            let sources = noteSources(for: citation, notes: notes)
            return sources.isEmpty ? nil : .init(citation: citation, sources: sources)
        }
        return (false, groups)
    }

    private func noteSources(for citation: MeetingNotesCitation, notes: MeetingNotes) -> [MeetingNotesSource] {
        let itemExists: Bool
        switch citation.section {
        case .summary: itemExists = citation.index == 0 && !notes.summary.isEmpty
        case .keyTakeaway: itemExists = notes.keyTakeaways.indices.contains(citation.index)
        case .actionItem: itemExists = notes.actionItems.indices.contains(citation.index)
        }
        guard itemExists else { return [] }
        let sources = notes.sources ?? []
        let counts = sources.reduce(into: [String: Int]()) { $0[$1.id, default: 0] += 1 }
        var seen = Set<String>()
        return citation.sourceIDs.compactMap { id in
            guard seen.insert(id).inserted, counts[id] == 1,
                  let source = sources.first(where: { $0.id == id }),
                  source.start.isFinite, source.start >= 0, source.start < duration,
                  !source.text.isEmpty else { return nil }
            return source
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, audioFilename, duration, speakers, regions, words, waveform, acousticEvidence
        case createdAt, updatedAt, provenance, textCorrections, reviewedAt, notes, participantCountHint
    }

    /// Midpoint ownership prevents a word crossing a speaker boundary appearing twice.
    func text(for region: MeetingRegion) -> String {
        text(in: region, from: effectiveWords)
    }

    func originalText(for region: MeetingRegion) -> String {
        text(in: region, from: words)
    }

    var transcriptText: String {
        var lines = ["# \(title.replacingOccurrences(of: "\n", with: " "))", ""]
        for paragraph in transcriptParagraphs {
            let seconds = Int(paragraph.start)
            let stamp = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            lines.append("[\(stamp)] \(speakerName(for: paragraph.speakerIDs)): \(paragraph.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Reading/export shares paragraphs while the editing timeline retains every
    /// original diarization boundary, including segments with no recognized words.
    var transcriptParagraphs: [MeetingTranscriptParagraph] {
        let displayWords = effectiveWords
        var result: [MeetingTranscriptParagraph] = []
        for region in regions.sorted(by: { $0.start < $1.start }) {
            let content = text(in: region, from: displayWords)
            guard !content.isEmpty else { continue }
            if let previous = result.last, previous.speakerIDs == region.speakerIDs,
               region.start - previous.end <= 1.5, previous.text.count + content.count + 1 <= 600 {
                result[result.count - 1].text += " " + content
                result[result.count - 1].end = region.end
            } else {
                result.append(.init(id: region.id, start: region.start, end: region.end,
                                    speakerIDs: region.speakerIDs, text: content))
            }
        }
        return result
    }

    private var effectiveWords: [MeetingWord] {
        guard !textCorrections.isEmpty else { return words }
        let recognized = words.filter { word in
            let midpoint = word.start + (word.end - word.start) / 2
            return !textCorrections.contains { midpoint >= $0.start && midpoint < $0.end }
        }
        return (recognized + textCorrections.flatMap(correctionWords)).sorted { $0.start < $1.start }
    }

    private func text(in region: MeetingRegion, from words: [MeetingWord]) -> String {
        words.filter { owns($0, start: region.start, end: region.end) }.map(\.text)
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func owns(_ word: MeetingWord, start: Double, end: Double) -> Bool {
        let midpoint = word.start + (word.end - word.start) / 2
        return midpoint >= start && midpoint < end
    }

    /// Edited text has approximate timing within its selected interval, rather
    /// than fabricated word alignment. Midpoint ownership preserves it on splits.
    private func correctionWords(_ correction: MeetingTextCorrection) -> [MeetingWord] {
        let tokens = correction.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let step = (correction.end - correction.start) / Double(max(1, tokens.count))
        return tokens.enumerated().map { index, text in
            MeetingWord(start: correction.start + Double(index) * step,
                        end: correction.start + Double(index + 1) * step, text: text)
        }
    }

    @discardableResult
    mutating func replaceText(regionID: String, text: String) -> Bool {
        guard let region = regions.first(where: { $0.id == regionID }) else { return false }
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let current = self.text(for: region).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard normalized != current else { return false }
        var retained: [MeetingTextCorrection] = []
        for correction in textCorrections {
            guard correction.start < region.end && correction.end > region.start else {
                retained.append(correction)
                continue
            }
            let tokens = correctionWords(correction)
            if correction.start < region.start {
                let text = tokens.filter { owns($0, start: correction.start, end: region.start) }.map(\.text).joined(separator: " ")
                retained.append(.init(start: correction.start, end: region.start, text: text))
            }
            if correction.end > region.end {
                let text = tokens.filter { owns($0, start: region.end, end: correction.end) }.map(\.text).joined(separator: " ")
                retained.append(.init(start: region.end, end: correction.end, text: text))
            }
        }
        retained.append(.init(start: region.start, end: region.end, text: text))
        textCorrections = retained.sorted { $0.start < $1.start }
        reviewedAt = nil
        updatedAt = Date()
        return true
    }

    func speakerName(for region: MeetingRegion) -> String {
        speakerName(for: region.speakerIDs)
    }

    func speakerName(for speakerIDs: [String]) -> String {
        if speakerIDs.isEmpty { return "Unassigned" }
        return speakerIDs.map { id in speakers.first { $0.id == id }?.name ?? "Unknown" }
            .joined(separator: " + ")
    }

    @discardableResult
    mutating func assign(regionID: String, to speakerIDs: [String]) -> Bool {
        guard let index = regions.firstIndex(where: { $0.id == regionID }),
              speakerIDs.allSatisfy({ id in speakers.contains { $0.id == id } }) else { return false }
        regions[index].speakerIDs = Array(NSOrderedSet(array: speakerIDs)) as? [String] ?? speakerIDs
        regions[index].isConfirmed = true
        regions[index].isUncertain = false
        updatedAt = Date()
        return true
    }

    /// Returns the new right-hand region. Both halves remain at their original times.
    @discardableResult
    mutating func split(regionID: String, at time: Double) -> String? {
        guard time.isFinite, let index = regions.firstIndex(where: { $0.id == regionID }),
              time > regions[index].start, time < regions[index].end else { return nil }
        var right = regions[index]
        right.id = UUID().uuidString
        right.start = time
        right.isConfirmed = true
        right.isUncertain = false
        regions[index].end = time
        regions[index].isConfirmed = true
        regions[index].isUncertain = false
        regions.insert(right, at: index + 1)
        updatedAt = Date()
        return right.id
    }

    @discardableResult
    mutating func setBounds(regionID: String, start: Double, end: Double) -> Bool {
        guard start.isFinite, end.isFinite, duration.isFinite,
              let index = regions.firstIndex(where: { $0.id == regionID }) else { return false }
        let boundedStart = max(0, min(duration, start))
        let boundedEnd = max(0, min(duration, end))
        guard boundedStart < boundedEnd else { return false }
        let original = regions[index]
        // A boundary adjustment cannot move the whole annotation past its original
        // interval or consume a neighbour. Shared boundaries move both annotations.
        guard boundedStart < original.end, boundedEnd > original.start else { return false }
        let previous = regions.indices.filter { $0 != index && regions[$0].end <= original.start }
            .max { regions[$0].end < regions[$1].end }
        let next = regions.indices.filter { $0 != index && regions[$0].start >= original.end }
            .min { regions[$0].start < regions[$1].start }
        if let previous, boundedStart <= regions[previous].start { return false }
        if let next, boundedEnd >= regions[next].end { return false }
        if boundedStart != original.start {
            if let previous,
               regions[previous].end == original.start || regions[previous].end > boundedStart {
                regions[previous].end = boundedStart
                regions[previous].isConfirmed = true
                regions[previous].isUncertain = false
            } else if boundedStart > original.start {
                regions.append(.init(start: original.start, end: boundedStart, speakerIDs: [], isUncertain: true))
            }
        }
        if boundedEnd != original.end {
            if let next,
               regions[next].start == original.end || regions[next].start < boundedEnd {
                regions[next].start = boundedEnd
                regions[next].isConfirmed = true
                regions[next].isUncertain = false
            } else if boundedEnd < original.end {
                regions.append(.init(start: boundedEnd, end: original.end, speakerIDs: [], isUncertain: true))
            }
        }
        regions[index].start = boundedStart
        regions[index].end = boundedEnd
        regions[index].isConfirmed = true
        regions[index].isUncertain = false
        sortRegions()
        updatedAt = Date()
        return true
    }

    @discardableResult
    mutating func confirm(regionID: String) -> Bool {
        guard let index = regions.firstIndex(where: { $0.id == regionID }) else { return false }
        regions[index].isConfirmed = true
        regions[index].isUncertain = false
        updatedAt = Date()
        return true
    }

    @discardableResult
    mutating func setUncertain(regionID: String) -> Bool {
        guard let index = regions.firstIndex(where: { $0.id == regionID }) else { return false }
        regions[index].isConfirmed = false
        regions[index].isUncertain = true
        updatedAt = Date()
        return true
    }

    @discardableResult
    mutating func renameSpeaker(id: String, name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = speakers.firstIndex(where: { $0.id == id }),
              speakers[index].name != trimmed else { return false }
        speakers[index].name = trimmed
        updatedAt = Date()
        return true
    }

    /// Confirmed intervals have absolute priority, including Other and overlap labels.
    /// New analysis may only fill the unconfirmed complement of those intervals.
    @discardableResult
    mutating func applyAnalysis(regions proposals: [MeetingRegion], words newWords: [MeetingWord]? = nil) -> Bool {
        // Re-running recognition requires explicit removal of editorial overlays.
        // Refinement supplies no new words and can safely preserve them.
        guard newWords == nil || !hasTextCorrections else { return false }
        let confirmed = regions.filter(\.isConfirmed).sorted { $0.start < $1.start }
        var result = confirmed
        for proposal in proposals {
            guard proposal.start.isFinite, proposal.end.isFinite else { continue }
            var fragments: [(Double, Double)] = [(max(0, proposal.start), min(duration, proposal.end))]
            for fixed in confirmed {
                fragments = fragments.flatMap { start, end in
                    guard fixed.start < end && fixed.end > start else { return [(start, end)] }
                    var remainder: [(Double, Double)] = []
                    if start < fixed.start { remainder.append((start, fixed.start)) }
                    if end > fixed.end { remainder.append((fixed.end, end)) }
                    return remainder
                }
            }
            for (start, end) in fragments where start < end {
                var fragment = proposal
                fragment.id = UUID().uuidString
                fragment.start = start
                fragment.end = end
                fragment.isConfirmed = false
                result.append(fragment)
            }
        }
        regions = result
        if let newWords { words = newWords }
        sortRegions()
        reviewedAt = nil
        updatedAt = Date()
        return true
    }

    @discardableResult
    mutating func renameTitle(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != title else { return false }
        title = trimmed
        updatedAt = Date()
        return true
    }

    @discardableResult
    mutating func addSpeaker(name: String = "") -> String {
        var number = speakers.count + 1
        while speakers.contains(where: { $0.id == "speaker-\(number)" }) { number += 1 }
        let id = "speaker-\(number)"
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        speakers.append(.init(id: id, name: trimmed.isEmpty ? "Speaker \(number)" : trimmed))
        reviewedAt = nil
        updatedAt = Date()
        return id
    }

    @discardableResult
    mutating func removeSpeaker(_ id: String) -> Bool {
        guard !regions.contains(where: { $0.speakerIDs.contains(id) }), speakers.contains(where: { $0.id == id }) else { return false }
        speakers.removeAll { $0.id == id }
        reviewedAt = nil
        updatedAt = Date()
        return true
    }

    func validate() throws {
        guard Self.safeComponent(id), Self.safeComponent(audioFilename),
              audioFilename.hasPrefix("original."), duration.isFinite, duration >= 0, duration < Double(Int.max),
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingStoreError.invalidDocument("Invalid meeting identity, audio filename, or duration.")
        }
        let speakerIDs = Set(speakers.map(\.id))
        let orderedRegions = regions.sorted { $0.start < $1.start }
        let orderedCorrections = textCorrections.sorted { $0.start < $1.start }
        guard speakerIDs.count == speakers.count,
              speakers.allSatisfy({ !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(regions.map(\.id)).count == regions.count,
              regions.allSatisfy({ region in
                  !region.id.isEmpty && validInterval(region.start, region.end)
                      && Set(region.speakerIDs).count == region.speakerIDs.count
                      && region.speakerIDs.allSatisfy(speakerIDs.contains)
                      && !(region.isConfirmed && region.isUncertain)
              }), words.allSatisfy({ validInterval($0.start, $0.end, allowEmpty: true) }),
              waveform.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
              acousticEvidence.allSatisfy({ validInterval($0.start, $0.end) && $0.embedding.allSatisfy(\.isFinite) }),
              zip(orderedRegions, orderedRegions.dropFirst()).allSatisfy({ $0.end <= $1.start }),
              textCorrections.allSatisfy({ validInterval($0.start, $0.end) }),
              Set(textCorrections.map(\.id)).count == textCorrections.count,
              zip(orderedCorrections, orderedCorrections.dropFirst()).allSatisfy({ $0.end <= $1.start }),
              participantCountHint.map({ (1...12).contains($0) }) ?? true,
              reviewedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              notes.map({ $0.generatedAt.timeIntervalSince1970.isFinite }) ?? true
        else { throw MeetingStoreError.invalidDocument("Invalid speakers, annotation times, or audio evidence.") }
    }

    static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
            && !value.contains("\\") && !value.contains("\0")
    }

    private func validInterval(_ start: Double, _ end: Double, allowEmpty: Bool = false) -> Bool {
        start.isFinite && end.isFinite && start >= 0 && end <= duration
            && (allowEmpty ? start <= end : start < end)
    }

    private mutating func sortRegions() {
        regions.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    }
}

extension MeetingDocument {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        audioFilename = try values.decode(String.self, forKey: .audioFilename)
        duration = try values.decode(Double.self, forKey: .duration)
        speakers = try values.decode([MeetingSpeaker].self, forKey: .speakers)
        regions = try values.decode([MeetingRegion].self, forKey: .regions)
        words = try values.decode([MeetingWord].self, forKey: .words)
        waveform = try values.decode([Float].self, forKey: .waveform)
        acousticEvidence = try values.decode([MeetingAcousticEvidence].self, forKey: .acousticEvidence)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        provenance = try values.decode(String.self, forKey: .provenance)
        textCorrections = try values.decodeIfPresent([MeetingTextCorrection].self, forKey: .textCorrections) ?? []
        reviewedAt = try values.decodeIfPresent(Date.self, forKey: .reviewedAt)
        notes = try values.decodeIfPresent(MeetingNotes.self, forKey: .notes)
        participantCountHint = try values.decodeIfPresent(Int.self, forKey: .participantCountHint)
    }
}
