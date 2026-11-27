# Developing QDuo

How to build, test, release and change QDuo. For what the app is and how to
install it, see the [README](README.en.md) ([中文](README.md)).

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

## AI agent setup (the command line and the skill)

An AI coding agent on the user's Mac (Claude Code, Codex, Cursor…) can change
the config for them. Three parts, all in `Sources/Core/AgentSetup/` plus the
`skill/` folder:

- **The command line.** `<executable> cli <command>` is handled in `main.swift`
  before `NSApplication` exists (`AgentCLI`): `info`, `schema`, `validate`,
  `apply`, `restart`, `backups`, `rollback`, `providers`, `languages`,
  `install-skill`, `prompt`. Running inside the app's own executable gives it
  the app's Keychain access and keeps it at the app's version.
- **The checks.** `ConfigValidator` = the JSON Schema itself (`SchemaCheck`
  walks `ConfigSchema.json`, so a key added to the schema is checked from that
  day) + what a schema cannot say: unique ids and urlNames, groups one level
  deep, the fields each kind needs, hotkeys the app can parse, readers that
  exist, models without a saved key. Errors block `apply`, warnings block
  `apply --strict`, notes (script actions) never block.
- **Replacing the file under a running app.** The app reads the config once, so
  `apply` restarts it, over `DistributedNotificationCenter` (`AgentIPC`,
  `AgentIPCServer`): prepare (the app writes any pending change, then stops
  writing) → the CLI backs up the old file to
  `~/Library/Application Support/<baseID>/config-backups/` and writes the new
  one → commit (the app relaunches, reopening the settings page that was open).
  `apply` refuses when the app saved a different setting during prepare, and
  when a copy of the app is running that does not answer (a version from
  before this existed would write its old settings back).
- **Inside an agent's sandbox** (Codex runs every command in one by default)
  the system misleads the command line instead of failing: drawing an SF
  Symbol kills the process, Launch Services says no app is installed, the
  Keychain errors, `NSRunningApplication` sees nothing. `AgentSandbox` detects
  the sandbox (`sandbox_check`); there `info` reports the running app as
  unknown, `validate` skips the app and key checks, and `apply`, `restart`,
  `rollback`, `install-skill` refuse with a message saying to run them outside
  it. Symbol names come from the CoreGlyphs list (`SymbolCatalog`), never from
  `NSImage`, so the command line never touches the window server. Check with
  `codex sandbox -- <executable> cli info`.
- **The AI Setup page** ("AI 辅助配置") copies one prompt that carries the path
  to the bundled skill, so nothing has to be installed first. Its layout is
  HyperCapslock's AI Setup page; keep the two alike.
- **The skill** (`skill/SKILL.md`, `skill/references/actions.md`) is bundled as
  `Contents/Resources/skill/` and optionally installed by the AI Setup page or
  `cli install-skill` to `~/.agents/skills/<name>`, linked into each agent
  found on the Mac. The folder name comes from the `name:` in SKILL.md. When a
  command, a kind or a setting is added, update the skill too —
  `SkillInstallerTests.testTheRepositorySkillIsNamedAndComplete` checks that
  every command is documented.

Tests: `Tests/AgentSetupTests.swift`; the CLI runs there against a fake running
app (`FakeApp`).

## Releasing

`scripts/bump-version.sh` bumps the version (CalVer `YY.MM.<build>`), commits and
tags; pushing the tag runs `.github/workflows/build.yml`: tests → universal build →
sign (with the embedded Developer ID provisioning profile) → notarize → staple →
Gatekeeper check → DMG → Sparkle EdDSA signature → `appcast.xml` + `latest.json` →
GitHub Release → Homebrew cask update. Pull requests and manual runs build and
test without publishing.

The whole routine — writing the bilingual `RELEASE_NOTES.html` block, the checks,
and verifying the downloaded DMG afterwards — is `.claude/skills/release/SKILL.md`.

Before handing a feature over for on-device testing, read
`docs/lessons-from-issue-22.md`: code that writes and code that reads the same
format share one module and get a round-trip test; quit/relaunch/sheet behaviour
is checked with a script (`scripts/check-relaunch.sh` after touching
`AppRelaunch.swift`); only what cannot be automated goes on the manual list.

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
docs/KNOWN_ISSUES.md   problems we know about and left open, with the options
Sources/
├─ App/                main · AppDelegate · MenuBarController · UpdateController
├─ Core/               Brand · FileLog · Preferences · Analytics · LocalizationOverride · LLM/ · Speech/ (TTS provider adapters)
├─ UI/                 AppChrome · SettingsPage · AppState · MainWindowController · Pages/
├─ Speech/             read-aloud: readers, playback, streaming player, audio cache
└─ PopBar/             the popup itself — trigger, selection, window, actions, OCR
Resources/             en + zh-Hans strings
Supporting/            Info.plist · App.entitlements
scripts/               run.sh · bump-version.sh
```

The **More Apps** page (the author's other apps, with a Get button that
downloads, verifies, installs and opens one) is not QDuo code: catalog,
installer, views and analytics event names all come from the shared
`MoreAppsKit` Swift package, which the sibling apps embed too. QDuo adds only
the `moreApps` case in `SettingsPage`, the detail case in `MainView`, the entry
row on the About page, `AppState.moreApps` / `showMoreApps(from:)`, the menu
item's target (`MainWindowController.show(moreAppsFrom:)`) and
`Analytics.trackMoreApps`. See the package's README for the catalog format.

Talking to model services is not QDuo code either: the shared `AIModelKit`
package (github.com/XueshiQiao/AIModelKit) holds the three wire standards
(OpenAI-compatible, Anthropic, Gemini), the address handling, the model lists,
the request bodies and the provider table with each provider's thinking knob.
QDuo keeps the settings (`LLMSettingsStore`), the keys (`LLMKeyStore`), the
in-memory model lists (`ModelListStore`) and the picker (`UI/ModelPicker.swift`).
A new provider is a row in the package's `Provider.all`, not a change here.

`PopBar` is the internal name of the popup machinery and is unrelated to what the
app is called — renaming the product does not touch it.

## Renaming the app

The name lives in exactly one place: the brand block at the top of `project.yml`.
No Swift file contains it, no directory is named after it, and no localized string
spells it out — everything reads it back from the built bundle through
`Sources/Core/Brand.swift`, and strings take it as `%@`.

To rename: edit those five values, rename the GitHub repo, redraw the icon, and
fix README.md, README.en.md, this file and the agent skill (`skill/SKILL.md`,
`skill/references/actions.md`: its `name:`, the paths and the name in the text).

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
