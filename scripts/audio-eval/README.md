# Local audio accuracy evaluation

This developer harness compares supplied audio variants through Quill's real
Parakeet engine. It does not create variants, preprocess audio, install models,
run diarization, generate notes, or change the installed app's settings.

Build the existing native preview when authorized:

```sh
scripts/build-meeting-preview.sh
```

The native command accepts:

```sh
.build/meeting-evidence/QuillMeetingPreview.app/Contents/MacOS/QuillMeetingPreview \
  transcribe /absolute/path/audio.wav parakeet-v3 current /absolute/path/result.json
```

Both profiles explicitly override `ASRConfig.melChunkContext`, independently of
current app defaults. `current` pins the earlier `true` configuration; `multilingual`
pins `false` and is accepted only for `parakeet-v3`. Neither profile forces an output
language or performs translation. `parakeet-v2` accepts `current` only. The selected
model must already be installed; preparation never downloads it.

The command prepares the model, transcribes timed words, and releases it on both
success and failure. It refuses an existing output file, including at final write.
SDK console output is suppressed during inference. The JSON file contains the
plain transcript, `{text,start,end}` words, audio duration, model/profile/config,
input SHA-256, and preparation/transcription/total elapsed seconds. Native elapsed
time includes model preparation and cleanup but excludes input hashing and output
writing. Failure output contains only an error domain and code, not recognized words.

## Serial comparisons

Create a manifest outside the repository. All relative paths resolve beside it:

```json
{
  "reference": {
    "path": "reference.txt",
    "provenance": "Human transcription of this exact audio; author and review date supplied by the evaluator"
  },
  "variants": [
    {
      "id": "original-current",
      "audio": "original.wav",
      "model": "parakeet-v3",
      "profile": "current",
      "description": "Unmodified input"
    },
    {
      "id": "processed-multilingual",
      "audio": "processed.wav",
      "model": "parakeet-v3",
      "profile": "multilingual",
      "description": "Evaluator-provided preprocessing variant; record its settings here"
    }
  ]
}
```

Omit `reference` entirely when no reference exists. A variant can supply its own
`reference` object, or set `reference: null` to disable a shared reference. References
require an explicit provenance description. Label synthetic text and previous ASR
outputs accurately; the harness never treats either as a verified human transcript.
No reference text is created automatically or sent to the recognizer.

```sh
python3 scripts/audio-eval/run.py \
  --preview .build/meeting-evidence/QuillMeetingPreview.app/Contents/MacOS/QuillMeetingPreview \
  --manifest /absolute/path/evaluation/manifest.json \
  --output /absolute/path/evaluation/run-001 \
  --monitor-memory
```

The output directory must be new. Variants run one at a time in manifest order;
there are no automatic retries. `evaluation.json` records the manifest and native
executable hashes. Each variant gets its native output, a local log, `result.json`,
and optional memory samples. `runs.json` collects metadata and metrics. Terminal
output contains run IDs, status, timing, and numeric scores only. Keep all actual
recordings, references, and generated transcripts outside the repository.

`--monitor-memory` reuses the existing macOS notes-eval process-tree monitor. Its
sampled RSS and physical footprint are process measurements, not system memory
usage; native elapsed and full child-process wall time are recorded separately.
Without this option the metric library and its unit tests use only portable Python
standard-library modules.

## WER and CER

Scores are computed only when an explicit reference is supplied. Otherwise metrics
are null with an explanation that accuracy was not measured. Reference path, raw
SHA-256, and the supplied provenance are recorded with every scored run.

Normalization applies Unicode NFKC, case folding, punctuation-to-space replacement,
and whitespace collapse to both texts. Thus apostrophes and hyphens become token
boundaries. WER is minimum word substitutions + deletions + insertions divided by
reference word count. CER is character Levenshtein distance divided by reference
character count after removing spaces. Rates can exceed 1. An empty reference with
a nonempty hypothesis has an undefined rate (`null`); two empty normalized texts
score 0. These are transcription-distance metrics, not a semantic assessment.
Number words and digits are not made equivalent, so formatting differences can
contribute to the reported error rate.

## Interpreting comparisons

Keep decoding, recognizer configuration, and enhancement as separate comparisons.
Use the same decoded PCM input for all enhancement variants, retain the source,
and verify sample counts and alignment before interpreting timed words. Record
the enhancement implementation, model revision, settings, and processing cost
alongside the manifest. The runner measures recognition time only; preprocessing
must be measured separately.

A controlled synthetic reference can measure changes on that fixture, but it
does not establish accuracy on a natural conversation. Without a reference
checked against the recording, changes in word count, apparent fluency, or notes
cannot identify the correct transcript. A small aggregate improvement also does
not justify enabling a treatment that harms individual cases. Keep experimental
settings outside the app until representative recordings support the change.

Run the focused tests without audio, models, or downloads:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/audio-eval -p 'test_*.py'
```
