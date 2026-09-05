# Quill improvement review — September 5, 2026

Base: `9edd90f` on `main`. Scope: this fork's native macOS recorder, local transcription, settings, diagnostics, and existing tests. No dependency upgrades or changes to installed recordings/configuration.

## Ranked opportunities

Ranking balances user impact, implementation risk, and fit with Quill's minimal, local, two-track recording workflow. Risk refers to implementation and regression risk, not the severity of the existing problem. The first five were selected for implementation.

| Rank | Improvement | User impact | Risk | Product fit | Inspection evidence and decision |
| --- | --- | --- | --- | --- | --- |
| 1 | Report failed/missing transcription tracks accurately | High | Low | Core | The coordinator skipped failed tracks and still wrote a successful transcript, even when every track failed. Implemented. |
| 2 | Make recording metadata saves atomic, visible, and retryable | High | Medium | Core | `RecordingSession.stop()` discarded serialization/write errors, and the app dropped the session and queued transcription anyway. Implemented. |
| 3 | Warn about microphone gaps even after recovery | High | Low | Core | Metadata used final microphone health to determine completeness, ignoring recorded interruptions after recovery. Implemented. |
| 4 | Recover incomplete transcript exports | High | Low | Core | JSON was written before Markdown, while restart recovery treated JSON presence as completion. Implemented. |
| 5 | Retry pending transcriptions from the menu | Medium | Low | Core | Recovery required relaunch or model activation; direct enqueue also lacked duplicate checks. Implemented. |
| 6 | Recover sessions interrupted by a process crash | Very high | High | Core | Metadata is created only on clean stop, so surviving CAF tracks alone do not enter the resume queue. Deferred: requires durable recording-state checkpoints and safe reconstruction of timing/partial metadata. |
| 7 | Detect and surface system-audio capture failures | High | High | Core | System-track write errors only reach stderr; microphone capture has a health/recovery mechanism. Deferred: requires careful callback synchronization and real device testing. |
| 8 | Finalize recordings on SIGTERM | High | Medium | Core | The daemon handles SIGINT, but not SIGTERM from service management. Deferred: shutdown, ongoing writes, and failed-save handling need dedicated lifecycle tests. |
| 9 | Warn before and during low-disk-space recording | Medium | Medium | Strong | Startup checks folder writability but not available capacity; recording can continue into disk exhaustion. Deferred: needs a meaningful threshold and runtime storage-failure behavior. |
| 10 | Choose the recordings folder in Settings | Medium | Low | Good | Changing the destination currently requires config editing or `--out`. Deferred: adds a new settings concern and decisions about queued/active sessions. |

## Implemented behavior and evidence

### 1. Accurate transcription outcomes

Successfully decoded tracks are retained. Missing or failed declared tracks mark JSON as partial, name the failed files in a warning, and surface incomplete audio in Markdown and the completion notification. If no track succeeds, the job fails and remains pending. Successfully processing silence is still a valid empty transcript.

Regression tests in `TranscriptionCoordinatorTests` cover one failed track, one missing track, all tracks failing, all tracks missing, unsupported track declarations, valid silent audio results, and a subsequent successful retry.

### 2. Retryable recording saves

Stopping capture freezes the end time and metadata. Metadata uses an atomic write and errors reach the controller. A failed save retains the stopped session, displays a failure and **Retry saving recording**, prevents another recording, and refuses an ordinary quit until the metadata can be saved. A successful retry queues transcription normally. Existing audio bytes are preserved.

`testFailedMetadataSaveCanBeRetriedWithoutChangingEndTimeOrAudio` forces repeated filesystem failures, restores the destination, and verifies stable metadata/end time and unchanged audio. State tests cover the recording/transcription handoff and preservation of an earlier active job; native AppKit menu tests exercise the retry selector and recording availability.

This retry state is held in memory. It does not implement recovery after force-quit, power loss, or a process crash; see opportunity 6.

### 3. Microphone interruption warnings

Any recorded interruption makes the recording partial, even when the microphone is healthy again at stop. Final device health remains accurate and separate. Pending historical sessions with interruption records are also recognized, without rewriting their metadata.

`testInterruptionMetadataUsesISO8601Dates` verifies a recovered two-second gap is partial with healthy final status and preserved timestamps. `testLegacyRecoveredMicrophoneInterruptionStillWarns` checks the older metadata form through to JSON and the user notification.

### 4. Reliable readable and canonical exports

Markdown is written atomically before the canonical JSON completion marker. A failed export remains retryable. A valid legacy JSON transcript with missing Markdown is rendered again without loading a model or running inference; malformed JSON is retried. Valid completed JSON is preserved byte-for-byte.

Tests force Markdown and JSON write failures, retry after restoring the destination, repair legacy exports with no installed model, surface repair errors, and verify malformed canonical files are retryable. Mixed successful/failed work must preserve a failure status without unlocking controls during active inference.

### 5. Menu retry and queue safety

**Retry pending transcriptions** rescans the recordings root. It is unavailable during model preparation, active transcription, an unsaved recording, or disabled transcription. Queue checks reject duplicate queued, active, and completed sessions, including repeated scans and rapid enqueue requests. This action retries pending failures; it does not retranscribe already completed partial results.

Native AppKit tests dispatch the menu action and verify availability. Coordinator tests gate in-flight work, enqueue/rescan repeatedly, and verify one inference call and unchanged completed JSON. Existing activation, model-waiting, and enqueue-during-release tests remain part of the complete suite.

## Validation

Baseline: **72 tests passed** on Apple Swift 6.3.3, using `--scratch-path .build/validation`. The pre-existing `.build` cache referred to the repository's former path; a fresh scratch build avoids modifying the old cache.

Final integrated validation:

| Check | Result | Local evidence under `.build/validation/evidence/` |
| --- | --- | --- |
| `swift test --scratch-path .build/validation --enable-code-coverage` | 93 tests passed, 0 failures | `debug-tests.log` |
| `swift test --scratch-path .build/validation -c release` | 93 tests passed, 0 failures | `release-tests.log` |
| `swift build --scratch-path .build/validation -c release` | Passed | `release-build.log` |
| Release `quill --help`, `quill run --help`, `quill doctor` | All exited 0 | `cli-checks.log` |
| Isolated release startup with synthetic legacy transcript | Restored missing Markdown, original canonical SHA-256 unchanged | `release-recovery-check.log` |
| `git diff --check` | Passed | Final working-tree check |

The suite grew from 72 to 93 tests: 14 new coordinator regressions and 7 new recording-save, state, and native-menu tests. The existing recovered-interruption metadata test was strengthened as well.

Coverage for the recording metadata file is 88.79% of lines, the coordinator 93.20%, and the native menu 87.30%. The app lifecycle/controller remains lightly covered by unit tests (7.56%); the isolated release launch verifies startup/repair but does not exercise real capture. These are file-level figures, not a claim of repository-wide 80% coverage.

`doctor` confirmed microphone permission, writable recordings destination, and an installed Parakeet v3 model. Its system-audio permission warning is expected: that permission cannot be queried without starting capture. Builds also retain FluidAudio's existing unhandled `benchmark.md` resource warning; no dependency files were changed.

The desktop automation tool could not select Quill's standalone executable, so native menu selector/availability evidence comes from AppKit tests, not a desktop click. Real microphone capture, system-audio capture, hardware route changes, disk exhaustion during capture, and real model inference were not exercised. Tests use synthetic fixtures and fake engines; no models were downloaded and no paid calls were made.

The isolated release process was closed with SIGINT (exit 0). The existing installed Quill process was left running. No installation or LaunchAgent change was performed.

Delivery branch: `codex/recording-transcription-reliability` in `Matteo-Muscio/quill-clone`. The branch starts from `9edd90f` and retains all 17 fork commits above upstream, including the August 6 AirPods/audio-route recovery, format conversion, microphone timeline, recovery timeout, and early-audio fixes. `MicRecorder.swift` and its existing recovery tests are unchanged by this update. Hardware AirPods behavior was not retested during this work.
