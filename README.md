# ChacharApp

**Local, free, private voice dictation for macOS.** Hold a key, speak, release — the
transcribed text is inserted into whatever app you're looking at. Everything runs
on-device: no cloud, no account, no subscription. Tuned for a Spanish voice that mixes
in English tech jargon (code-switching).

> The alternative to Wispr Flow without the cloud, the account, or the monthly fee.

---

## Why it exists

Every existing option falls short on something:

- **macOS built-in dictation** is weak with technical jargon and with the Spanish↔English
  switch mid-sentence.
- **Wispr Flow** is paid and **sends your audio and text to the cloud**.
- **Cloud Whisper APIs** add network latency and break privacy.

ChacharApp fixes all three: **local, free, and tuned to your voice.**

## What makes it different

1. **Total privacy** — neither audio nor text ever leaves your Mac. No telemetry, no
   account.
2. **Zero cost, no limits** — no subscription, no tokens.
3. **Sub-second latency, large-model accuracy** — Whisper runs through **WhisperKit
   (CoreML) on the Apple Neural Engine**, not on the CPU or GPU like most alternatives.
   Measured at ~7–10× faster than real time with the model kept warm and no network
   round-trip ([why this matters](#why-whisperkit--the-neural-engine-matter)).
4. **Accuracy tuned to your voice** — a **layered** correction pipeline that learns from
   your corrections:
   - a deterministic replacement dictionary,
   - **Spanish phonetic matching** that catches misheard jargon without writing the
     misspelling (e.g. "cubernetes" → "Kubernetes"),
   - an **optional local LLM** (MLX) that removes fillers and resolves spoken
     self-corrections ("en Postgres, no, en Redis" → "en Redis").
5. **Works in any app** — text is inserted via the clipboard + a synthetic ⌘V, so it
   works in native, Electron and web apps alike (not just "accessible" text fields).
6. **A push-to-talk key that works everywhere** — F7 on the built-in keyboard, or Right
   ⌘ on external keyboards whose function row is intercepted by their own software.
7. **Extensible by design** — a ports & adapters architecture: the ASR engine or the
   cleanup LLM can be swapped without touching the rest.

## Who it's for

Spanish-speaking developers and professionals on Apple Silicon who dictate a lot, mix in
English technical terms, and **don't want to send their voice to the cloud** or pay a
subscription.

---

## How it works

```
hold key → record mic → transcribe (Whisper, local) → correct (layered) → paste
```

- **ASR**: WhisperKit `large-v3-turbo` (CoreML/ANE), on-device.
- **Correction**: Layer 1 dictionary + phonetic matching (always on, instant); optional
  Layer 2 local-LLM cleanup (off by default).
- **Injection**: universal clipboard + synthetic ⌘V (your clipboard is saved and
  restored).

### Why WhisperKit + the Neural Engine matter

Most open-source dictation tools run Whisper through **whisper.cpp on the GPU** or
**faster-whisper on the CPU**. ChacharApp instead uses **WhisperKit**, which compiles the
model to **CoreML** and executes it on the **Apple Neural Engine (ANE)** — the dedicated
ML silicon in every Apple Silicon chip. Among the free/open-source dictation apps we've
surveyed, ChacharApp is the only one running Whisper itself on the ANE (the same engine
otherwise found only in leading paid apps). What that buys you in practice:

- **Speed *with* a large model.** `large-v3-turbo` transcribes at **RTF 0.10–0.15×**
  (measured: an 11 s utterance → ~1–1.7 s), so you get large-model accuracy for Spanish +
  English jargon without downgrading to a `small`/`base` model for latency's sake —
  whisper.cpp-based tools commonly sit at 2–5 s per dictation on comparable models.
- **Efficiency.** The ANE is built for exactly this workload and draws far less power
  than GPU inference: no fan spin-up, minimal battery impact, and the CPU/GPU stay free
  for whatever you're actually working on — which matters for an app that sits resident
  all day.
- **Warm and resident.** The model loads once (~1 s when cached) and stays hot, so the
  first press of the day behaves like every other one.

Numbers and methodology: [`docs/latency.md`](docs/latency.md).

A full, gradual walkthrough of the code — with diagrams — is in
[`docs/code-guide.md`](docs/code-guide.md).

## Status

A working end-to-end vertical slice, validated on device. Development environment: macOS
26 (Tahoe), Apple Silicon, Xcode 26. This is early-stage software; see
[`docs/roadmap.md`](docs/roadmap.md) for what's planned.

## Requirements

- **Apple Silicon** Mac, **macOS 14+** (developed on macOS 26).
- On first run, grant **Microphone** and **Accessibility** — a built-in setup guide walks you
  through both and downloads the speech model (~626 MB, one time).

## Install

Three ways to get ChacharApp — **all run 100% locally**. The only difference is how the app
gets onto your Mac: prebuilt via direct download or Homebrew, or compiled by you.

### Option A — Download the app (easiest)

1. Download the latest **notarized** `.dmg`:
   [**dl.juanpablocastro.com/releases/1.3.1/ChacharApp-1.3.1.dmg**](https://dl.juanpablocastro.com/releases/1.3.1/ChacharApp-1.3.1.dmg)
   (mirrored on the [**Releases**](../../releases) page).
2. Open the `.dmg` and drag **`ChacharApp.app`** into the **Applications** folder.
3. Launch it from Applications. The build is **Developer ID-signed and notarized**, so the only
   thing you'll see is macOS's standard one-time confirmation for downloaded apps ("Apple checked
   it for malicious software and none was detected") — click **Open**. No `xattr` or right-click
   workaround needed.
4. On first launch a **setup guide** walks you through the two permissions (**Microphone** and
   **Accessibility** — both required) and downloads the speech model (~626 MB, one time). Each
   step turns green as you complete it; after that, everything runs offline.

That's the last `.dmg` you download by hand: the app offers new versions **in-app** (Sparkle),
and always asks before checking automatically or installing anything. Updates keep your
settings, permissions and the downloaded model.

### Option B — Homebrew

The same notarized app, installed from the
[`castrosolutions/homebrew-tap`](https://github.com/castrosolutions/homebrew-tap) tap:

```sh
brew install --cask castrosolutions/tap/chacharapp
```

Launch it from Applications and follow the setup guide (step 4 above). Updates arrive through
the app itself (Sparkle) — or run `brew upgrade --cask chacharapp` explicitly. To uninstall,
`brew uninstall --cask chacharapp` — or add `--zap` to also remove settings, vocabulary,
history and the downloaded models.

### Option C — Build from source (no download, fully auditable)

Prefer to run your own build? You only need Xcode and one command.

Extra build requirement: **Xcode** with the **Metal Toolchain** installed
(`xcodebuild -downloadComponent MetalToolchain`) — MLX's Metal kernels are only compiled by
Xcode's build system.

```sh
git clone https://github.com/castrosolutions/ChacharApp.git
cd ChacharApp
./Scripts/install.sh          # builds the app and installs it into /Applications
```

The source build installs as **“ChacharApp (dev)”** with its own bundle id, so it can coexist
with the downloaded release (to macOS they are different apps with separate permission grants).
Launch it from Spotlight/Finder/Dock, or from the terminal:

```sh
open -a "ChacharApp (dev)"  # the copy install.sh put in /Applications
open .build/ChacharApp.app  # or run the freshly-built copy directly, without installing
```

Grant **Microphone** and **Accessibility** on first run (the setup guide walks you through it).

**Core only** — no app bundle, no MLX, no Xcode needed (for tests / hacking on the core):

```sh
swift build
swift test
swift run chacharapp-spike <audioFile>   # measure the ASR alone on an audio file
```

Either way, the app runs as a menu-bar agent: hold your push-to-talk key (**Right ⌘** by
default; F6/F7/F8 and other right-hand modifiers selectable in Settings), speak, and release.

## Privacy

100% local by default. The optional Layer 2 cleanup also runs locally (an MLX model on
your Mac). Your dictation history is stored only on disk, under
`~/Library/Application Support/ChacharApp/`, and never leaves the machine.

## Architecture & docs

- [`docs/code-guide.md`](docs/code-guide.md) — read-it-like-a-book guide to the source,
  with diagrams.
- [`decisions/`](decisions/) — architecture decision records (ASR engine; distribution).
- [`docs/`](docs/) — latency, the Layer 0 glossary
  investigation, the MVP plan and the roadmap.

## License

Released under the [MIT License](LICENSE). Created by [Juan Pablo Castro](https://juanpablocastro.com).
