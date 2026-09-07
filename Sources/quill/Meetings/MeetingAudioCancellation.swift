import FluidAudio
import Foundation

/// FluidAudio starts detached inference tasks, so parent Task cancellation alone
/// does not reach their audio reads. This flag bridges cancellation at each
/// bounded sample request without interrupting an in-flight Core ML prediction.
final class MeetingAudioCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock { cancelled = true }
    }

    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

struct MeetingAudioCancellableSource: AudioSampleSource {
    let source: any AudioSampleSource
    let cancellation: MeetingAudioCancellation

    var sampleCount: Int { source.sampleCount }

    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        try cancellation.check()
        try source.copySamples(into: destination, offset: offset, count: count)
    }
}
