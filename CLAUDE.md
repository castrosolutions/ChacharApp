# CLAUDE.md — ChacharApp

Guide for contributors and coding agents. Keep this file **short, stable and always true**:
hard constraints, conventions and expensive-to-rediscover gotchas only. Project *status* lives
in [`docs/roadmap.md`](docs/roadmap.md); the code walkthrough in
[`docs/code-guide.md`](docs/code-guide.md) — don't duplicate them here.

## What it is
A macOS menu-bar voice dictation app: a **local, free** alternative to Wispr Flow. Hold a key
(push-to-talk, **Right ⌘** by default, configurable in Settings), speak, release — the
transcribed text is pasted into the focused app. Tuned for a Spanish speaker's voice, technical
jargon and Spanish↔English code-switching.

## Hard objectives (in priority order — use these to resolve trade-offs)
1. **Accuracy** with a Spanish speaker's voice, jargon and pronunciation.
2. **Free and 100% local.** The optional Layer 2 cleanup also runs locally (MLX); only plugging
   a remote model into its swappable interface would break this property.
3. **Minimal latency** between key release and inserted text (target sub-second, pure local).

## Conventions
- **Language**: all repo content (this file, `docs/`, `decisions/`, code, comments) in
  **English**. Type files in `UpperCamelCase.swift`.
- **SPM**: pin versions with `.exact(...)` or `.upToNextMinor(from:)`. **Never**
  `.upToNextMajor`, never moving branches. Commit `Package.resolved`. Each dependency carries an
  inline comment justifying what it resolves.
- **Commits**: conventional commits in English.
- All documentation lives **inside the repo**.
- **No sandbox**; **Developer ID** distribution (outside the App Store — see ADR 0002). TCC
  permissions: **Microphone + Accessibility**.
- Subprocess (if an external CLI is ever invoked): augment `PATH` explicitly (the app inherits
  a minimal `/usr/bin:/bin`).

## Build & environment gotchas (expensive to rediscover — read before building)
- **Build the app with xcodebuild, NOT `swift build`**: MLX's `default.metallib` is only
  compiled by Xcode's build system; a `swift build` binary crashes at runtime with "Failed to
  load the default metallib". Requires the **Metal Toolchain**
  (`xcodebuild -downloadComponent MetalToolchain`). `./Scripts/install.sh` does the right thing
  (builds, bundles `mlx-swift_Cmlx.bundle`, installs to /Applications).
  `swift build` / `swift test` still work for the MLX-free core and its unit tests.
- **Sign with the stable Apple Development cert** (the scripts do it automatically): ad-hoc
  signing loses the TCC grants (Mic + Accessibility) on every rebuild.
- **Layer 0 glossary prompt biasing is DISABLED by design**: on `large-v3-turbo` a glossary
  prompt collapses the decoder to an EMPTY transcription, and it is **not threshold-fixable**
  (investigated + measured — [`docs/layer0-glossary-findings.md`](docs/layer0-glossary-findings.md)).
  Do NOT try to re-enable it on the turbo model; revisit only with a non-turbo model. Jargon is
  handled by Layer 1 (dictionary + fuzzy phonetic matching).
- `Scripts/bench-cleanup.sh [modelId]` regenerates the Layer 2 benchmark numbers (xcodebuild +
  MLX — the `chacharapp-bench` target links MLX, so it can't use `swift run`).
- Reference environment: macOS 26 (Tahoe), Xcode 26, Apple Silicon (M5 Pro 64 GB).

## Architecture (decided — do not reopen without new data)
- **ASR**: WhisperKit `whisper-large-v3-turbo` (CoreML / Apple Neural Engine), on-device —
  [`decisions/0001-asr-engine.md`](decisions/0001-asr-engine.md).
- **Distribution**: open source (MIT), notarized Developer ID direct download —
  [`decisions/0002-distribution-and-packaging.md`](decisions/0002-distribution-and-packaging.md).
- **Correction is layered** behind swappable ports: Layer 0 glossary prompt (parked — see
  gotcha above) → Layer 1 dictionary + fuzzy phonetic + trailing-hallucination filter (always
  on, instant) → Layer 2 local MLX LLM cleanup (opt-in, off by default; default model
  `mlx-community/Qwen2.5-7B-Instruct-4bit`, any MLX instruct id selectable).
- **Injection**: clipboard + synthetic ⌘V (CGEvent), saving/restoring the user's clipboard.
- **Updates**: Sparkle 2 in distribution builds only (appcast on R2, EdDSA-signed). Dev builds
  intentionally omit `SUFeedURL`, so they never check or offer updates —
  [`decisions/0002`](decisions/0002-distribution-and-packaging.md) D9.

## Build / run
- `./Scripts/install.sh` — build the real app (xcodebuild) and install to /Applications.
- `swift build` / `swift test` — the MLX-free core and its unit tests.
- `swift run chacharapp-spike <audioFile>` — ASR measurement CLI.
- Release tooling (Developer ID `.dmg` + notarization + R2 publish) is **maintainer-local**, not in
  this repo — it needs the maintainer's signing cert and credentials. Contributors build with
  `install.sh` above.

## Where things are
- Project **status, epics & roadmap**: [`docs/roadmap.md`](docs/roadmap.md)
- **Code walkthrough** (read-like-a-book, diagrams): [`docs/code-guide.md`](docs/code-guide.md)
- Measured **latency** numbers & the latency model: [`docs/latency.md`](docs/latency.md)
- **Testing strategy** (unit-only on purpose, and why): [`docs/testing.md`](docs/testing.md)
- Device/RAM **support matrix**: [`docs/device-support.md`](docs/device-support.md)
