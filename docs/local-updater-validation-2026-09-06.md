# Local updater validation — 6 September 2026

The manual `quill update` command builds the latest main from the user-owned fork, validates it before asking the daemon to exit, and replaces the installed LaunchAgent executable with a retained rollback copy. `--check` leaves the daemon running. No scheduled checks or downloaded release binaries are involved.

## Verification

- Debug tests with coverage: 134 passed, zero failures.
- Release tests: 134 passed, zero failures.
- Release build and ad hoc signature verification passed.
- CLI help, run help, updater help, invalid timeout rejection, and live fork revision check passed.
- Doctor confirmed microphone access, recordings folder, and the installed v3 model. System audio permission remains unknowable until capture.
- An isolated running daemon ignored a request addressed to another PID and exited successfully on its own PID request. No recording artifacts were produced.
- Transaction tests cover failed builds and probes, busy and older daemons, loaded and unloaded agents, restart rollback, retained recovery copies, concurrent invocations, changed installation files, malformed process states, and a dirty cache whose manifest is absent.
- Handoff tests cover recording/model/unsaved metadata guards, duplicate requests, coordinator reservation, outstanding submissions, and disabled-transcription hooks.
- Independent code review identified malformed-PID and missing-manifest cache checks; both were corrected and included in the passing suite.

The FluidAudio dependency emits its existing unhandled `benchmark.md` warning. No GitHub Actions workflows are configured in this repository. No real microphone capture, system-audio capture, or model inference was run for this updater change.

## Local evidence

The ignored `.build/` directory contains `updater-debug-full.log`, `updater-release-full.log`, `updater-release-build.log`, and `updater-evidence/handoff-live.json`. These are local validation records, not remote CI results. The production updater writes its own build log and installation receipt under the user's Application Support directory.
