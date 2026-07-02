# Device support — what runs ChacharApp well

> Which Macs run ChacharApp, and how much RAM each configuration needs. The short version: **any
> Apple Silicon Mac dictates well out of the box; the optional Layer 2 cleanup is what raises the
> bar**. These figures feed the model-tier decision in
> [`decisions/0002-distribution-and-packaging.md`](../decisions/0002-distribution-and-packaging.md).

## The one hard requirement: Apple Silicon

- **ASR (always on).** WhisperKit runs the speech model on CoreML / the Apple Neural Engine.
  On Apple Silicon this is fast and power-efficient. On Intel Macs it falls back to CPU/GPU and is
  much slower, with no ANE.
- **Layer 2 cleanup (optional).** The local LLM runs on **MLX**, which is **Metal / Apple-Silicon
  only**. It will not run on Intel at all.

So ChacharApp targets **Apple Silicon (M1 and later)**. Intel is out of scope for the full
experience.

## RAM: driven almost entirely by the cleanup model

Base dictation is light. The variable is whether you also run the Layer 2 cleanup LLM, and which
one. Cleanup is **off by default** — a fresh install only needs the ASR model.

| Configuration | Resident RAM | 8 GB | 16 GB | 24 GB+ |
|---|---|---|---|---|
| Dictation only — Whisper turbo (**default**) | ~1.5 GB | ✅ great | ✅ | ✅ |
| + Cleanup **Qwen 1.5B** (4-bit) | ~1.2 GB | ✅ | ✅ | ✅ |
| + Cleanup **Qwen 3B** (4-bit) | ~2 GB | ⚠️ tight | ✅ | ✅ |
| + Cleanup **Qwen 7B** (4-bit, L2 default) | ~4–5 GB | ❌ swaps | ⚠️ tight | ✅ |

Reading it:

- **M1 / 8 GB** — dictates perfectly (cleanup is off by default). If you want cleanup too, pick the
  1.5B model; the 7B will thrash swap.
- **16 GB** — dictation plus the 3B is comfortable; the 7B is usable but leaves little headroom.
- **24 GB and up** — the 7B default is fine.

Pick the cleanup model in **Settings → Models** (the capabilities table lists size/RAM/speed), or
disable cleanup entirely in **Settings → Cleanup**.

## Disk

- Bundled Whisper turbo model: ~626 MB (ships inside the app).
- Cleanup models download on first use: ~1 GB (1.5B) to ~4.3 GB (7B), cached under the user's
  Hugging Face cache.

## Latency

Numbers are measured on the reference machine (M5 Pro, 64 GB) — see [`latency.md`](latency.md).
Smaller/older chips are slower but still interactive:

- **Transcription:** RTF 0.10–0.15× on M5 Pro (an 11 s clip → ~1–1.7 s). Expect an M1 to be
  meaningfully slower per second of audio, but short phrases still land in ~1–2 s.
- **Cleanup (7B):** ~65 tok/s on M5 Pro, 0.6–2.7 s per phrase. Smaller models are faster
  (1.5B/3B) at some quality cost. On tighter RAM, prefer a smaller model to avoid swap, which would
  dominate any compute difference.

## Rule of thumb

- **Just want dictation?** Any Apple Silicon Mac, any RAM. Ship it.
- **Want the LLM cleanup too?** 16 GB for the 3B, 24 GB+ for the 7B, or the 1.5B on 8 GB.
