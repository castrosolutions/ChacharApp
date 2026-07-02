# Plan — ChacharApp (phased MVP)

> **Historical planning document**, kept for context. Phases 0/1/3/4 shipped; Phase 2 (the WER
> spike) is still pending. Current status lives in [`../CLAUDE.md`](../CLAUDE.md) and the living
> plan in [`roadmap.md`](roadmap.md). Details below (the `Package.swift` sketch, checklists) are
> frozen as written and no longer match the code exactly.

## Guiding principle
Build a **pure, testable core (`ChacharCore`)** with two consumers: the **menubar app** (live
PTT) and the **measurement spike** (CLI). The ASR engine, audio capture and correction are
written **once** and reused.

## Decisions taken
- **Product / package name**: `ChacharApp` (= directory).
- **First deliverable**: the **live vertical slice** (F7 → mic → WhisperKit → show text).
  Reason: it's what was asked ("the scope is to get my microphone transcribed") and, once it
  works, it **unblocks** recording the 15–20 spike phrases with the app itself.
- **Repo language**: English (open-source ready).

## Proposed SPM layout
```
ChacharApp/
├── Package.swift
├── Package.resolved             # versioned after `swift package resolve`
├── .gitignore
├── CLAUDE.md
├── decisions/
│   └── 0001-asr-engine.md
├── docs/
│   ├── plan-mvp.md
│   ├── latency.md
│   └── spike/
│       ├── results.md           # results table (versioned)
│       └── audio/               # raw recordings (git-ignored)
├── Models/                      # downloaded CoreML model (git-ignored)
├── Sources/
│   ├── ChacharCore/             # pure, testable library
│   │   ├── Audio/               # AVAudioEngine capture, resample 16 kHz mono
│   │   ├── ASR/                 # Transcriber protocol + WhisperKitTranscriber
│   │   ├── Correction/          # Corrector protocol + layers 0/1 (2 later)
│   │   └── Support/             # shared types, logging
│   ├── ChacharSpike/            # CLI executable: measures WER + latency per engine
│   └── ChacharApp/              # AppKit menubar executable (PTT)
└── Tests/
    └── ChacharCoreTests/
```

### Proposed `Package.swift`
```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChacharApp",
    platforms: [
        .macOS(.v14) // target macOS 14+ (WhisperKit supports v13)
    ],
    products: [
        .library(name: "ChacharCore", targets: ["ChacharCore"]),
        .executable(name: "chacharapp", targets: ["ChacharApp"]),
        .executable(name: "chacharapp-spike", targets: ["ChacharSpike"]),
    ],
    dependencies: [
        // WhisperKit (Argmax Open-Source SDK): on-device ASR engine (CoreML/ANE).
        // Pin to a real tag >= 1.0.0; the README's `from: "0.9.0"` is OBSOLETE.
        // .upToNextMinor => 1.0.x; NEVER .upToNextMajor. Package.resolved pins the commit.
        .package(
            url: "https://github.com/argmaxinc/WhisperKit.git",
            .upToNextMinor(from: "1.0.0")
        ),
    ],
    targets: [
        .target(
            name: "ChacharCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .executableTarget(name: "ChacharApp", dependencies: ["ChacharCore"]),
        .executableTarget(name: "ChacharSpike", dependencies: ["ChacharCore"]),
        .testTarget(name: "ChacharCoreTests", dependencies: ["ChacharCore"]),
    ]
)
```

## Phase 0 — Setup
- [x] git init, `.gitignore`, `CLAUDE.md`, `decisions/0001-asr-engine.md`, this plan,
  `docs/latency.md`.
- [~] Download the turbo model into `Models/` (running).
- [ ] `Package.swift` + `Sources/` skeleton + `swift package resolve` (generate and version
  `Package.resolved`).

## Phase 1 — Live vertical slice (PTT → text) ← FIRST DELIVERABLE
- Global hotkey **F7** (configurable), hold-to-talk (`keyDown`/`keyUp`).
- `AVAudioEngine` capture with a **warm mic** + streaming, resample to 16 kHz mono.
- WhisperKit `large-v3-turbo` transcription (only the tail on release).
- Output: first **show the text** (validate ASR end-to-end); injection comes later.
- Menubar app (`NSStatusItem`, `LSUIElement`), `.app` bundle + microphone TCC permission.
  Possible **ADR 0002** (packaging and signing).
- Useful sub-milestone: **record audio** from the app to feed the spike.

## Phase 2 — Measurement spike (ratifies ADR 0001)
Goal: **ratify (or refute) Whisper with own data**.
- Record **15–20 real phrases** (jargon, "AWS"/"S3" interleaved, odd pronunciation, ES↔EN
  code-switching) — reusing Phase 1 capture.
- `chacharapp-spike`: ingests the audio and transcribes with:
  - (a) `whisper-large-v3-turbo` **with** and **without** glossary (Layer 0),
  - (b) Parakeet-tdt-0.6b-v3 (FluidAudio) — plan B,
  - (c) optional: Apple `SpeechAnalyzer` (comparison only).
- Metric: **WER** + **latency** + qualitative inspection of code-switching and jargon.
- Deliverable: **results table** in `docs/spike/results.md`.

## Phase 3 — Layered correction
- Layer 0 (glossary, validated in the spike) + Layer 1 (deterministic editable dictionary that
  learns from my corrections).
- `Corrector` interface for an **optional, swappable** Layer 2 (LLM) (Haiku ↔ local MLX).

## Phase 4 — Universal injection
- Clipboard + synthetic Cmd-V (CGEvent) saving/restoring the clipboard; fallback unicode typing.
  Accessibility TCC permission.

## Risks / notes
- **Cold mic** = the real latency risk: keep it warm (active background tap).
- **Biasing via `promptTokens`**: confirm the exact API in WhisperKit 1.0.
- **`.app` bundle** required for TCC and the menubar agent; the spike CLI does **not** need it
  (it can request microphone permission as a plain executable).
- **F7 on Mac**: by default a media/brightness key; using it as a standard key requires a system
  setting or remapping (the developer already uses MX Keys / Karabiner-style software).
- See [`latency.md`](latency.md) for the latency model and estimates.
