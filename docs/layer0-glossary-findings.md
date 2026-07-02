# Layer 0 (glossary prompt biasing) — findings

**Status:** Layer 0 prompt biasing is **not viable** with the current ASR model
(`whisper-large-v3-turbo`). It stays **disabled** in the app. Jargon is handled by Layer 1
(deterministic dictionary). This documents what we tried, the data, and the decision.

## Goal

"Add a word to my vocabulary → it gets recognised" (e.g. *GicoCam*, *ChacharApp*) without having to
guess the misheard spelling. The intended mechanism (Layer 0) was to feed the glossary to WhisperKit
as decoder **prompt tokens** (`DecodingOptions.promptTokens`), which bias the recogniser toward those
terms — the on-device equivalent of OpenAI Whisper's `initial_prompt`.

## Symptom

Passing `promptTokens` made WhisperKit return **empty** transcriptions for the terms we care about,
so Layer 0 was disabled early on (the app transcribes with `prompt: nil`).

## Investigation

We read the WhisperKit 1.0 decoder and ran a controlled matrix with the spike
(`swift run chacharapp-spike <audio> --lang <code> --prompt "<terms>"`) on the bundled test clips
(`jfk.wav` EN, `es_test_clip.wav` ES), turbo model.

### 1. First hypothesis — `firstTokenLogProbThreshold` bug

The decode loop computes `isFirstToken = (tokenIndex == prefilledIndex)` and, when prompt tokens are
present, evaluates `firstTokenLogProbThreshold` (default `-1.5`) against the *first forced prefill
token* rather than the first decoded token, which can break the loop immediately
(`TextDecoder.decodeText`, the `isFirstTokenLogProbTooLow` early-break). We set
`firstTokenLogProbThreshold = nil` when a prompt is present.

**Result: did not fix it.** Output was still empty.

### 2. Second hypothesis — quality gates discard the segment

We then nulled the other gates that can reject a segment as "failed":
`compressionRatioThreshold`, `logProbThreshold`, `noSpeechThreshold` (when a prompt is present).

**Result: did not fix it either.** Still empty.

### 3. Empirical matrix (turbo)

| Prompt | In audio? | Tokens | Result |
|---|---|---|---|
| *(none)* | — | — | ✅ full, correct |
| `ask not what your country` | yes | several | ✅ |
| `country` | yes | 1 | ✅ |
| `Kubernetes` | no | few | ✅ |
| `GicoCam` | no | (rare) | ❌ empty |
| `banana apple orange table` | no | several | ❌ empty |
| `Vocabulary: GicoCam, ChacharApp.` | no | several | ❌ empty |
| `GicoCam, ChacharApp, Kubernetes, WhisperKit` (es clip) | no | many | ❌ empty |

The failure correlates with **incoherent / out-of-context prompts** (a list of disjoint proper
nouns), not with token count or quality thresholds. Coherent prompts, or prompts whose words appear
in the audio, decode fine.

## Root cause

`large-v3-turbo` was distilled without robust "condition on previous text" training. WhisperKit wraps
`promptTokens` with `<|startofprev|>` to mean *"the previous transcription said this"*. When that
context is an incoherent glossary list unrelated to the audio, the turbo decoder **collapses** —
it emits an immediate end-of-text, so the segment between `<|startoftranscript|>` and `<|endoftext|>`
contains no word tokens → empty text. This is a model-capability limitation, not a fixable WhisperKit
threshold setting.

A glossary prompt is applied to **every** utterance, and most utterances do **not** contain the
jargon, so this collapse would break normal dictation. That makes Layer-0-as-prompt a non-starter on
turbo.

## Decision

- **Keep Layer 0 disabled** on turbo. The model must not be changed (project constraint), and the
  spoken-prompt path is wired but unused (`makeDecodeOptions`, called with `prompt: nil`).
- **Reach the "add a word" goal via Layer 1 instead** — deterministic, reliable, free. Candidate
  improvements (next): fuzzy / phonetic matching so a glossary term auto-catches its likely
  mishearings (today you must add the exact misheard form, e.g. `hikokam → GicoCam`); and/or feeding
  the glossary to the optional Layer 2 LLM for correction.
- Re-evaluate Layer 0 only if/when a non-turbo model (e.g. `large-v3`) becomes selectable
  (Epic B, model management) — full Whisper models condition on prompts far more reliably.

## Reproduce

```bash
swift run chacharapp-spike .build/checkouts/WhisperKit/Tests/WhisperKitTests/Resources/jfk.wav \
  --lang en --prompt "GicoCam"        # → empty
swift run chacharapp-spike .build/checkouts/WhisperKit/Tests/WhisperKitTests/Resources/jfk.wav \
  --lang en --prompt "ask not what your country"   # → full transcription
```
