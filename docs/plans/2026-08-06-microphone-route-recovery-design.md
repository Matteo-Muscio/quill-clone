# Microphone Route Recovery Design

## Problem

Quill records the microphone as `me` and system audio as `them`. It does not
identify voices with a diarization model; speaker labels come from the source
track.

In the affected AirPods meeting, `system.caf` recorded the full call while
`mic.caf` contained no audio packets. macOS logs show that Bluetooth changed
from A2DP playback to the HFP/SCO input route shortly after recording began.
The route changed channel count and sample rate, and `AVAudioEngine` stopped.
Quill continued to report that the session was recording because it monitored
session state rather than microphone-track health.

This matches Apple's documented `AVAudioEngineConfigurationChange` behaviour:
an input or output hardware format change stops and uninitializes the engine,
and the app must reestablish connections whose formats changed.

## Goals

- Recover microphone capture after a macOS audio-route or hardware-format
  change without interrupting system-audio recording.
- Make microphone failure immediately visible and actionable.
- Preserve transcript timing across a microphone interruption.
- Record enough route information to diagnose future failures.
- Keep the change local to the existing two-track recording architecture.

## Non-goals

- Voice identification or model-based speaker diarization.
- A microphone picker or a generalized device-management subsystem.
- Silently overriding the user's selected input with the built-in microphone.
- Replacing the current recording or transcription pipeline.

## Recording Behaviour

`MicRecorder` owns a small health state: `healthy`, `reconnecting`, or
`failed`.

It observes `AVAudioEngineConfigurationChange` for its active engine and also
uses a lightweight watchdog based on the time of the first and most recent
buffer. The watchdog covers cases where the engine stops without delivering a
useful notification or callback.

When capture becomes unhealthy:

1. Mark the microphone as reconnecting.
2. Tear down the stale tap and engine outside Apple's notification callback.
3. Read the current default input's native format.
4. Rebuild the engine, tap, and converter for that format.
5. Continue writing to the existing microphone file.

The microphone file keeps the processing format chosen at session start. A
new hardware format is converted into that stable format. When capture resumes,
Quill inserts silence equal to the interruption before writing new microphone
audio. This preserves the wall-clock relationship between `mic.caf` and
`system.caf`; simply appending recovered audio would shift all later `me`
segments earlier in the transcript.

If capture has not resumed after roughly three seconds, microphone health
becomes failed. System audio continues recording. A subsequent route change,
such as the user choosing another input in Sound Settings, starts another
bounded recovery attempt.

## User Interface

The menu-bar item has three relevant appearances:

- Idle: the existing Quill feather.
- Healthy recording or brief recovery: the native `stop.fill` symbol.
- Confirmed microphone failure: the native
  `exclamationmark.triangle.fill` symbol.

All menu-bar symbols remain AppKit template images. macOS therefore renders
them black in light appearance and white in dark appearance; Quill does not
apply a red warning colour.

The danger state changes the menu status to "Microphone unavailable - system
audio still recording", sends one macOS notification, and reveals an "Open
Sound Settings..." action. "Stop recording" remains available. If capture
recovers, the stop icon and normal recording status return automatically.

The short reconnecting period does not flash or replace the stop icon, avoiding
noise for route changes that recover normally.

## Components and Data Flow

- `MicRecorder` detects route changes and missing buffers, rebuilds capture,
  preserves the file timeline, and emits health changes.
- `RecordingSession` forwards microphone health and collects interruption
  metadata.
- `AppController` maps session health to menu-bar state and notifications.
- `MenuBarController` displays the native icon, warning text, and conditional
  Sound Settings action.

The state remains within these existing components. No standalone audio-route
manager is introduced.

## Metadata and Completed Recordings

`meta.json` records the initial microphone identity and format, interruption
intervals, and the final microphone status. If no microphone buffer was ever
captured, the session is explicitly marked partial rather than reported as a
fully successful two-track recording.

Transcription continues to skip an unreadable or empty microphone track, but
the user-facing recording result must retain the partial-recording warning.

## Validation

Automated validation covers:

- Health transitions from healthy to reconnecting, recovered, and failed.
- Gap calculation and preservation of microphone timeline alignment.
- Continued system recording when microphone recovery fails.
- Menu-bar state and the conditional Sound Settings action.
- Recovery from a failed state after another route change.
- Unchanged built-in microphone behaviour.

A real hardware test must reproduce the original conditions:

- AirPods used for input and output while macOS switches from A2DP to HFP.
- AirPods disconnected and reconnected during recording.
- `mic.caf` contains captured audio after recovery.
- `me` and `them` transcript segments remain aligned.
- The danger icon, notification, and recovery behaviour match the design.

The AirPods test is intentionally deferred until the user and AirPods are
physically available. Automated checks and non-AirPods validation can proceed
before then, but the fix is not hardware-verified until that test is complete.
