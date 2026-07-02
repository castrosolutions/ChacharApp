# ADR 0001 — ASR engine choice

- **Status**: Accepted
- **Date**: 2026-06-25
- **One-line decision**: use **WhisperKit** with the **`whisper-large-v3-turbo`** model
  on-device (CoreML/ANE) as the default speech-recognition engine.

## Context
ChacharApp must transcribe speech to text meeting, **in priority order**: (1) accuracy with my
Spanish voice, technical jargon and pronunciation; (2) free and 100% local; (3) minimal latency
in push-to-talk. Real usage mixes Spanish with English **code-switching** (technology names:
"AWS", "S3", "Kubernetes", "i3", libraries) and vocabulary that benefits from being **biased**
toward my terms. Target hardware is an M5 Pro (64 GB) on macOS 26.

Derived **requirement #1**: the engine must support **vocabulary biasing** and be **robust to
ES↔EN code-switching**.

## Decision
Adopt **WhisperKit** (Argmax Open-Source SDK, `argmax-oss-swift`, tag ≥ `v1.0.0`) with
`whisper-large-v3-turbo`, running on-device on CoreML/ANE. Vocabulary biasing is implemented via
`initial_prompt` / `promptTokens` (glossary; correction Layer 0).

## Alternatives considered

### Apple `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26) — REJECTED
The replacement for the old `SFSpeechRecognizer`. Rejected because:
1. It **removed `contextualStrings`** ⇒ **no vocabulary biasing**, exactly requirement #1.
2. **Bound to a `locale`** per session ⇒ weak ES↔EN code-switching.
3. **Insufficient accuracy**: Argmax measured ~**14% WER** in English (≈ Whisper-*small*),
   worse than *small*.

### Parakeet-tdt-0.6b-v3 (via FluidAudio) — REJECTED as default (kept as plan B)
A strong, ~10× faster alternative; ~**3.45% WER** (FLEURS). Rejected as default because:
1. **Vocabulary biasing** lives in their **paid** SDK (Pro).
2. **Per-utterance language auto-detection** ⇒ risk with short mixed ES↔EN phrases.
3. Its **speed** advantage (~0.3× real-time) **is not perceived** in push-to-talk with short
   utterances: the bottleneck is the model, not throughput.

Kept as **plan B** and as a spike contender.

### Whisper `large-v3` / `-turbo` — CHOSEN
- Spanish ~**3.65% WER** (ties Parakeet) and **strong at code-switching**: keeps "AWS"/"S3" in
  English inside Spanish sentences.
- Supports **biasing** via `initial_prompt`.
- **`-turbo`** is ~5× faster than `large-v3` with minimal accuracy loss. WhisperKit gives
  ~**1–1.5 s per utterance** in PTT, acceptable within the latency budget.

## Consequences
- **Positive**: meets requirement #1 (biasing + robust code-switching), 100% local and free,
  acceptable PTT latency, open-source and native Swift/SPM SDK.
- **Negative / risks**:
  - We depend on WhisperKit's CoreML packaging and its prompting API (confirm `promptTokens`
    in 1.0).
  - The initial model download (~626 MB compressed variant) needs asset management (not
    versioned in the repo; see `.gitignore`).
- **Validation with own data**: this decision is **ratified (or refuted)** by the **measurement
  spike** (see `docs/plan-mvp.md`). If the spike contradicts these numbers, we reconsider with
  Parakeet (plan B).
- **Performance clarification (myth to avoid)**: "`large-v3` at 8× real-time on M5 Pro" is
  **optimistic**. For full `large-v3` the decode is memory-bandwidth-bound (~3–5× real-time;
  the M5 only gains ~1.2× over the M4). The **8× only applies to `-turbo`**. Do not use the 8×
  figure for full `large-v3` in docs or latency math.

## References
- WhisperKit / Argmax Open-Source SDK: <https://github.com/argmaxinc/WhisperKit> (tag `v1.0.0`,
  2026-05-01).
