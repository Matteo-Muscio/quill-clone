# Local notes evaluation

Build the native harness with `bash scripts/build-meeting-preview.sh`, then run
`python3 scripts/notes-eval/run.py --help`. Supply the preview executable,
an installed model, and an output directory outside the repository. Runs are
serial. Expected and forbidden claims in `cases.json` never enter the prompt.
Raw notes, intermediate outputs, timing, source hashes, and sampled process
memory remain in the chosen output directory. Earlier notes are not overwritten.

## September 7, 2026 comparison

Ten authored synthetic Italian/English transcripts contain 29 expected facts.
These fixtures were used during development, so this is a development check,
not a held-out benchmark. An independent agent reviewed each output against
the expected and forbidden claims; partial coverage is distinct from an
unsupported claim. One deterministic run per configuration cannot establish
general accuracy.

| Configuration | Fully covered | Partly covered | Missing | Median time | Peak app + worker RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Qwen3.5 2B, direct | 14/29 | 13 | 2 | 2.54 s | 1.62 GiB |
| Qwen3.5 2B, evidence | 6/29 | 17 | 6 | 7.80 s | 1.58 GiB |
| Qwen3.5 4B, direct control | 20/29 | 9 | 0 | 5.18 s | 2.99 GiB |
| Qwen3.5 4B, evidence | 27/29 | 2 | 0 | 15.91 s | 3.13 GiB |

**No configuration passed the full fidelity check.** The 4B evidence path
covered more expected content, but still overstated a tentative option,
included closing small talk, and confused some statements with commitments.
The 2B evidence path introduced serious factual errors despite valid source
references. SmolLM3 was checked on two canaries rather than the full suite.

All configurations were also tested on one real, noisy automatic transcript.
None was reliable on that input; SmolLM3 additionally used the wrong language
and invented an exact date. That transcript was not corrected by listening to
the audio, so this does not isolate ASR errors from summarization errors. No
private recording, transcript, or generated content belongs in this repository.

The app therefore uses the evidence path for Qwen3.5 4B and retains direct
generation for the smaller models. Notes remain visibly labelled drafts and
experimental; the factory model choice stays unchanged. Source IDs establish
traceability, not whether the model interpreted the source correctly.

## Runtime and measurement

The runs used an M4 Pro Mac with 24 GiB RAM, the pinned llama.cpp runtime,
8,192 context tokens, disabled thinking, seed 42, and each model's published
temperature/top-p/top-k filters. Presence penalties were set to zero: the
pinned CLI includes prompt tokens in its penalty history, unlike vLLM's
output-only presence semantics. See `NotesPromptFormat.swift` for pinned
template references and the precise settings.

The table reports sampled RSS, not model download size or total system memory.
The runner separately records physical footprint and system swap snapshots.
Mapped model pages make RSS and physical footprint differ substantially.
CLI runs do not load transcription. Use `--monitor-pid` during a native import
to measure the complete transcription-to-notes flow, and create the reported
output directory's `stop` file after generation finishes. The app releases the
transcription engine before generating notes. Neither
measurement is a performance verification on a MacBook Air or a 16 GiB Mac.
