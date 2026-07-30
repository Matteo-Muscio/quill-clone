# Transcription Model Settings

## Scope

Add native model management to Quill without expanding it beyond a focused
macOS meeting recorder. This release includes:

- A SwiftUI Settings window hosted by the existing AppKit menu-bar app.
- Parakeet TDT v3 as the recommended multilingual default.
- Parakeet TDT v2 as the English-focused alternative.
- Explicit model download, activation, and cancellation.
- Pending-session recovery when no transcription model is installed.
- A recording-state menu-bar icon that changes from the feather to a stop
  square.

Live transcription and its floating side panel are a separate experiment and
are not part of this release.

## Approach

Keep Quill's `NSStatusItem` shell and open one reusable SwiftUI-backed Settings
window from a new **Settings…** menu item. SwiftUI provides concise reactive UI
for download progress and model state without adding a dependency. The
implementation should borrow FluidVoice's interaction principles without
copying its broader provider and settings architecture.

The Settings window contains one **Transcription Model** section with two model
cards:

### Parakeet TDT v3

- Recommended default.
- Best for Italian and multilingual meetings.
- Supports 25 European languages with automatic language detection.
- Runs locally through FluidAudio and Core ML.

### Parakeet TDT v2

- Best for English-only meetings.
- Retained as the English-focused, higher-recall option.
- Runs locally through FluidAudio and Core ML.

Each card shows the model name, provider, recommendation, language summary,
approximate download size, local-only privacy status, and model state. The
primary action changes between **Download & Use**, progress and cancellation,
**Use Model**, **Active**, and **Retry**. Model deletion is deferred because
FluidAudio's default cache may be shared with other applications.

## Native macOS appearance

The UI uses native SwiftUI controls, semantic colors, system typography, system
materials, and SF Symbols. It must follow Light, Dark, and Auto appearance,
Clear and Tinted Liquid Glass, accent color, Reduce Transparency, Increase
Contrast, and text-size preferences.

The recording-state icon uses the template SF Symbol `stop.fill`. macOS chooses
the correct white or black rendering for the current menu-bar appearance. No
hard-coded red, white, or black tint is used. The idle state retains the
template feather. Availability fallbacks preserve macOS 15 support when newer
appearance APIs require macOS 26.

All icon-only state and action controls include accessibility labels and help
text.

## Model catalog and persistence

A small `TranscriptionModel` catalog owns stable identifiers and display
metadata for v2 and v3. A main-actor model manager publishes these states:

- Not installed
- Downloading with percentage
- Installed
- Active
- Failed

The active model is stored as `transcription.model` in
`~/.config/quill/config.json`. Configuration writes preserve all unknown keys
and existing settings and replace the file atomically. An existing
configuration containing only `"engine": "parakeet"` resolves to v3 without
rewriting the file until the user explicitly changes a setting.

FluidAudio remains the only inference dependency. The transcription engine
accepts the selected model version instead of hard-coding v2, and transcript
provenance continues to record the concrete model identifier.

One serialized model-store boundary owns all FluidAudio cache access. Explicit
download and verification runs online through this boundary, while
transcription loads run with FluidAudio's global offline mode enabled. The
boundary prevents these operations from overlapping and guarantees that
transcription cannot recover a damaged cache by downloading implicitly.

## Download and activation

Model downloads are always explicit. Quill does not begin a roughly 600 MB
download merely because a meeting ended.

**Download & Use** performs these steps:

1. Download through FluidAudio with determinate progress.
2. Load the downloaded model once to verify it.
3. Persist the new active selection atomically.
4. Publish the installed and active state.
5. Release model weights until transcription needs them.
6. Resume pending sessions.

A cancelled or failed operation leaves the previous active model unchanged.
Download and activation are disabled while Quill is recording or transcribing.
Starting a recording is disabled while download or verification is active, so
Core ML verification and activation cannot complete during capture. Disabled
controls explain the reason through help text.

FluidAudio reports download and model-loading phases separately, so the UI
shows determinate transfer progress followed by an indeterminate
**Verifying…** phase. Completion is shown only after verification and
configuration persistence succeed.

## Pending transcription

When the transcription queue finds no installed active model, it enters a
`waitingForModel` state. It does not download a model, mark the session failed,
or write an empty transcript. The finished session remains recoverable through
its existing `meta.json`.

Quill shows the waiting state in the menu and Settings window and sends a
notification directing the user to install a model. After a model is installed
and activated, the coordinator rescans the recordings root and resumes pending
sessions automatically.

The coordinator checks model availability before removing a session from its
in-memory queue. If the model is absent, it retains the complete queue, clears
its draining flag, and publishes one waiting transition. Activation restarts
the retained queue without adding duplicates.

## Error handling

- Download and verification failures appear inline on the affected model with
  a retry action.
- Cancellation returns the model to its prior installed or unavailable state.
- Configuration write failure prevents activation and preserves the previous
  selection.
- Missing configuration may be created, but malformed JSON or invalid root and
  transcription values are never overwritten.
- Recording output remains untouched by model-management failures.

## Validation

Automated tests cover:

- Model catalog identifiers and user-facing metadata.
- Default v3 resolution and existing-configuration migration.
- Atomic configuration updates that preserve unknown keys.
- Download, cancellation, failure, installation, and activation transitions.
- Action locking during recording and transcription.
- Pending-session behavior and automatic resumption after activation.
- Correct transcript provenance for v2 and v3.

Manual verification covers:

- Release build and the focused test suite.
- `quill doctor` for both selected models.
- Download, cancellation, retry, activation, and switching.
- A short English transcription with v2 and an Italian transcription with v3.
- Pending-session resumption after installing the first model.
- Settings in Light, Dark, Auto, Clear, Tinted, and Reduce Transparency modes.
- Feather-to-stop-square state changes during a recording.
- LaunchAgent installation and relaunch behavior.

## Rollback

The current installed baseline remains unchanged until this branch passes
validation. Rollback consists of reinstalling the baseline release binary and
removing `transcription.model` from the config; existing recordings and
transcripts remain compatible.
