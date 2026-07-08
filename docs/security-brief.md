# ChacharApp — Enterprise Security & Deployment Brief

*For IT and Security teams evaluating ChacharApp for use on managed Macs.*

ChacharApp is a **local, free, open-source** macOS menu-bar dictation app: hold a key, speak,
release, and the transcribed text is pasted into the focused app. **All processing happens
on-device.** No audio and no transcript ever leaves the machine, there is no account, and there
is no analytics or telemetry. This document gives your IT/Security team everything needed to
review, approve and deploy it on a managed fleet.

If you are reading this because an employee asked to install it, the short version is: it is a
**notarized, Developer ID-signed, non-sandboxed menu-bar agent** that needs **Microphone** and
**Accessibility**, and its only outbound network traffic is a one-time speech-model download from
Hugging Face and an update check against the developer's server. The source is public and
auditable.

---

## At a glance (identifiers to allowlist)

| Property | Value |
| --- | --- |
| App name | ChacharApp |
| Bundle identifier | `com.juanpablocastro.chacharapp` |
| Developer / signing identity | `Developer ID Application: Juan Pablo Castro Hurtado` |
| Apple Team ID | `3Q7VW4D8M9` |
| Notarized by Apple | Yes (ticket stapled to the `.app` and `.dmg`) |
| Hardened runtime | Yes |
| App Sandbox | No (required — see below) |
| App type | Menu-bar agent (`LSUIElement`, no Dock icon, no main window) |
| Minimum macOS | 14.0 (Sonoma); developed on macOS 26 |
| Architecture | Apple Silicon (arm64) |
| TCC permissions required | Microphone, Accessibility |
| License / source | MIT — <https://github.com/castrosolutions/ChacharApp> |
| Updates | Sparkle 2 (EdDSA-signed), user-initiated, over HTTPS |

---

## Why the install method does not change the security posture

A common assumption is that the direct `.dmg`, Homebrew, or building from source are three
different levels of "trust". They are not. **All three produce the same kind of binary that must
pass the same OS policy gates:**

- **Direct `.dmg`** and **`brew install --cask chacharapp`** deliver the **exact same notarized
  app from the same URL** (`dl.juanpablocastro.com`). Homebrew copies the same bytes to
  `/Applications`; it does not bypass Gatekeeper, binary allowlisting, or the TCC permission
  requirements. Homebrew itself is also frequently restricted on locked-down fleets.
- **Building from source** produces a locally-signed (ad-hoc or the developer's own certificate)
  build. Under an "App Store only" Gatekeeper policy or binary allowlisting, a self-built binary is
  *more* likely to be blocked than the notarized release, and it still needs the same Microphone +
  Accessibility grants.

**The real gate on a managed Mac is MDM policy, not the download format.** The rest of this
document covers exactly which policies apply and how to approve the app.

---

## Code signing & notarization

- Signed with a **Developer ID Application** certificate (Team ID `3Q7VW4D8M9`) using the
  **hardened runtime** and a secure timestamp.
- **Notarized** by Apple and **stapled**, so Gatekeeper validates it offline. On a Mac with the
  default Gatekeeper setting ("App Store and identified developers") the user sees only the
  standard one-time *"Apple checked it for malicious software"* dialog — no `xattr` or right-click
  workaround is needed.
- Nested code (the Sparkle updater framework and its XPC services) is signed inside-out with the
  same identity so the whole bundle validates.

**Verification commands** your team can run on an installed copy:

```sh
# Signing identity, Team ID and hardened-runtime flags
codesign -dv --verbose=4 /Applications/ChacharApp.app

# Gatekeeper assessment (should report "accepted", source "Notarized Developer ID")
spctl -a -vvv -t exec /Applications/ChacharApp.app

# Notarization ticket is stapled (works offline)
stapler validate /Applications/ChacharApp.app

# Full entitlement listing
codesign -d --entitlements :- /Applications/ChacharApp.app
```

## Sandbox & entitlements

ChacharApp runs **outside the App Sandbox by design** — this is why it is distributed directly and
not on the Mac App Store. A global push-to-talk key (a `CGEventTap`) and cross-application text
insertion (Accessibility + a synthetic ⌘V) are both incompatible with the sandbox.

The entitlements are deliberately minimal (the file is in the public repo:
[`ChacharApp.entitlements`](../ChacharApp.entitlements)):

| Entitlement | Value | Why |
| --- | --- | --- |
| `com.apple.security.app-sandbox` | *(absent)* | Non-sandboxed: needed for the global hotkey and cross-app paste. |
| `com.apple.security.cs.disable-library-validation` | `true` | Allows the hardened runtime to load the bundled ML frameworks (MLX, WhisperKit) and their Metal library. |
| `com.apple.security.device.audio-input` | `true` | Microphone access (a hardened-runtime app is silently denied the mic without it). |
| `com.apple.security.cs.allow-jit` | *(absent)* | Not enabled. |
| `com.apple.security.cs.allow-unsigned-executable-memory` | *(absent)* | Not enabled. |

There are **no file-access, network-server, or Apple-Events entitlements**, and no
executable-memory/JIT exceptions.

## Permissions the app requests (TCC)

On first launch a built-in setup guide walks the user through two permissions:

1. **Microphone** (`kTCCServiceMicrophone`) — to capture speech while the key is held.
2. **Accessibility** (`kTCCServiceAccessibility`) — to read the global push-to-talk key and to
   paste the transcribed text into the focused app.

> **Operational note for locked-down fleets:** on hardened Macs the **Accessibility** grant is
> often the real blocker, not the installation. Accessibility **can be pre-approved for the app
> via an MDM PPPC profile** (see below). **Microphone cannot be pre-approved by MDM** — Apple
> requires the user to grant Camera/Microphone interactively; a PPPC profile can only *deny* the
> mic, never silently allow it. In practice the user will always see and accept the microphone
> prompt themselves; everything else can be handled by IT.

No other privacy-sensitive services are used (no Camera, Contacts, Calendar, Photos, Full Disk
Access, Screen Recording, or Automation/Apple Events).

## Network behaviour & data egress

**Audio and transcripts never leave the device.** Transcription, correction and the optional
LLM cleanup all run locally. The complete list of outbound connections the app can make:

| When | Destination | What | Notes |
| --- | --- | --- | --- |
| First run (once) | `huggingface.co` (WhisperKit model repo) | Downloads the ~626 MB speech model + tokenizer | After this, transcription is 100% offline. Can be pre-seeded (see below). |
| Update check | `dl.juanpablocastro.com` (Cloudflare R2) | Fetches `releases/appcast.xml`, then the `.dmg` if the user updates | Sparkle 2; **user-initiated / user-consented**; can be disabled for managed fleets. |
| Optional (off by default) | `huggingface.co` (`mlx-community/…`) | Downloads a local LLM for the opt-in "Layer 2" cleanup | Only if the user enables cleanup and selects a model. |
| User-initiated links | `tally.so`, `github.com`, `juanpablocastro.com` | Opens Feedback / project links in the **default browser** | The app sends no data itself; these just open a URL. |

There are **no analytics, telemetry, crash-reporting, ad, or account/authentication endpoints**.
The dictation history is stored **only on local disk** (see below) and is never transmitted.

## Local data storage

All app data lives under the user's Library, never in a shared or transmitted location:

```
~/Library/Application Support/ChacharApp/
    Models/           # downloaded speech model(s)
    Tokenizers/       # tokenizer files
    history.jsonl     # local dictation history (on-disk only)
    vocabulary.json   # user glossary + replacement rules
```

Preferences are stored in the standard per-user defaults domain for the bundle id. Uninstalling
and removing this folder (Homebrew's `--zap`, or `brew uninstall --cask chacharapp --zap`) fully
removes all user data and models.

---

## Deploying on a managed fleet

Pick whichever of these matches your environment. They are ordered from most to least "managed".

### 1. Package and deploy via MDM (recommended)

Add the notarized `.dmg`/`.app` to your MDM app catalog (Jamf, Kandji, Intune, Mosyle, etc.) and
push it like any other approved app. Because it is already Developer ID-signed and notarized, no
repackaging or re-signing is required. Pair it with the PPPC profile in step 3.

### 2. Gatekeeper policy

- **Default policy** ("App Store and identified developers"): the app installs and runs with the
  standard one-time confirmation. No action needed.
- **"App Store only" policy** (`AllowIdentifiedDevelopers = false` via the
  `com.apple.systempolicy.control` payload): this blocks **all** Developer ID apps, notarized or
  not. To allow ChacharApp, either relax this policy for managed devices or deploy the app through
  MDM (step 1), which is exempt.

### 3. Binary allowlisting (Santa / equivalent) + PPPC

If you run **Santa** or similar in lockdown mode, allowlist by the Developer ID certificate /
Team ID rather than by hash (so updates keep working):

- **Team ID to allowlist:** `3Q7VW4D8M9`
- **Bundle identifier:** `com.juanpablocastro.chacharapp`

To pre-grant **Accessibility** via an MDM **PPPC (Privacy Preferences Policy Control)** profile,
use:

- **Identifier:** `com.juanpablocastro.chacharapp`  (type: *bundle ID*)
- **Code requirement:**

  ```
  identifier "com.juanpablocastro.chacharapp" and anchor apple generic and \
  certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and \
  certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and \
  certificate leaf[subject.OU] = 3Q7VW4D8M9
  ```

- **Service:** `Accessibility` → *Allow*.

As noted above, **Microphone** cannot be pre-allowed by PPPC; the user grants it interactively at
first use. (You may include `Microphone` in the profile set to *Allow standard user to change*, but
not to silently grant it.)

### 4. Updates (Sparkle) on managed fleets

The shipped app checks `dl.juanpablocastro.com/releases/appcast.xml` for updates and verifies each
update with an **EdDSA signature** before installing; the user is always asked before checking
automatically or installing anything. If you prefer to control updates through MDM instead:

- Block outbound access to the appcast URL, or
- Manage versions entirely through your MDM catalog and ignore the in-app updater.

(For reference, the source build installs under a separate bundle id, `…​.chacharapp.dev`, and ships
**without** any update feed, so it never checks for updates.)

### 5. Pre-seeding the speech model (fully offline environments)

To avoid the first-run Hugging Face download on air-gapped or egress-restricted machines, stage the
model directory once and deploy it to each user's
`~/Library/Application Support/ChacharApp/Models/` (and `Tokenizers/`). The app detects a complete
local model and skips the download entirely.

### 6. Build from source (maximum auditability)

The full source is public and MIT-licensed. A team that wants to compile and sign it with its own
certificate can:

```sh
git clone https://github.com/castrosolutions/ChacharApp.git
cd ChacharApp
./Scripts/install.sh   # requires Xcode + the Metal Toolchain
```

Note this yields a locally-signed build, not the notarized release; under an "App Store only" or
allowlist policy you would allowlist your **own** signing certificate for it.

---

## Why a security team can approve this quickly

- **No data exfiltration.** The usual objection to a dictation tool — *"it sends our audio/text to
  a third party"* — does not apply. ChacharApp processes everything locally and has no telemetry,
  analytics, or account.
- **Auditable.** The entire source, including the entitlements and the correction pipeline, is
  public under the MIT license.
- **Apple-verifiable identity.** Developer ID-signed and notarized; the Team ID and bundle id above
  are stable across releases and are what you allowlist.
- **Minimal surface.** Non-sandboxed only where functionally required, with a deliberately tight
  entitlement set and no JIT/executable-memory exceptions.

## Contact

- Source & issues: <https://github.com/castrosolutions/ChacharApp>
- Author: Juan Pablo Castro — <https://juanpablocastro.com>

*This brief reflects ChacharApp 1.3.x. The identifiers (Team ID, bundle id) and security posture
are stable across releases; version-specific details are in the
[release notes](https://github.com/castrosolutions/ChacharApp/releases).*
