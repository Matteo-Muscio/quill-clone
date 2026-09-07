import Foundation

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

    /// Midpoint ownership prevents a word crossing a speaker boundary appearing twice.
    func text(for region: MeetingRegion) -> String {
        words.filter {
            let midpoint = $0.start + ($0.end - $0.start) / 2
            return midpoint >= region.start && midpoint < region.end
        }.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func speakerName(for region: MeetingRegion) -> String {
        if region.speakerIDs.isEmpty { return region.isUncertain ? "Uncertain" : "Other" }
        return region.speakerIDs.map { id in speakers.first { $0.id == id }?.name ?? "Unknown" }
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
        guard !trimmed.isEmpty, let index = speakers.firstIndex(where: { $0.id == id }) else { return false }
        speakers[index].name = trimmed
        updatedAt = Date()
        return true
    }

    /// Confirmed intervals have absolute priority, including Other and overlap labels.
    /// New analysis may only fill the unconfirmed complement of those intervals.
    mutating func applyAnalysis(regions proposals: [MeetingRegion], words newWords: [MeetingWord]? = nil) {
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
        updatedAt = Date()
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
              zip(orderedRegions, orderedRegions.dropFirst()).allSatisfy({ $0.end <= $1.start })
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
