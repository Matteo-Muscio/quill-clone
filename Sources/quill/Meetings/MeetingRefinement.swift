import Foundation

/// Session-only acoustic matching. This neither trains a model nor stores a
/// cross-meeting identity. Thresholds are deliberately conservative heuristics,
/// not calibrated probabilities. Weak matches flag the original attribution for
/// review; only a strong acoustic match moves a segment into a different lane.
enum MeetingRefinement {
    static func refine(document: MeetingDocument) throws -> [MeetingRegion] {
        guard !document.acousticEvidence.isEmpty else { throw MeetingAnalysisError.noAcousticEvidence }
        let prototypes = references(regions: document.regions, evidence: document.acousticEvidence)
        let activeSpeakers = Set(document.regions.flatMap(\.speakerIDs))
        guard prototypes.count >= 2, activeSpeakers.isSubset(of: Set(prototypes.keys)) else {
            throw MeetingAnalysisError.noReferenceExamples
        }
        return try document.regions.map { region in
            try Task.checkCancellation()
            guard !region.isConfirmed else { return region }
            // A single embedding cannot resolve simultaneous speakers. Preserve
            // that annotation rather than erase a known overlap.
            guard region.speakerIDs.count <= 1 else { return region }
            var refined = region
            let candidates = document.acousticEvidence.filter {
                overlap(region.start, region.end, $0.start, $0.end) >= min(0.25, (region.end - region.start) * 0.5)
            }
            let vector = average(candidates.map {
                ($0.embedding, overlap(region.start, region.end, $0.start, $0.end))
            })
            let ranked = prototypes.compactMap { speaker, reference -> (String, Double)? in
                guard let score = cosine(vector, reference) else { return nil }
                return (speaker, score)
            }.sorted { $0.1 > $1.1 }
            if ranked.count >= 2, ranked[0].1 >= 0.65, ranked[0].1 - ranked[1].1 >= 0.08 {
                refined.speakerIDs = [ranked[0].0]
                refined.isUncertain = false
            } else {
                // A failed comparison is not evidence that an existing draft
                // assignment is wrong. Keep its lane, mark it for review, and
                // leave originally unknown sections unknown.
                refined.isUncertain = true
            }
            return refined
        }
    }

    static func references(
        regions: [MeetingRegion], evidence: [MeetingAcousticEvidence]
    ) -> [String: [Float]] {
        let clean = regions.filter { $0.isConfirmed && $0.speakerIDs.count == 1 && $0.end - $0.start >= 0.75 }
        var examples: [String: [([Float], Double)]] = [:]
        let windows = Dictionary(grouping: evidence.enumerated(), by: {
            $0.element.windowID ?? "legacy-\($0.offset)"
        })
        for window in windows.values {
            let samples = window.map(\.element)
            let duration = samples.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
            guard duration >= 0.75, let vector = samples.first?.embedding else { continue }
            var coverage: [String: Double] = [:]
            var hasOverlap = false
            for sample in samples {
                if regions.contains(where: {
                    $0.speakerIDs.count > 1 && overlap($0.start, $0.end, sample.start, sample.end) > 0.05
                }) { hasOverlap = true }
                for region in clean {
                    let covered = overlap(region.start, region.end, sample.start, sample.end)
                    if covered > 0.05 { coverage[region.speakerIDs[0], default: 0] += covered }
                }
            }
            // All fragments share one model-window embedding. Requiring coverage
            // across that whole window's speech avoids accepting one tiny clipped
            // fragment as a clean reference for the entire acoustic vector.
            guard !hasOverlap, coverage.count == 1, let (speaker, covered) = coverage.first,
                  covered / duration >= 0.8 else { continue }
            examples[speaker, default: []].append((vector, covered))
        }
        return examples.compactMapValues {
            let reference = average($0)
            return reference.isEmpty ? nil : reference
        }
    }

    static func overlap(_ start: Double, _ end: Double, _ otherStart: Double, _ otherEnd: Double) -> Double {
        max(0, min(end, otherEnd) - max(start, otherStart))
    }

    static func average(_ samples: [([Float], Double)]) -> [Float] {
        guard let dimension = samples.first?.0.count, dimension > 0 else { return [] }
        var sum = [Double](repeating: 0, count: dimension)
        for (vector, weight) in samples where vector.count == dimension && weight.isFinite && weight > 0 {
            guard vector.allSatisfy(\.isFinite) else { continue }
            let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
            guard norm > 0 else { continue }
            for index in sum.indices { sum[index] += Double(vector[index]) / norm * weight }
        }
        let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
        guard norm > 0, norm.isFinite else { return [] }
        return sum.map { Float($0 / norm) }
    }

    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        guard !lhs.isEmpty, lhs.count == rhs.count,
              lhs.allSatisfy(\.isFinite), rhs.allSatisfy(\.isFinite) else { return nil }
        var product = 0.0, leftNorm = 0.0, rightNorm = 0.0
        for index in lhs.indices {
            let left = Double(lhs[index]), right = Double(rhs[index])
            product += left * right
            leftNorm += left * left
            rightNorm += right * right
        }
        guard leftNorm > 0, rightNorm > 0 else { return nil }
        return max(-1, min(1, product / sqrt(leftNorm * rightNorm)))
    }
}
