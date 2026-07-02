# Testing — strategy and current state

> How ChacharApp is tested, why the "web-app end-to-end" model (Playwright and friends) does not
> map cleanly onto a desktop dictation tool, and which layers we deliberately leave uncovered.
> This is a decision record as much as a status report: the gaps below are chosen, not accidental.

## Current state

Automated testing today is **unit tests only, and only over `ChacharCore`** — the pure,
dependency-free logic layer (no MLX, no AppKit, no hardware). The SPM `.testTarget`
(`ChacharCoreTests`) depends on `ChacharCore` and nothing else. Run them with `swift test`.

Covered:

| Test file | What it exercises |
|---|---|
| `VocabularyStoreTests` | glossary persistence + the malformed-file `lastParseError` path |
| `DictionaryCorrectorTests` | Layer 1 exact replacement |
| `FuzzyGlossaryCorrectorTests` | Layer 1 fuzzy/phonetic matching |
| `HistoryStoreTests` | dictation-history log (append, trim, malformed lines) |
| `ASRModelManagerTests` | on-disk model management |
| `ChacharCoreTests` | smoke |

**Not covered by any automated test** (by choice — see the reasoning below):

- `ChacharApp` — `AppDelegate`, `DictationController`, `HotkeyMonitor`, `HUDController`, and the
  whole SwiftUI/AppKit Settings surface.
- `ChacharCleanupMLX` — the Layer 2 MLX cleaner.
- The hardware/OS-boundary pieces: `WhisperKitTranscriber` (Apple Neural Engine),
  `MicrophoneCapture` (`AVAudioEngine`), `TextInjector` (Accessibility TCC + injecting into a
  third-party app).

There is **no CI**. `swift test` is run locally and on demand. The `.app` itself is built and
smoke-tested manually on device via `Scripts/install.sh` (see [`../CLAUDE.md`](../CLAUDE.md)).

## Why there is no automated end-to-end test

In a web app, end-to-end means driving a browser with Playwright: one sandbox, one process, a
stable Accessibility/DOM tree to assert against. The desktop equivalent exists — Apple's
**XCUITest** drives the real app through the macOS Accessibility tree. Two things make it a poor
fit here:

1. **Structural.** XCUITest wants a UI-test bundle in an `.xcodeproj`/workspace, not in SPM. It
   would add build-system friction to a project that otherwise lives in `Package.swift`.
2. **Fundamental — and this is the real reason.** ChacharApp's entire value lives *outside* its
   own process. The end-to-end path is: physical microphone → model on the ANE → a **global**
   hotkey pressed while focus is in **another** application → synthetic `CGEvent` keystrokes that
   inject text into that third-party app. Playwright never has to leave its sandbox; our happy
   path crosses the microphone, the Neural Engine, the window server, and TCC-gated Accessibility
   into an app we do not own. No test harness controls that chain. A UI test cannot meaningfully
   assert "the text landed in TextEdit after F7 was pressed" without becoming as fragile and
   environment-specific as the thing it claims to verify.

So the literal end-to-end (voice → text-in-another-app) is **not automated on purpose**. The
manual on-device smoke test after each `install.sh` is the pragmatic, honest substitute.

## The intended testing pyramid

Three levels, none of which chase the literal E2E:

1. **Unit (what we have).** Pure logic in `ChacharCore`. Cheap, fast, deterministic. Keep growing
   it as logic lands here.
2. **Integration with fakes at the seams (the deliberate gap).** The ports-and-adapters refactor
   made this *possible*: `DictationController` depends on `any Transcriber`, `any TextCleaner`,
   capture, vocabulary, and history through protocols. A `FakeTranscriber` returning canned text,
   a capture yielding a fixed buffer, and a spy injector would let a test drive `press()`/
   `release()` and assert the **whole pipeline** — capture → transcribe → Layer 1 → Layer 2 →
   inject → history — with no mic, ANE, GPU, or TCC involved. This is the highest-ROI test we
   *could* add, and it is the one that would prove "the feature still works end-to-end in logic
   terms". **We have chosen not to build it yet.** The one prerequisite when we do: `DictationController`
   currently lives in the `ChacharApp` executable target, which SPM tests poorly; the clean move
   is to relocate `DictationController` (and an `Injector` protocol) into `ChacharCore`, leaving
   `ChacharApp` as thin AppKit glue.
3. **Golden / contract tests, opt-in and local (not built).** A test that transcribes a fixed WAV
   and asserts a WER threshold; a test that runs Layer 2 over a fixed phrase and checks the
   cleanup. These guard accuracy against model swaps, but they need the model + hardware, so they
   must be manual/local and skipped by default — the same posture as the existing
   `chacharapp-bench` harness, which is
   effectively a manual, measured E2E for Layer 2.

## Decision

For now we stop at **level 1 (unit)**. Levels 2 and 3 are documented, understood, and
intentionally deferred — not forgotten. When the accuracy or pipeline surface starts changing
often enough that manual on-device checks stop being enough, the first step is the level-2
integration test on `DictationController`, which the recent refactor already unblocked.
