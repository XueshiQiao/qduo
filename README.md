# QDuo

Select text in any macOS app and a small popup appears at the cursor with actions
you defined — copy, search, open a link, or send the selection to a model and get
the answer back in place. Or press a hotkey, drag a box over anything on screen,
and get the text out of it.

Extracted from [XTools](https://github.com/XueshiQiao/XTools), where it lived as
one tool among many.

## What it does

- **Selection popup** — a capsule above the selection, or a ring centred on the
  cursor. Actions can be grouped, and a group opens a second ring.
- **Actions you define** — each one is local (copy, open, search, reveal) or a
  prompt sent to a model, with its own model override if you want one. Results
  stream back as live Markdown.
- **Screenshot text** — hotkey, drag a rectangle, OCR, same popup.
- **Menu bar only** — no Dock icon. The status item is the whole interface when
  the settings window is closed. There is no on/off switch: the popup runs
  whenever the app does, and quitting is how you stop it.
- **One settings file** — `~/.config/qduo/config.json`, with a generated JSON
  Schema beside it. Edit it by hand if you like; it is read at launch, so a hand
  edit takes effect on the next start. API keys are not in it — those stay in the
  Keychain, which is what makes the file safe to commit. Keys the app does not
  recognise are preserved rather than dropped, and a version of the file that
  differs from what the app last read is copied aside before being overwritten.
  See `docs/config-file.html` for the whole design.

## Requirements

- macOS 13 or later
- **Accessibility** permission — how the selection is read
- **Screen Recording** permission — only for screenshot text

Not sandboxed: reading the selection out of another app and watching the mouse
globally are both forbidden inside the sandbox.

## Build and run

```bash
brew install xcodegen
xcodegen generate
scripts/run.sh                 # kill old → build → relaunch (Debug), via `open`
scripts/run.sh --page actions  # …and pre-select a settings page
scripts/run.sh --preview       # …and pop the sample popup, to look at the shape
scripts/run.sh --quiet         # …without opening the settings window
```

Or open the generated `QDuo.xcodeproj` and press Cmd-R.

- The Debug build is a separate app (`QDuo-Debug`, id `…qduo.debug`) so it can be
  installed alongside a release build. It shares the Keychain and the config file
  with Release, and keeps its own log.
- Logs: `~/Library/Logs/QDuo-Debug/QDuo-Debug.log` — `tail -F` it.
- Tests: `xcodebuild test -project QDuo.xcodeproj -scheme QDuo -destination 'platform=macOS'`.
  The test target is deliberately **not** hosted in the app — the app installs
  global input monitors at launch, and a test host would wake all of that on every
  run. Files under test compile straight into the bundle, so **a new file under
  test has to be added to the target's `sources` in `project.yml`**.

## Renaming the app

The name lives in exactly one place: the brand block at the top of `project.yml`.
No Swift file contains it, no directory is named after it, and no localized string
spells it out — everything reads it back from the built bundle through
`Sources/Core/Brand.swift`, and strings take it as `%@`.

To rename: edit those five values, rename the GitHub repo, redraw the icon, and
fix this README.

## The icon

`scripts/make-icon.py` draws it and writes every file that needs it — the seven
sizes in the asset catalogue, the copy the sidebar and About page draw
themselves, and two 1024 masters under `design/icon/`. Nothing else in the
project draws it, so a change means editing the constants at the top of that
script and re-running it.

The two masters are for different jobs. `icon-1024-square.png` is full bleed
with no corners and no shadow: hand it to anything that applies its own mask.
`icon-1024-rounded.png` is the macOS tile — an 824-point body centred in a 1024
canvas, which is Apple's own template, cut with the system's continuous-curvature
corner rather than a rounded rectangle or a superellipse. Measured against a real
system icon's alpha, that outline tracks it to 1.3px on a 1024 canvas; the best
superellipse of any exponent managed 4.0.

## Layout

```
project.yml            ← the name, and only here
design/icon/           the two 1024 masters
Sources/
├─ App/                main · AppDelegate · MenuBarController · UpdateController
├─ Core/               Brand · FileLog · Preferences · Analytics · LocalizationOverride · LLM/
├─ UI/                 AppChrome · SettingsPage · AppState · MainWindowController · Pages/
└─ PopBar/             the popup itself — trigger, selection, window, actions, OCR
Resources/             en + zh-Hans strings
Supporting/            Info.plist · App.entitlements
scripts/               run.sh · bump-version.sh
```

`PopBar` is the internal name of the popup machinery and is unrelated to what the
app is called — renaming the product does not touch it.

## Release

Pushing a `v*` tag runs sign → notarize → DMG → Sparkle-sign → appcast → GitHub
Release. Cut one with `scripts/bump-version.sh`, then push the tag. Steps degrade
gracefully when secrets are absent, so a tag build without them still produces an
unsigned DMG.

Repository secrets for a signed release:

| Secret | State | What it is |
|---|---|---|
| `SPARKLE_EDDSA_KEY` | **set** | This app's own EdDSA private key (keychain account `qduo`). The public half is in `Supporting/Info.plist`. |
| `MAC_CERTS_P12_BASE64` + `MAC_CERTS_P12_PASSWORD` | missing | Developer ID Application certificate, `.p12` base64-encoded. |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APP_SPECIFIC_PASSWORD` | missing | For `notarytool`. Team is `584KQTRF3B`. |
| `MAC_PROVISION_PROFILE_BASE64` | missing | A **Developer ID** provisioning profile for `me.xueshi.qduo`, created in the developer portal. It authorizes the `keychain-access-groups` entitlement; without it a notarized build is SIGKILLed at launch while every static check still passes. A development profile will not do — the profile has to contain the Developer ID certificate that signs the build. |
| `HOMEBREW_TAP_PAT` | missing | Optional: auto-updates the Homebrew cask. |

**While the repository is private, auto-update cannot work**: Sparkle downloads
the release asset anonymously, and a private repo refuses that. Make the repo
public before relying on updates.
