# Local notes evaluation

Build the native harness with `bash scripts/build-meeting-preview.sh`, then run
`python3 scripts/notes-eval/run.py --help`. Supply the preview executable,
an installed model, and an output directory outside the repository. Runs are
serial. Expected and forbidden claims in `cases.json` never enter the prompt.
Raw notes, intermediate outputs, timing, source hashes, and sampled process
memory remain in the chosen output directory. Earlier notes are not overwritten.

## September 7, 2026 follow-up: generation controls and verification

**The tested changes did not improve the held-out results. Application defaults
remain unchanged.** Thirteen conditions produced 39 outputs on three known
Italian/English development cases. They tested atomic extraction with adjacent
context, fact and final-claim checks, temperatures 0/0.2/0.4/0.7, top-p 0.8/0.95,
top-k 20/40/disabled, and extraction thinking caps of 512/2048 tokens. This was a
staged comparison, not a full factorial search. Changing filters or adding
thinking did not eliminate the development status error. The full verifier
removed unsupported claims but discarded four useful expected facts.

One finalist was frozen before reviewing unseen outcomes: existing extraction,
the revised renderer, adjacent context, and final-claim verification, with atomic
extraction and fact verification disabled. Its development output retained 9
full and 1 partial expected facts out of 10, with one noncritical unsupported
priority. The control retained all 10 but had two unsupported claims, one critical.

The frozen finalist and control then generated 48 outputs: eight new synthetic
cases, two methods, and seeds 7, 42 and 2026. Two agents reviewed anonymized,
balanced batches against a fixed source-based rubric. The implementation and
candidate settings were not tuned on these outcomes. Full coverage earns 1,
partial coverage 0.5; 33 substantive expected facts repeated across three seeds
give 99 assessments per method. The no-clear-facts case is scored separately.

| Qwen3.5 4B condition | Full / partial / missing | Weighted coverage | Unsupported claims (critical) | Median time | Peak sampled RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Current evidence path | 76 / 17 / 6 | 85.4% | 9 (7) | 16.91 s | 3.13 GiB |
| Frozen finalist | 66 / 19 / 14 | 76.3% | 11 (8) | 28.22 s | 3.03 GiB |

Both methods appropriately abstained in all three no-clear-facts runs. All 48
outputs passed generation, language and citation-ID checks. These structural
checks did not establish factual correctness. The finalist lost coverage at
every seed; in one run it suppressed all four expected facts in a clear case.
It still introduced causal, unit and completion-status errors. “Critical” here
means a consequential change to a number/unit, owner, status, timing, polarity or
causal relationship, not a statistical confidence level.

This is a small, model-reviewed synthetic evaluation, not a human-validated
accuracy benchmark. Borderline wording was adjudicated consistently before
condition labels were opened; no cases or failed interpretations were excluded.
The eight seed-42 control outputs used the frozen prior binary; rebuilt controls
use the same baseline behavior, with exact-content reproduction checked on a
development case and the real transcript. Both finalists used temperature 0.7,
top-p 0.8, top-k 20, no thinking, 8,192 context tokens and 2,200 output tokens.

Both methods were also repeated three times on one unchanged real automatic
transcript. All three control runs completed; the finalist completed two and
failed one when its verifier returned the same target ID twice. The failure was
retained and was not rerun or counted as successful abstention. This transcript
has no human-listening reference, so its review assesses text faithfulness only.

The new pipeline and generation controls remain developer experiments. The app
continues to use its existing evidence path for 4B and direct generation for the
smaller models. A separate Astra Low comparison used the same real-transcript
extraction/rendering instructions and schemas, but different host context and
runtime. It is a useful comparison output, not gold or a hard upper bound.
Private recordings, transcripts, raw outputs and detailed score sheets remain
outside this repository.

## Earlier September 7 model comparison

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

## Generation and pipeline experiments

The native `notes` command accepts an optional final options-file argument:

```sh
QuillMeetingPreview notes transcript.txt qwen3.5-4b-q4_k_m \
  verifiedEvidence notes.json options.json
```

`singlePass` and `evidenceFirst` remain available as controls. `verifiedEvidence`
adds atomic extraction with literal source spans and unknown fields, adjacent
context, and separate checks of extracted facts and final claims. Model verdicts
are fallible judgments; citation validation does not prove that a claim is true.
The experiment can retain a useful qualified takeaway while leaving unclear
owners, dates, quantities, or terminology unresolved.

Options are internal developer inputs, not saved app preferences. Omitted fields
retain their defaults. For example:

```json
{
  "seed": 42,
  "contextTokens": 8192,
  "outputTokens": 2200,
  "defaultCompletion": {"temperature": 0.4, "topP": 0.8, "topK": 20},
  "stageOverrides": {
    "extraction": {"thinkingBudget": 512},
    "rendering": {"temperature": 0.2}
  },
  "verification": {
    "atomicExtraction": true,
    "verifyFacts": true,
    "verifyClaims": true,
    "includeContext": true
  }
}
```

This is an example experiment, not an accuracy recommendation. Stage names are
`extraction`, `verification`, `selection`, `rendering`, and `direct`. Optional
sampling/seed fields inherit from `defaultCompletion`; an explicit stage entry
has `thinkingBudget: 0` unless supplied, so a rendering override can turn thinking
off. Supported thinking budgets are 0, 512 and 2048, with thinking currently limited
to Qwen3.5 4B. Invalid settings or insufficient context are rejected.

The pinned raw completion path does not activate the backend reasoning-budget
sampler merely by supplying its flag. Quill instead bounds an initial thinking
continuation by its generation-token limit and closing marker, then replays it
inside a closed thinking block for a separate schema-constrained JSON completion.
The first pass may reach its limit mid-sentence. Context packing reserves both
thinking and final output, and the actual replay is counted again. Both worker
startups and replay cost count toward elapsed time. Reasoning is not returned in
notes or retained by the evaluation trace callback.

Pass the same file to the serial runner with `--options /absolute/path/options.json`.
Its result records requested options and their file hash; native metrics record
the decoded generation options. Use a fresh output directory for every condition
and seed. Keep the transcript fixed while testing prompts, sampling or thinking;
report failures, omissions and unsupported claims, not just fluent output or
valid JSON. Hold out unseen cases and repeat finalist configurations across seeds
before choosing application defaults. A frontier-model output is a comparison
specimen, not a reference transcript or a guaranteed upper bound.
