# quill

A minimal, fully local macOS meeting recorder + transcriber. One menu-bar
click records your mic and all system audio as two separate tracks; when you
stop, quill transcribes both on-device and writes a speaker-tagged transcript.
Nothing ever leaves the machine.

Named for the feather. Sibling of [parrot](https://github.com/digimata/parrot), same skeleton: single
Swift binary, menu-bar tray, no app bundle.

## Install

```sh
cd quill
swift build -c release
sudo cp .build/release/quill /usr/local/bin/quill
quill install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

Source builds and updates also require Git and the Swift toolchain from
Xcode or its Command Line Tools.

## Update this fork

```sh
quill update --check          # inspect main without building or restarting
quill update                 # build, test, and install the latest main
quill update --wait 60        # allow up to 60 seconds for the app to become idle
```

This manual updater uses `Matteo-Muscio/quill-clone` only. It builds in a
separate cache, runs debug and release tests, checks the executable signature
and CLI, then asks Quill to exit when idle. Recording, transcription, model
preparation, and unsaved recording metadata block the handoff. The default
idle timeout is five minutes; a timeout leaves the running app untouched.
`--wait 0` installs only if the daemon is already stopped.

The existing LaunchAgent must point to a user-owned, writable `quill` binary.
The updater never uses sudo; a root-owned installation made with the commands
above needs a one-time migration to a user-owned location before using it.
For an existing user-local installation, invoke its full path if it is not on
your PATH, for example `"$HOME/Library/Application Support/quill/bin/quill" update`.
For the first update from a version without this
handoff, finish active work and quit Quill from its menu before updating.
Later updates handle that step automatically. A failed restart attempts to
restore the previous executable; if safe rollback cannot finish, the command
reports the retained backup and recovery error.

Source, build output, `update.log`, and the installed revision receipt live in
`~/Library/Application Support/quill/updates/`. Each attempted installation
retains a backup under `updates/backups/`, including the previous binary and
LaunchAgent plist. The updater preserves settings and the existing plist and
does not modify your development checkout. It makes no scheduled checks and
needs no paid signing service. `--check` reports “up to date” only when both
the recorded main revision and the installed binary hash match.

## How to use

1. **Run it** (`quill` in a terminal, or the LaunchAgent).
2. **Open Settings… → Transcription**, choose a model, then click
   **Download & Use**. Parakeet v3 is the recommended default for Italian and
   multilingual meetings; v2 is the English-focused alternative.
3. **Click the feather in the menu bar → Start recording.** First use prompts
   for microphone and System Audio Recording permissions. While recording, the
   feather becomes a template stop-square with a running elapsed counter,
   following the current macOS menu-bar appearance.
4. **Click → Stop recording** when the meeting ends. If the selected model is
   installed, transcription starts automatically and a notification fires when
   the transcript is ready. Otherwise, the session remains pending until a
   model is downloaded and activated.

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `transcribe.log` | transcription progress/errors for this session |

Two tracks on purpose: speech models do better on clean single-source audio,
and mic-vs-system is free two-party diarization — `me` vs `them` with no
speaker-identification model. CAF on purpose: unlike m4a, it needs no
finalization pass — if the process dies mid-meeting, everything already
written is still readable.

If Quill cannot save a stopped recording's metadata, the menu shows
**Retry saving recording**. Check available disk space and access to the
recordings folder, then retry. Capture has stopped; Quill keeps the original
end time and metadata in memory and prevents another recording or an ordinary
quit until saving succeeds. Force-quitting before retrying loses that in-memory
metadata, although any audio already written remains on disk.

Microphone interruptions mark the transcript as partial even if the microphone
reconnects before the recording ends. Check the warning before relying on the
transcript as a complete record of the meeting.

## Transcription

Built in, on-device, automatic. The recommended default is **Parakeet TDT 0.6B
v3**, which supports Italian and multilingual meetings with automatic language
detection. **Parakeet TDT 0.6B v2** remains available as the English-focused
alternative. Both run through
[FluidAudio](https://github.com/FluidInference/FluidAudio)'s Core ML port —
roughly 20 seconds per hour of audio on Apple Silicon.

Transcription models are about 600 MB and are never downloaded implicitly. Open
**Settings… → Transcription**, choose a model, and click **Download & Use**;
`quill doctor` reports whether the selected model is already cached.

Each track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. Jobs run in a serial queue — you can
start a new recording while the last one transcribes. Unfinished jobs resume
on next launch, and sessions waiting for a model resume automatically after one
is downloaded and activated (the filesystem is the queue: a session with
`meta.json` but no `transcript.json` is pending). Failures append to the
session's `transcribe.log` and never block later jobs.

Use **Retry pending transcriptions** in the menu after resolving a failure;
restarting Quill is not required. Repeated retries do not duplicate queued or
active jobs, and completed transcripts are preserved. The action is unavailable
while a model is being prepared, transcription is running, a recording still
needs saving, or transcription is disabled.

If one audio track cannot be transcribed, Quill saves the other track's speech
and warns that the transcript is incomplete. If every track fails, it reports a
failure and leaves the session pending for retry. A successfully processed track
with no speech may legitimately produce an empty transcript. Retry applies to
pending jobs, not completed partial transcripts.

Quill also restores a missing `transcript.md` from a valid `transcript.json`
when scanning pending work, without loading a model or repeating transcription.

## Imported in-person meetings

Record with iPhone Voice Memos, AirDrop the `.m4a` to this Mac, then choose
**Edit an imported recording…** from Quill's menu. Drop the file into the
editor or choose **Import recording**. No iPhone companion app is required.

The editor copies the original audio into **Imported Meetings** inside your
recordings folder. It shows the full waveform and duration, then automatically
runs the selected Parakeet model and FluidAudio's offline speaker diarizer.
Speaker count defaults to **Automatic**; an optional participant count guides
the next analysis. Automatic detection can merge distinct voices, especially
in noisy or overlapping recordings. If the count is wrong, set the known
participant count and run transcription again. The separate speaker models
download on first use; recording audio is never uploaded.

Double-click a timeline lane name to rename a speaker. **+ Speaker** adds a
participant after analysis. Unassigned audio can contain several people: adding
a speaker assigns only the selected unassigned segment unless you explicitly
choose all unassigned segments. Pinch or hold Option while scrolling to zoom
around the pointer; ordinary scrolling pans the timeline. Fit and zoom buttons
remain available.

Select a segment to hear it and inspect its words. Move it to another speaker
lane, assign a speaker with the number keys, split at the playhead, or adjust
its boundaries. These operations change speaker annotations while preserving
the original audio and its timing. Overlapping speech can belong to multiple
speakers; the lanes are not isolated audio stems. Other or ambiguous voices
remain visible instead of being forced into a participant's identity.

Confirmed corrections are protected. After confirming clear examples of each
detected participant, **Refine remaining audio** compares session-local voice
evidence to those examples and revisits unconfirmed segments. Weak matches stay
uncertain. This is conservative acoustic matching, not model retraining or
cross-meeting voice recognition. It cannot recover words obscured by noise or
simultaneous speech. Refinement is undoable.

Double-click transcript wording to edit it. Wording corrections save separately
from speaker confirmations, preserve the original recognition, and survive
speaker refinement and timeline splits. Running transcription again requires
explicitly resetting wording corrections first. Double-click the heading to
rename a meeting. **View transcript** opens a reading view with Copy, Export,
and a nonlocking **Mark reviewed** state; further transcript edits return it to
draft.

Sessions save automatically and can be reopened from the editor. `session.json`
is the editable source of truth; `transcript.json` and `transcript.md` are
regenerated from the corrected annotations. A failed save stays visible and
must be retried before closing or quitting. Imports do not enter the normal
mic/system transcription queue or run its hooks.

### Optional local meeting notes (experimental)

Settings separates **Speech to text** from **Meeting notes**. Download and select
Qwen3.5 2B Q4_K_M (1.27 GB), Qwen3.5 4B Q4_K_M (2.71 GB), or SmolLM3 3B
Q4_K_M (1.92 GB). New imports automatically transcribe and generate notes when
the selected notes model is ready. No wording corrections or speaker
confirmations are required. Existing meetings have a **Generate notes** button;
reopening a meeting does not regenerate or replace its notes.

Draft notes open as readable text with a suggested title, summary, key takeaways,
and agreed action items. **Edit notes** and individual transcript wording edits
are optional. **Use as meeting title** applies the suggestion explicitly.
Qwen3.5 4B supplies a collapsed **Sources** section linking generated claims to
saved transcript excerpts and audio playback. Editing a generated claim clears its old source
references; changing the transcript marks the notes and links as outdated.

Qwen3.5 4B first extracts facts with source IDs, checks those IDs, retrieves
the exact source text, then writes notes from that evidence. Requests and
suggestions belong in takeaways unless explicitly accepted as future actions.
An authentic quotation does not prove that a model interpreted it correctly:
these small models can still omit facts or misread unclear speech. The notes
remain experimental, and the source links are available when a detail matters.
The smaller models retain direct generation: the extra extraction stage reduced
their accuracy in local output checks. The default model choice is unchanged.

Notes run on Apple silicon using a pinned llama.cpp worker downloaded from its
official release alongside the model. Model and runtime downloads are checked
against pinned SHA-256 digests. Generation uses bounded context, divides long
transcripts into sections, and runs one job at a time. The worker exits after
completion, cancellation, or failure; there is no resident notes server. Once
downloaded, generation works offline. Models and their selection are stored
under `~/Library/Application Support/quill/notes/`.

For development, `bash scripts/build-meeting-preview.sh` creates an isolated
native editor using the real views and local inference. Its default test data
stays under `.build/meeting-evidence/recordings`; set
`QUILL_MEETING_TEST_ROOT` to choose another test root. The preview executable
also accepts `analyze AUDIO_PATH PARTICIPANTS` for local pipeline verification
without printing the transcript into the terminal. For notes evaluation, use
`notes TRANSCRIPT_PATH MODEL_ID STRATEGY OUTPUT_JSON`, where `STRATEGY` is
`evidenceFirst` or `singlePass`. This developer command
saves raw intermediate model output beside the result; the normal app does
not retain intermediate prompts or model output.

`scripts/notes-eval/run.py --help` describes the serial evaluation runner and
native-app memory monitor. The ten Italian/English fixtures in
`scripts/notes-eval/cases.json` are authored synthetic transcripts, not recorded
meetings. Expected and forbidden claims never enter the model prompt. Keep
real recordings, transcripts, and evaluation output outside the repository.

The engine sits behind a small protocol; a Whisper engine (WhisperKit
large-v3-turbo) is planned as the fallback / re-transcription option.

## Config

Optional, at `~/.config/quill/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": {
    "enabled": true,
    "engine": "parakeet",
    "model": "parakeet-v3"
  },
  "on_stop": "my-hook"
}
```

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `transcription.enabled` — set `false` to just record.
- `transcription.model` — selected local model: `parakeet-v3` (recommended
  Italian/multilingual default) or `parakeet-v2` (English-focused alternative).
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript is written** (or right after recording if
  transcription is disabled). Wire it to whatever comes next: summarization,
  filing, indexing.

## CLI

```sh
quill                        # run the menu-bar daemon (^C to quit)
quill run --out <dir>        # custom recordings root (default ~/Recordings)
quill doctor                 # check permissions, recordings folder, models
quill install --launch-at-login
quill install --uninstall
quill update --check
quill update
```

## Stack

- **Swift** — single SPM executable target
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
  system audio capture via a private aggregate device
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming AAC encode into CAF
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **NSStatusItem** — the whole UI

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- Parakeet v2 is English-only; choose the recommended v3 model for Italian and
  multilingual meetings.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a LaunchAgent.
