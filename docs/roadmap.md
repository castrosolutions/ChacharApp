# ChacharApp — roadmap

Living document. The MVP (push-to-talk → local Whisper → layered correction → injection) works and
is in daily use. This captures where we take it next.

## Product vision

ChacharApp is the **local, free, configurable intermediary** between your voice and any on-device
model — a self-hostable alternative to Wispr Flow. It owns the parts a model alone doesn't:

- the **global push-to-talk** shortcut and warm audio capture,
- **model management** — pick / download / import the ASR model *and* the cleanup model,
- **layered correction** — glossary biasing (L0), deterministic dictionary (L1), optional local-LLM
  cleanup (L2), all swappable,
- a friendly Mac UX you can **configure visually**,
- and the freedom to **publish it** (Developer ID, website download) as a polished, consistent app.

The cleanup (L2) is explicitly a **toggle**: on = it fixes your stumbles/self-corrections at the cost
of a few seconds; off = fastest path. The user accepts the trade-off and wants it configurable —
including swapping the cleanup model (Qwen today, anything tomorrow) or turning it off entirely.

## Status snapshot (done)

- PTT (**Right ⌘** default, F7 opt-in), warm mic, WhisperKit `large-v3-turbo` on-device, clipboard+⌘V injection.
- Layer 1 correction: deterministic dictionary (editable JSON, reloaded on change) + fuzzy phonetic
  matching + a trailing-"gracias"/"thank you" hallucination guard (silence trim + filter).
- Layer 2 local-LLM cleanup via MLX — Qwen2.5-7B-Instruct-4bit, hardened delete-only prompt,
  **benchmarked** (~65 tok/s, 0.6–2.7 s/phrase). Toggle persisted across launches.
- Install to /Applications, stable-identity signing (TCC persists), icons.
- **Distribution pipeline** ready: `Scripts/release.sh` produces a symbol-stripped, hardened,
  **Developer ID-signed, notarized + stapled `.dmg`** (Apple cert + `notarytool` profile set up; first
  0.0.1 build notarized). The model is **not** bundled — it downloads on first run. Open source (MIT).

---

## Epics

### A. Configuration & settings UI  ⭐ (core value-add)
Turn today's hidden state (menu toggle, raw `vocabulary.json`, hardcoded keys) into a real,
discoverable settings surface.

- [x] A **settings window** (SwiftUI) reachable from the menu (`Settings…`, ⌘,). Tabs:
      General / Cleanup / History / About.
- [x] A central **settings store** (`SettingsStore` + `AppSettings`): all options persisted as a
      single JSON blob in UserDefaults, migrating the old standalone `cleanupEnabled` key. Applied
      live via a Combine subscription in `AppDelegate`.
- [x] Configurable **push-to-talk key(s)** in the UI — multi-select over a curated catalog
      (F6/F7/F8 + right-hand modifiers); at least one stays enabled; hotkey rebuilt on change.
      (Arbitrary key-capture recording deferred to polish.)
- [x] Tunable **parameters** exposed safely: ASR language (es/en/nl/de/fr/it/pt/auto), L2 on/off +
      model selection, fuzzy matching, hallucination filter, mic mode, history retention — all
      applied live (no relaunch). (L2 generation params are deliberately *not* exposed: temperature
      is fixed at 0 and maxTokens is sized from the input.)
- [x] Host the **dictation history** viewer (Epic G).

### B. Model management  ⭐ (the "configurable" promise)
Make both the ASR and the cleanup model first-class, selectable, downloadable and importable.

- [x] **Capabilities table** per model (Models tab): size, RAM, speed (RTF / tok/s), quality,
      languages — seeded from our benchmarks (`ModelCatalog`). ASR + cleanup tiers listed.
- [x] **Select the cleanup model** live (Qwen 7B/3B/1.5B): pick in the Models tab → reload with
      download progress (`MLXTextCleaner.reload`); dictation skips Layer 2 while it loads.
- [x] **Download manager (cleanup)**: MLX downloads the chosen model from Hugging Face on first use,
      with progress surfaced in the UI.
- [x] **Reloadable ASR transcriber + select/import** (Phase 2a): `WhisperKitTranscriber.reload`,
      `ASRModelManager` (managed dir + folder validation). Models tab: select the bundled model or
      an imported one; a bad model falls back to the bundled one so dictation never breaks.
- [x] **Import** a local model folder (validated: MelSpectrogram/AudioEncoder/TextDecoder; warns if
      no offline `tokenizer.json`). Referenced in place.
- [x] **Download the ASR model** in-app (Phase 2b): Models tab "Download a Whisper model" section —
      per-model Download button + progress, into ChacharApp's managed folder, then auto-selected.
      (Re-enabling Layer 0 biasing once a non-turbo model is active is a separate follow-up.)
- [x] **Bundling vs on-demand: decided — download-on-first-run** (ADR 0002 D4). Large models can't
      ship inside the .app; `release.sh` bundles none and the app fetches `large-v3-turbo` on first
      launch (or loads an existing/imported copy).

### C. Recognition quality & personalization
The errors seen in practice are **vocabulary** gaps (proper nouns/jargon like "GicoCam"), not
acoustic — so the lever is biasing, not voice fine-tuning.

- [x] ~~**Fix Layer 0 glossary biasing**~~ — **Not viable on `large-v3-turbo`** (investigated &
      measured): a glossary prompt makes the turbo decoder collapse to an empty transcription, and
      it's not threshold-fixable. Disabled by design. See `docs/layer0-glossary-findings.md`.
      Revisit only with a non-turbo model (Epic B). The "add a word → recognized" goal pivots to a
      stronger Layer 1 (below).
- [x] **Fuzzy / phonetic Layer 1** — "add a word" now works without guessing the misheard form:
      `FuzzyGlossaryCorrector` reduces 1–3 word windows to a Spanish-oriented phonetic key
      (`PhoneticFold`) and replaces close matches with the canonical glossary term (e.g.
      *hikokam / hiko cam / jicokam → GicoCam*). Conservative (short terms skipped); on by default
      with a settings toggle. Unit-tested. The reliable replacement for Layer 0.
- [x] **Vocabulary editing UI** (Vocabulary tab) — add/edit/remove glossary terms and replacement
      rules visually; sanitises on save (trims, drops empty rows, normalises flags) and writes via
      the shared `VocabularyStore` so the next dictation picks it up. Replaces hand-editing the JSON
      (the menu item still opens the raw file for power users).
- [x] **Trailing-hallucination guard** — Whisper's end-of-audio "gracias"/"thank you" (learned from
      caption data) is removed two ways: `SilenceTrim` trims the near-silent tail before
      transcription, and a conservative Layer 1 `HallucinationFilter` strips the phrase only as an
      isolated final clause (so a real "muchas gracias por tu ayuda" survives). Behind a default-on
      toggle; unit-tested.
- [ ] (Maybe) feed the glossary to the optional Layer 2 LLM so it can correct jargon when cleanup
      is on; and/or capture corrections to grow the L1 dictionary with less friction.

### D. Cleanup (Layer 2) maturity
- [x] Generalize `MLXTextCleaner` to **any MLX instruct model id** (config-driven). The engine
      already reloads any id; the Models tab now also has a free-form "Custom cleanup model" field
      in addition to the curated list.
- [x] **Pre-warm** the cleanup model when the toggle is enabled so the first cleanup isn't ~1 s slow.
      `warmUp()` runs a throwaway generation after load, and the model is now **loaded + warmed only
      while cleanup is enabled** (freed on disable) instead of always resident at startup.
- [ ] (Optional) residual prompt flecos: full-sentence "perdón" restarts (#2), occasional verb
      rewrites (#5) — tune further, or build the deterministic+LLM **hybrid** (instant for the common
      case, LLM only on detected self-corrections). Deferred by choice; current quality is good.

### E. Distribution & "feels like a real app" (to publish on the website)
- [x] **ADR 0002** — **Accepted** (2026-07-01): open source under **MIT**, Developer ID direct
      download (not the MAS), R2 + GitHub hosting, models download-on-first-run, anti-RE
      mitigations retired. See `decisions/0002-distribution-and-packaging.md`. The device/RAM
      support matrix that informs the model tiers lives in [`device-support.md`](device-support.md).
- [x] **Notarization + Developer ID**: the Developer ID Application cert + `notarytool` profile are
      set up; `Scripts/release.sh` builds the stripped, hardened, signed, **notarized + stapled `.dmg`**
      end-to-end (first 0.0.1 build notarized). `Scripts/upload-r2.sh` publishes it. *(These
      maintainer scripts are kept local, not in the public repo — see `.gitignore`.)*
- [ ] **Publish the first release**: the notarized **1.1.4 `.dmg` is live on R2** at
      `https://dl.juanpablocastro.com/releases/1.1.4/ChacharApp-1.1.4.dmg`. First-run fixes found
      by clean-install testing: 1.1.0 added the setup guide; 1.1.1 the missing microphone
      entitlement (a hardened-runtime app without `com.apple.security.device.audio-input` is
      denied the mic silently — no prompt, no row in System Settings); 1.1.2 made the mic-grant
      take effect live (fresh `AVAudioEngine` on grant — the engine that triggers the TCC prompt
      stays silent forever) and moved WhisperKit's tokenizer fetch out of `~/Documents` (which
      fired a Documents-access prompt) into the managed Application Support dir; 1.1.3 refuses to
      run straight from the mounted `.dmg` (permissions granted there bind to the `/Volumes` path
      and orphan into icon-less "ChacharApp.app" TCC rows on eject); 1.1.4 fixed the setup guide
      sticking at "Downloading 100%" (straggler progress callbacks overwrote the `.ready` state,
      leaving "Start Dictating" locked). Published at
      **github.com/castrosolutions/ChacharApp** with the `.dmg` attached as a GitHub release,
      mirroring R2 (ADR 0002 D3). Remaining: validate the first-download path from a fresh macOS
      user account (careful: `/Applications` is shared across accounts, so the test account must
      not find a copy already installed there).
- [x] **First-run onboarding**: a **setup guide window** (`Sources/ChacharApp/Onboarding/`) walks
      through Mic + Accessibility with live checkmarks (TCC is polled — a grant flips its row green
      within a second, no relaunch) and shows the one-time speech-model download with a progress
      bar; "Start Dictating" unlocks when all three are green. It auto-opens on launch whenever
      setup is incomplete (first run, revoked permission, deleted model) and can be reopened from
      the status menu ("Setup Guide…"). The hotkey **arms live** when Accessibility is granted —
      `AppDelegate` polls `AXIsProcessTrusted()` and starts the `CGEventTap` on grant.
- [x] Open-source hygiene, part 1: public `README` + MIT `LICENSE` (done).
- [ ] Open-source hygiene, part 2: contribution notes; versioning; optional auto-update
      (e.g. Sparkle).

### F. Polish & robustness
- [x] **Microphone privacy mode** — setting to open the mic only while the PTT key is held, so
      macOS's "mic in use" indicator shows only while dictating (default) vs always-warm for lowest
      latency. Mic engine start/stop runs off the event-tap thread so it never stalls key handling.
- [x] **Hands-free PTT mode** (optional) — press to start, press again to stop. Default is
      classic hold-to-talk (record only while held).
- [ ] **Recording indicator** (repurpose the disabled HUD or animate the menu-bar icon).
- [x] **Separate dev/prod signing identity** (done): the local build (`make-app.sh`/`install.sh`)
      uses `com.juanpablocastro.chacharapp.dev` + display name "ChacharApp (dev)", so its TCC grants
      no longer collide with the notarized build's clean id (same id + a different cert had made macOS
      treat them as different apps that clobbered each other's Mic/Accessibility grants).
- [ ] Error handling: model download failure, low disk, model load failure, missing permissions.
- [ ] Phase 2 **WER spike** — quantify accuracy on a small personal set to track regressions.

### G. Dictation history  ⭐ (recover what you dictated)
A persistent, **local** log of every dictation so nothing is lost — e.g. an injection that failed,
or a prompt you want to reuse. Stores both texts: the **raw recognition** and the **final inserted
text** (after L1, and after L2 cleanup when the toggle was on; otherwise the final corrected text).

- [x] **Capture** at injection time (in `onRelease`): timestamp, raw recognition, final inserted
      text, whether cleanup was applied, target app, duration. *(Model id not yet stored per record —
      add once model management lands.)*
- [x] **Persist** append-only as JSON Lines in Application Support — crash-safe and easy to recover.
- [x] **History viewer** in the settings UI (History tab): list (newest first), search, copy raw or
      final text, delete entries.
- [x] **Privacy:** 100% local; a "clear history" action, a retention cap, and a recording on/off
      switch, with a note that everything dictated is recorded.

---

## Suggested sequencing (largely executed — E is the active front)

1. **Foundation (A):** settings store + a basic settings window wiring what already exists
   (PTT key, L2 on/off, model ids). Makes the app *feel* configurable immediately. **Done.**
2. **Model management (B):** capabilities table → select active ASR/cleanup model → download/import.
   This is the headline feature for publishing. **Done.**
3. **Quality (C):** vocabulary UI + the "add a word" gap — resolved via the fuzzy Layer 1
   (Layer 0 proved non-viable on turbo). **Done.**
4. **Distribution (E):** ADR 0002 (accepted) → notarization → onboarding → OSS hygiene, to ship on
   the website. **← current focus.**
5. **Polish (F) and cleanup maturity (D)** woven in throughout.

A, B and C deliver the configurable-intermediary value; E makes it publishable. Order within is
flexible — the Layer 0 fix (C) can jump earlier since it's independent and high-impact. Start the
**history capture** (G) early during A so no dictations are lost; its viewer lands with the UI.

---

## Testing

Automated coverage is intentionally **unit-only, over `ChacharCore`**. The integration and
golden/accuracy layers — and why the literal voice-to-app end-to-end is not automated (it crosses
the mic, the ANE, and injection into a third-party app, which no harness controls) — are recorded
in [`testing.md`](testing.md). The deferral is a decision, not an oversight.
