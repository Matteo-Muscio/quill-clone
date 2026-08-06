# Microphone Route Recovery Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Keep microphone capture alive across macOS audio-route changes, preserve the two-track timeline, and show an actionable native menu-bar warning when recovery fails.

**Architecture:** Keep recovery inside `MicRecorder`: observe the active engine's configuration changes, monitor buffer liveness, and rebuild the tap against the new native input format while retaining one stable output file format. Forward a small health state through `RecordingSession` and `AppController` to `MenuBarController`; system audio continues independently if the microphone remains unavailable.

**Tech Stack:** Swift 6, AVFoundation/AVAudioEngine, Core Audio, AppKit, Swift Package Manager, XCTest.

---

Use @test-driven-development for each behavioural task and
@verification-before-completion before reporting the implementation complete.
Do not add a device picker, diarization model, audio-route service, or automatic
fallback to a different microphone.

**Delegation:** Use one lower-cost implementation agent through
`multi_agent_v2` for Tasks 1-5 in sequence because they converge on
`MicRecorder` and its state flow. The orchestrator reviews the actual diff and
runs Task 6; parallel implementation would create avoidable conflicts.

### Task 1: Add the microphone recovery state and timeline model

**Files:**
- Modify: `Sources/quill/Audio/MicRecorder.swift:15-43`
- Create: `Tests/quillTests/MicRecoveryStateTests.swift`

**Step 1: Write the failing state tests**

Create `Tests/quillTests/MicRecoveryStateTests.swift` with fixed dates and
tests equivalent to:

```swift
import XCTest
@testable import quill

final class MicRecoveryStateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testLossRecoveryRecordsOneClosedInterruption() {
        var state = MicRecoveryState()
        state.captureLost(at: start)
        XCTAssertEqual(state.health, .reconnecting)

        state.captureResumed(at: start.addingTimeInterval(2.5))

        XCTAssertEqual(state.health, .healthy)
        XCTAssertEqual(state.interruptions, [
            .init(startedAt: start, endedAt: start.addingTimeInterval(2.5))
        ])
    }

    func testTimeoutKeepsInterruptionOpenAndMarksFailed() {
        var state = MicRecoveryState()
        state.captureLost(at: start)
        state.recoveryTimedOut()

        XCTAssertEqual(state.health, .failed)
        XCTAssertNil(state.interruptions.last?.endedAt)
    }

    func testRouteChangeRetriesWithoutOpeningASecondGap() {
        var state = MicRecoveryState()
        state.captureLost(at: start)
        state.recoveryTimedOut()
        state.retryRecovery()

        XCTAssertEqual(state.health, .reconnecting)
        XCTAssertEqual(state.interruptions.count, 1)
    }

    func testFinishClosesAnOpenInterruption() {
        var state = MicRecoveryState()
        state.captureLost(at: start)
        state.finish(at: start.addingTimeInterval(10))

        XCTAssertEqual(
            state.interruptions.last?.endedAt,
            start.addingTimeInterval(10)
        )
    }
}
```

**Step 2: Run the tests to verify they fail**

Run:

```bash
swift test --filter MicRecoveryStateTests
```

Expected: compilation fails because the recovery types do not exist.

**Step 3: Add the minimal internal model**

In `MicRecorder.swift`, add `MicCaptureHealth`, `MicInterruption`, and
`MicRecoveryState`. Keep them internal so the tests can import them with
`@testable` without creating a public API.

Required behaviour:

```swift
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

    mutating func recoveryTimedOut() { health = .failed }
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
```

Do not put AVAudioEngine logic into this value type.

**Step 4: Run the focused tests**

Run:

```bash
swift test --filter MicRecoveryStateTests
```

Expected: all four tests pass.

**Step 5: Commit**

```bash
git add Sources/quill/Audio/MicRecorder.swift Tests/quillTests/MicRecoveryStateTests.swift
git commit -m "test: define microphone recovery states"
```

### Task 2: Preserve one microphone file across format changes

**Files:**
- Modify: `Sources/quill/Audio/MicRecorder.swift:30-232`
- Modify: `Tests/quillTests/MicRecoveryStateTests.swift`

**Step 1: Write failing frame and gap tests**

Add tests for two internal static calculations:

```swift
func testConversionCapacityAccountsForUpsampling() {
    XCTAssertEqual(
        MicRecorder.convertedFrameCapacity(
            inputFrames: 4_096,
            inputRate: 24_000,
            outputRate: 48_000
        ),
        8_192
    )
}

func testSilenceFramesPreserveElapsedTime() {
    XCTAssertEqual(
        MicRecorder.silenceFrameCount(seconds: 2.5, sampleRate: 48_000),
        120_000
    )
}
```

**Step 2: Run the tests to verify they fail**

Run:

```bash
swift test --filter MicRecoveryStateTests
```

Expected: compilation fails because the helpers do not exist.

**Step 3: Separate file creation from engine attachment**

Refactor `start(writingTo:)` so it:

1. Creates a fresh engine and reads the initial input format.
2. Creates `mic.caf` once using the current mono sample rate.
3. Stores `file.processingFormat` as the session output format.
4. Attaches the tap and starts the engine.

Refactor `attach(voiceProcessing:)` into an engine-attachment method that uses
the already-open file. Recovery must never call `AVAudioFile(forWriting:)` on
the same URL because that truncates the captured track.

Use these capacity calculations, rounding up:

```swift
static func convertedFrameCapacity(
    inputFrames: AVAudioFrameCount,
    inputRate: Double,
    outputRate: Double
) -> AVAudioFrameCount {
    AVAudioFrameCount(ceil(Double(inputFrames) * outputRate / inputRate))
}

static func silenceFrameCount(
    seconds: TimeInterval,
    sampleRate: Double
) -> AVAudioFrameCount {
    AVAudioFrameCount(max(0, (seconds * sampleRate).rounded()))
}
```

Both voice-processing and raw taps must convert from their current tap format
to the stable file processing format. Allocate the destination buffer with
`convertedFrameCapacity`, not the input capacity, so AirPods' 24 kHz HFP input
can be written into a 48 kHz file.

**Step 4: Add bounded silence writing for a recovered gap**

Add a private method that writes zeroed `AVAudioPCMBuffer` chunks in the file's
processing format. Use chunks no larger than one second of frames. Invoke it
before accepting buffers from a successfully rebuilt engine, and advance a
`silenceWrittenThrough` date after each recovery attempt so repeated attempts
do not duplicate the same gap.

Do not synthesize silence during healthy recording. If recovery never succeeds,
there is no need to pad the unused tail of the microphone file.

**Step 5: Preserve the existing digital-silence fallback**

Keep the first-second voice-processing peak check. Its initial raw fallback may
recreate the file only when no useful microphone signal has ever been captured.
Once real audio exists, all later route recovery must preserve the file.

**Step 6: Run focused and full tests**

Run:

```bash
swift test --filter MicRecoveryStateTests
swift test
```

Expected: both commands pass.

**Step 7: Commit**

```bash
git add Sources/quill/Audio/MicRecorder.swift Tests/quillTests/MicRecoveryStateTests.swift
git commit -m "fix: preserve mic timeline across format changes"
```

### Task 3: Detect route loss and recover the microphone engine

**Files:**
- Modify: `Sources/quill/Audio/MicRecorder.swift`
- Modify: `Tests/quillTests/MicRecoveryStateTests.swift`

**Step 1: Add a failing recovery-policy test**

Add a test proving that the first loss opens one interruption, a timeout marks
failure, and a later retry plus resumed buffer closes that same interruption.
Use fixed dates and assert the complete final state.

Run:

```bash
swift test --filter MicRecoveryStateTests
```

Expected: the test fails until retry/resume integration is complete.

**Step 2: Add observable recorder health**

Give `MicRecorder` these read-only outputs and callback:

```swift
private(set) var recoveryState = MicRecoveryState()
private(set) var initialInput: InputDescription?
var onHealthChange: (@MainActor @Sendable (MicCaptureHealth) -> Void)?
```

`InputDescription` should contain only the default input device name, UID,
sample rate, and channel count. Query the macOS default input with Core Audio
when each engine is attached. Failure to read descriptive metadata must not
fail recording.

**Step 3: Observe the active engine configuration**

Register for `.AVAudioEngineConfigurationChange` with `object: engine` after
the engine is constructed. In the notification handler, dispatch recovery to
the main queue before stopping or replacing the engine. Apple warns that
deallocating the engine inside its internal notification callback can deadlock.

Remove the observer whenever the engine is replaced or recording stops.

Reference:
<https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/avaudioengineconfigurationchange>

**Step 4: Add one liveness watchdog**

Run one main-run-loop timer at one-second intervals while recording. It checks:

- No first buffer within two seconds of start.
- The engine is no longer running.
- No new callback for two seconds while the engine claims to be recording.

Protect timestamps shared with the tap callback using one small lock. Do not
hold that lock while starting, stopping, converting, or writing audio.

**Step 5: Implement bounded recovery**

On loss:

1. Record the gap from the last buffer time, or the recorder start time when no
   buffer arrived.
2. Emit `.reconnecting` once.
3. Remove the old observer, stop the engine, and remove its tap.
4. Rebuild from the current input format on the next main-run-loop turn.
5. Allow one additional attempt after 500 ms if attachment fails.
6. Require a real buffer within three seconds; otherwise emit `.failed`.

On the first recovered buffer, close the interruption and emit `.healthy`.
A configuration change received while failed calls `retryRecovery()` and starts
the same bounded sequence. Use a monotonically increasing recovery generation
to make stale delayed attempts no-ops.

**Step 6: Stop cleanly**

`stop()` must invalidate the watchdog, remove the configuration observer,
cancel stale recovery attempts through the generation, close any interruption,
then stop the engine and file. A delayed retry must never restart after stop.

**Step 7: Run validation**

Run:

```bash
swift test --filter MicRecoveryStateTests
swift test
swift build
```

Expected: tests and debug build pass.

**Step 8: Commit**

```bash
git add Sources/quill/Audio/MicRecorder.swift Tests/quillTests/MicRecoveryStateTests.swift
git commit -m "fix: recover mic after audio route changes"
```

### Task 4: Forward health and persist partial-recording metadata

**Files:**
- Modify: `Sources/quill/RecordingSession.swift`
- Create: `Tests/quillTests/RecordingSessionMetadataTests.swift`

**Step 1: Write failing metadata tests**

Extract the existing dictionary construction into an internal
`RecordingSession.makeMetadata(...)` function so it can be tested without
opening audio hardware. Add tests that verify:

- Healthy capture records `partial: false`.
- No microphone buffer records `partial: true` and final status `failed`.
- Initial device name, UID, sample rate, and channel count are serialized.
- Interruption dates are ISO-8601 strings.
- Existing `files` and `start_offset_ms` keys remain unchanged for the
  transcription coordinator.

Run:

```bash
swift test --filter RecordingSessionMetadataTests
```

Expected: compilation fails because `makeMetadata` and the microphone metadata
keys do not exist.

**Step 2: Forward microphone health**

Add to `RecordingSession`:

```swift
var onMicHealthChange: (@MainActor @Sendable (MicCaptureHealth) -> Void)? {
    didSet { mic.onHealthChange = onMicHealthChange }
}
```

If Swift actor checking rejects direct callback assignment, initialize the
session with the callback instead; do not add a delegate protocol.

**Step 3: Extend `meta.json` minimally**

Keep the existing top-level fields and add one `microphone` object:

```json
{
  "microphone": {
    "partial": true,
    "final_status": "failed",
    "initial_device": {
      "name": "AirPods",
      "uid": "...",
      "sample_rate": 48000,
      "channels": 1
    },
    "interruptions": [
      { "started": "...", "ended": "..." }
    ]
  }
}
```

Set `partial` when no mic buffer was captured or the final health is failed.
Do not change `SessionMeta.read`; it should continue reading the `files` and
offset fields and ignoring the additive metadata.

**Step 4: Run tests**

Run:

```bash
swift test --filter RecordingSessionMetadataTests
swift test
```

Expected: all tests pass.

**Step 5: Commit**

```bash
git add Sources/quill/RecordingSession.swift Tests/quillTests/RecordingSessionMetadataTests.swift
git commit -m "feat: record microphone capture health"
```

### Task 5: Add the native danger state and Sound Settings action

**Files:**
- Modify: `Sources/quill/UI/MenuBarController.swift`
- Modify: `Sources/quill/Quill.swift`
- Modify: `Tests/quillTests/AppControllerStateTests.swift`

**Step 1: Write failing presentation-state tests**

Extend `AppBusyState` with microphone health and a computed menu-bar recording
state. Add tests equivalent to:

```swift
func testMicFailureUsesDangerStateWithoutEndingRecording() {
    var state = AppBusyState()
    state.isRecording = true
    state.micHealth = .failed

    XCTAssertTrue(state.isRecording)
    XCTAssertEqual(state.recordingIndicator, .microphoneFailed)
}

func testRecoveredMicRestoresRecordingState() {
    var state = AppBusyState()
    state.isRecording = true
    state.micHealth = .failed
    state.micHealth = .healthy

    XCTAssertEqual(state.recordingIndicator, .recording)
}
```

Run:

```bash
swift test --filter AppControllerStateTests
```

Expected: compilation fails because the new state does not exist.

**Step 2: Replace the boolean menu presentation with a small enum**

Add an internal `RecordingIndicator` enum with `idle`, `recording`, and
`microphoneFailed`. Keep `.reconnecting` visually mapped to `.recording`.
Change `MenuBarController.update` to accept the enum and elapsed time.

For `.microphoneFailed`:

- Use `NSImage(systemSymbolName: "exclamationmark.triangle.fill", ...)`.
- Set `isTemplate = true`; do not apply a colour.
- Set the state label to
  `Microphone unavailable - system audio still recording`.
- Set the accessibility value to the same meaning.
- Keep the toggle title as `Stop recording`.

The one-second ticker must retain the danger state instead of overwriting it
with the normal stop icon.

**Step 3: Add the conditional action**

Create an `NSMenuItem` titled `Open Sound Settings...`, hidden except in the
failed state. Add an `onOpenSoundSettings` closure and open this macOS 15 URL
from `AppController`:

```swift
URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")
```

Use `NSWorkspace.shared.open`. If URL construction or opening fails, keep the
recording running and log the failure.

**Step 4: Wire health into the active session**

When creating `RecordingSession`, install its health callback. On the main
actor:

- Update `busyState.micHealth`.
- Refresh the menu-bar presentation.
- Send one notification on the transition to failed:
  title `quill - microphone unavailable`, body
  `System audio is still recording. Choose a microphone in Sound Settings.`
- Do not notify for reconnecting or repeat the failure notification each tick.
- Restore the stop icon automatically when health returns to healthy.

Reset mic health to healthy when a session ends or a new one starts.

**Step 5: Run tests and build**

Run:

```bash
swift test --filter AppControllerStateTests
swift test
swift build
```

Expected: tests and debug build pass.

**Step 6: Commit**

```bash
git add Sources/quill/UI/MenuBarController.swift Sources/quill/Quill.swift Tests/quillTests/AppControllerStateTests.swift
git commit -m "feat: warn when microphone capture fails"
```

### Task 6: Validate the integrated recording path

**Files:**
- Modify only if a validation failure requires a scoped correction.

**Step 1: Run repository validation**

Run:

```bash
swift test
swift build -c release
git diff --check
```

Expected: all tests pass, release build succeeds, and `git diff --check`
produces no output.

**Step 2: Perform a built-in microphone smoke test**

Launch the built executable, make a short recording using the MacBook's
built-in microphone, and verify:

- The menu-bar icon is the template stop square during healthy recording.
- `mic.caf` and `system.caf` contain readable audio.
- `meta.json` reports `partial: false` and the built-in input identity.
- Stopping still queues transcription normally.

Do not perform broad UI changes if the menu layout already communicates these
states clearly.

**Step 3: Exercise the failure UI without AirPods**

Use a controlled input-device removal or a debug-only test hook that is not
committed. Verify that microphone failure leaves system capture running, shows
the monochrome warning triangle, reveals `Open Sound Settings...`, sends only
one notification, and returns to the stop square after recovery.

**Step 4: Defer and record the AirPods acceptance test**

The user currently has the AirPods and is away from the MacBook. Do not claim
Bluetooth hardware verification. When both are available, test:

1. AirPods as both input and output during the A2DP-to-HFP transition.
2. AirPods disconnect and reconnect during a recording.
3. Recovered `mic.caf` audio and aligned `me`/`them` transcript timestamps.
4. Danger icon, notification, Sound Settings action, and recovery state.

**Step 5: Commit any scoped validation correction**

Only when Step 2 or 3 required a code correction:

```bash
git add <exact corrected files>
git commit -m "fix: correct microphone recovery integration"
```

Otherwise leave the implementation commits unchanged and report the deferred
AirPods test as the only material unverified risk.
