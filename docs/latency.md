# Latency — estimates and budget

> Estimates for WhisperKit `large-v3-turbo` on the target hardware (Apple M5 Pro, 64 GB), with
> the model and microphone kept **warm**. The estimates below were written first; the
> **Measured** section further down confirms them with real on-device numbers (transcribe
> RTF 0.10–0.15×, warm load ~1 s).

## What scales and what doesn't
Transcription cost is **not fixed per utterance**: it scales with the **number of words**
spoken, because the decoder generates tokens autoregressively. Turbo has only **4 decoder
layers** (vs 32 in `large-v3`), so decoding is ~5× faster. What is **not** paid per utterance
is **model load**: the model is loaded **once** at app launch and kept warm. Hence: short
phrase → fast; long text → a few seconds. This is the desired behaviour.

## Estimates (warm model + warm mic, `large-v3-turbo`)

| You dictate | Audio | Wait after releasing F7 (batch) | With streaming |
|---|---|---|---|
| 5 words | ~2–3 s | **~0.3–0.8 s** | ~0.3–0.5 s |
| One sentence (~12–15 words) | ~5–6 s | **~0.6–1.3 s** | ~0.4–0.7 s |
| Long paragraph (~70 words) | ~25–30 s | ~2.5–5 s | **~0.6–1 s** |

- **Batch** (transcribe the whole clip on release): long text rises to a few seconds,
  proportional to what was said — never 20 s.
- **Streaming** (transcribe while speaking; on release only the tail remains): the wait after
  release is **near-constant** whether 5 or 70 words were said. This is the key to keeping long
  dictations responsive, and is the design the spec calls for.

## Where 20 s would come from (and how the design avoids it)
- **Cold model** (load ~2–5 s) → load at launch + a warm-up inference with a dummy buffer, so
  even the **first** transcription isn't slow.
- **Cold mic** (Bluetooth/AirPods +1–3 s) → keep the audio tap active (warm mic).
- **No ANE** (Intel) or **full `large-v3`** instead of turbo → 5–10× slower; that is where ugly
  numbers appear. Avoided by requiring Apple Silicon + using turbo.
- 20 s for 5 words = only if several of these stack. On the target setup: ruled out.

## Latency budget (end-to-end, local only)
`release` → [audio already captured by streaming ≈ 0] → [transcribe tail ~1–1.5 s with turbo] →
[correction layers 0–1: instant] → [inject ~50 ms]. Layer 2 (local MLX LLM, only when the
cleanup toggle is on) adds ~0.6–2.7 s per phrase (7B, measured — regenerate with
`Scripts/bench-cleanup.sh`). The largest real latency risk is the **cold mic**: keep it warm
(or accept the small warm-up in the default mic-only-while-dictating mode).

## Measured — first data point (M5 Pro, `large-v3-turbo` 626 MB)
First real numbers from `chacharapp-spike` on synthetic TTS audio (not yet real-user
voice, so WER is not meaningful here — Phase 2 measures that). They validate the timing model:

| Metric | First-ever run | Warm run (cached) |
|---|---|---|
| Model load + warm-up | ~46.5 s | **~1.0 s** |
| Transcribe 11.0 s audio | 1.65 s (RTF 0.15×) | **1.06 s (RTF 0.10×)** |

Reading:
- **Transcription is ~7–10× faster than real time.** An 11 s utterance → ~1–1.7 s. Nowhere near
  the feared 20 s, and consistent with the estimates above.
- **The ~46.5 s is a one-time cost**: CoreML specializes the model to the chip on first load and
  caches it; subsequent launches load in ~1 s. The cache can be evicted after an OS update,
  re-triggering specialization. If that startup hit ever matters, enable WhisperKit `prewarm`
  or pre-specialize on install.
- Code-switching held up: "Kubernetes", "S3", "AWS" stayed in English inside Spanish.

## To be measured (Phase 2 WER spike — still pending)
Record 15–20 real-voice phrases and measure **WER** alongside per-utterance latency for
short / medium / long inputs on the M5 Pro (results to live in `docs/spike/results.md` once the
spike runs — the file does not exist yet). The latency side is already validated by the
measurements above; the accuracy side is what the spike still owes.
