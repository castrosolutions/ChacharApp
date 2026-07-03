# ADR 0002 — Distribution, packaging & licensing

- **Status**: **Accepted** — **open source** (decided 2026-07-01; reverses the short-lived
  "closed for now" draft of the same date)
- **Date**: 2026-06-26 (proposed) · 2026-07-01 (revised to **open source**)

## Context
ChacharApp needs a global hotkey (CGEventTap) and text injection into other apps (synthetic ⌘V),
which require **Accessibility** and a **non-sandboxed** app. It is published as a direct download for
macOS, signed with a **Developer ID Application** certificate (which still needs creating). The
proprietary surface is tiny — the app orchestrates
open-source WhisperKit + MLX and a personal glossary that never ships; the value is integration/UX.

A market scan of the category (local, push-to-talk Whisper dictation for macOS) showed it is crowded
and that **every serious peer is open source** (Handy, VoiceInk, OpenWhispr, Yap — mostly MIT). For a
tool whose entire value proposition is privacy/local-first and that demands **Microphone +
Accessibility**, an **auditable codebase is the credibility**: it is the only way to *prove* audio
never leaves the machine. A closed, free binary would buy nothing (no revenue, no community, no
trust) while undercutting the "100% local" promise. So an earlier same-day decision to ship closed is
**reversed: ChacharApp is open source.**

## Decisions

### D1 — Distribution channel: **Developer ID direct download (NOT the Mac App Store)**
The Mac App Store requires the App Sandbox, which forbids ChacharApp's core mechanisms: a global
`CGEventTap` hotkey, Accessibility control of other apps, and synthetic ⌘V injection into the focused
app. A sandboxed build would be crippled — the same reason Wispr Flow / Raycast aren't on the MAS.
**Distribute a notarized Developer ID build via direct download**, alongside the public source.

### D2 — Signing & notarization: **required for the binary**
Web downloads are quarantined; Gatekeeper needs Developer ID-signed + notarized (`notarytool`) +
stapled. This needs a **Developer ID Application** certificate + `notarytool` credentials (part of a
paid Apple Developer account). Dev/local builds keep the
**Apple Development** cert (Debug profile). Shipping a notarized binary still matters even though the
source is public: most users won't build from source.

Gotcha (cost us release 1.1.1): notarization requires the **hardened runtime**, and a
hardened-runtime app is **silently denied the microphone** — no TCC prompt, no row in System
Settings — unless it carries the `com.apple.security.device.audio-input` entitlement
(`ChacharApp.entitlements`); the Info.plist usage description alone is not enough. Dev builds don't
hit this because `make-app.sh` doesn't harden.

### D3 — Hosting: **Cloudflare R2 + GitHub Releases**
The public repo lives on GitHub, which becomes a first-class release channel (source + notarized
`.app`). Cloudflare R2 (zero egress on the free tier, branded URL) hosts the binary and any hosted
model, with a landing page on Cloudflare Pages. The two channels mirror each other. A **Homebrew
cask** (`chacharapp` in the public tap `castrosolutions/homebrew-tap`) fronts the same R2 `.dmg`
for `brew install --cask` users; graduating it into the official `homebrew/cask` repo is deferred
until the project meets Homebrew's notability bar.

### D4 — Model packaging: **download-on-first-run**
The Whisper model is **not** bundled in the `.app`. The dev symlink in `make-app.sh` is install-only
and would **dangle** on any other machine. Instead WhisperKit downloads `large-v3-turbo` into
ChacharApp's managed dir on first launch, with progress surfaced during onboarding. Keeps the
download small; never commit the model to git.

### D5 — Open vs closed: **OPEN SOURCE (reverses the earlier "closed for now")**
Publish the source publicly. The whole value proposition is privacy/local-first, and the only way to
*prove* audio never leaves the machine is an auditable codebase; the peer set is all open source;
there is no monetization plan that a closed binary would protect. Open-sourcing turns the app's
"not a novel concept" reality into a strength: an auditable, Spanish-tuned, ANE build people can
actually run and inspect. If monetization is ever pursued, an "open core" split remains available.

### D6 — Reverse-engineering mitigations: **retired (they only made sense while closed)**
The symbol-strip-for-secrecy, anti-debugger hardened runtime, and Layer 2 prompt XOR obfuscation
(`PromptCipher`) existed solely to protect a closed binary. With D5 open, they are moot — the source
(including the cleanup prompt) is public by definition. **Retire** the prompt obfuscation and the
anti-RE posture. **Keep** two Release steps for non-security reasons: a full symbol **strip** (smaller
binary) and **dSYM archiving** (so field crash reports still symbolicate). "Never ship secrets"
remains a hard rule (Layer 2 is local, no API key).

### D7 — Licensing: **MIT**
Ship an **MIT** `LICENSE` at the repo root — the ecosystem default (Handy, Yap, open-wispr,
OpenWhispr are MIT) and compatible with the permissive dependencies (WhisperKit MIT, Whisper weights
MIT). Re-check the Hugging Face model repo's LICENSE before redistributing/hosting the model weights
themselves.

### D8 — Model tiers & minimum hardware: **Apple Silicon (M1+), turbo default**
The app requires Apple Silicon (CoreML/ANE); Intel is out. Ship `large-v3-turbo` as the default on
capable machines and offer smaller WhisperKit models (base/small/distil) for weaker ones; declare the
minimum requirement in the README. The device/RAM matrix that informs the tiers lives in
[`../docs/device-support.md`](../docs/device-support.md).

### D9 — In-app updates: **Sparkle 2 over the same R2 channel**
Direct-download users get updates in-app via **Sparkle 2**, the de-facto standard for non-MAS macOS
apps. The appcast lives at the stable `releases/appcast.xml` key on R2 next to the versioned dmgs,
and each release's enclosure is **EdDSA-signed** — the private key exists only in the maintainer's
Keychain; the public key ships in the app's Info.plist (`SUPublicEDKey`). User control is preserved:
Sparkle asks before enabling scheduled checks and asks again before installing anything — no silent
updates. Only distribution builds carry the feed; dev builds omit the `SUFeedURL`/`SUPublicEDKey`
keys entirely, so they never check or offer updates (contributors update via git, and the release
bundle wouldn't match the dev bundle id anyway). From 1.2.0 on, the Homebrew cask declares
`auto_updates true`, so plain `brew upgrade` defers to Sparkle instead of fighting it.

## Consequences / next steps
- Add the MIT `LICENSE` (done) and a public `README` (done).
- Simplify `release.sh` (done): kept the symbol **strip** + **dSYM** archiving; dropped the
  reflection-name/obfuscation/anti-debugger steps that only made sense closed. `PromptCipher` +
  `gen-prompt-cipher.swift` removed.
- Keep `make-app.sh` / `install.sh` as the local Debug (debuggable) path (done). The local build
  uses a distinct `com.juanpablocastro.chacharapp.dev` bundle id (display name "ChacharApp (dev)")
  so its TCC grants never collide with the notarized build's clean id, and installs as
  `/Applications/ChacharApp (dev).app` so both builds coexist.
- **Release/publish tooling kept maintainer-local:** `Scripts/release.sh`, `Scripts/upload-r2.sh`
  and `docs/releasing.md` are gitignored (not in the public repo) — they need the maintainer's
  Developer ID cert, `notarytool` profile and Cloudflare/R2 auth, none of which ship. Contributors
  build from source with `install.sh`; only the maintainer notarizes + publishes. Tidiness, not
  security: the signing keys already prevent impersonation, and MIT permits redistribution regardless.
- Implement **download-on-first-run** (D4) (done): the app resolves an existing copy or downloads
  the default model on first launch; the `make-app.sh` symlink remains a dev-only convenience.
  Progress is surfaced in the first-run **setup guide** window (permissions checklist + download
  progress bar — `Sources/ChacharApp/Onboarding/`), as D4 required.
- **Developer ID cert + `notarytool` profile (done):** set up; the first 0.0.1 build is notarized +
  stapled end-to-end via `release.sh`.
- **Pending:** wire the R2 upload + a GitHub Release; landing page on Cloudflare Pages.
- Before the first public push, **squash history** to a single clean initial commit so earlier
  closed-source drafts and internal notes aren't reachable from `main`. (Pending — the final step
  before publishing.)

## References
- ADR 0001 (ASR engine) — `decisions/0001-asr-engine.md`.
- `docs/device-support.md` — device/RAM matrix feeding D8.
