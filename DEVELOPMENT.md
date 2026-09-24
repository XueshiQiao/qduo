# Developing QDuo

How to build, test, release and change QDuo. For what the app is and how to
install it, see the [README](README.md).

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

## The config file

Everything in Settings lives in one file, `~/.config/qduo/config.json`, with a
generated JSON Schema beside it. It is read at launch; keys the app does not
recognise are preserved, and a version of the file that differs from what the app
last read is copied aside before being overwritten. API keys are not in it —
they live in the Keychain. The whole design is in `docs/config-file.html`.

## Releasing

`scripts/bump-version.sh` bumps the version (CalVer `YY.MM.<build>`), commits and
tags; pushing the tag runs `.github/workflows/build.yml`: tests → universal build →
sign (with the embedded Developer ID provisioning profile) → notarize → staple →
Gatekeeper check → DMG → Sparkle EdDSA signature → `appcast.xml` + `latest.json` →
GitHub Release → Homebrew cask update. Pull requests and manual runs build and
test without publishing.

The whole routine — writing the bilingual `RELEASE_NOTES.html` block, the checks,
and verifying the downloaded DMG afterwards — is `.claude/skills/release/SKILL.md`.

All repository secrets are set: `MAC_CERTS_P12_BASE64`, `MAC_CERTS_P12_PASSWORD`,
`APPLE_ID`, `APPLE_TEAM_ID`, `APP_SPECIFIC_PASSWORD`, `MAC_PROVISION_PROFILE_BASE64`
(the QDuo Developer ID profile — it authorizes the `keychain-access-groups`
entitlement; without it a notarized build is killed at launch while every static
check passes), `SPARKLE_EDDSA_KEY` (keychain account `qduo`; public half in
`Supporting/Info.plist`) and `HOMEBREW_TAP_PAT`.

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

## Renaming the app

The name lives in exactly one place: the brand block at the top of `project.yml`.
No Swift file contains it, no directory is named after it, and no localized string
spells it out — everything reads it back from the built bundle through
`Sources/Core/Brand.swift`, and strings take it as `%@`.

To rename: edit those five values, rename the GitHub repo, redraw the icon, and
fix README.md, README_CN.md and this file.

## The icon

What ships is painted, and lives at `design/icon/painted-master-1024.png` — one
square image, edge to edge, no corners. To rebuild every file the app needs
from it:

```bash
scripts/cut-icon.py design/icon/painted-master-1024.png
```

That writes the seven catalogue sizes, the copy the sidebar and About page draw
themselves, and `design/icon/icon-1024-rounded.png` for looking at. The master
is never scaled to fit: the tile is an 824-point body inside a 1024 canvas, so
clipping throws away 100 points on each side and the artwork keeps its size.
That is what full bleed is for.

The tile's outline is the system's own continuous-curvature corner, taken from
`RoundedRectangle(cornerRadius: 185.4, style: .continuous)` over the body
Apple's template centres in a 1024 canvas — not a rounded rectangle and not a
superellipse, neither of which can draw that curve. Against a real system icon's
alpha it tracks to 1.3px; the best superellipse of any exponent managed 4.0.

`scripts/make-icon.py` draws the same design in vector and is kept as the
fallback and as the written record of it: every proportion, both colours and the
reason behind each sit in the constants at the top of that file. Run it and it
overwrites the catalogue with the vector version; run `cut-icon.py` again to go
back. It also writes `design/icon/icon-1024-square.png`, the vector master, in
the same full-bleed form.

The menu bar icon is the same ring and arc with no tile, as a template SVG the
system tints for light and dark bars. `scripts/make-menubar-icon.py` writes it to
`Assets.xcassets/MenuBarIcon.imageset/`, reading every proportion from the
constants in `make-icon.py` — change the mark there, then re-run both.

One known limit of the painted master, accepted deliberately: at 16px the arc
beside the ring blurs into it. The vector version keeps the two apart at that
size. 16px only shows up in Finder's list view.
