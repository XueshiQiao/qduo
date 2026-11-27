---
name: qduo
description: Configure, inspect, validate and apply settings of QDuo (QDuo-Debug for development builds), the macOS app that pops up a ring or bar of actions when text is selected — AI actions with prompts, translation, web search, read-aloud, text transforms, Shortcuts, shell scripts, keystrokes, groups, hotkeys, excluded apps, default model and per-action models. Use when the user mentions QDuo or Q多, its popup/ring/capsule actions, ~/.config/qduo/config.json, or asks what QDuo can do.
---

# QDuo Agent Skill

QDuo is a menu-bar app for macOS. Select text anywhere and a popup appears (a
ring around the pointer, or a bar above the selection) with the user's
**actions**: send the text to a model with a prompt, translate it, search for
it, read it aloud, change its case, run a Shortcut or a shell command on it,
and so on. Actions can be folded into **groups** (a second ring).

Every setting lives in one JSON file, **`~/.config/qduo/config.json`**, with a
JSON Schema beside it (`config.schema.json`) that documents every key. The app
reads the file **once, at launch**. The app's executable has a built-in command
line that checks a config, backs up the old one, puts the new one in place and
restarts the running app so it takes effect.

Read [`references/actions.md`](references/actions.md) before adding or changing
actions: one example per kind, groups, outputs, per-action models.

## The command line

The executable is inside the app bundle. Find it, in this order:

1. A path given in the user's prompt.
2. A running copy: `pgrep -fl "QDuo(-Debug)?.app/Contents/MacOS/"`.
3. `/Applications/QDuo.app/Contents/MacOS/QDuo` (Release), or a Debug build at
   `…/Build/Products/Debug/QDuo-Debug.app/Contents/MacOS/QDuo-Debug`.

Release and Debug builds read **the same** config file. Use either one.

```bash
BIN="/Applications/QDuo.app/Contents/MacOS/QDuo"
"$BIN" cli info
```

| Command | What it does |
| --- | --- |
| `cli info` | Version, config path (and its real path if it is a symlink), schema path, number of actions, default model and whether its API key is saved, a check of the current config, backups, skill, running copies. |
| `cli schema` | Prints the JSON Schema: every key, type, allowed value, range and what it means. |
| `cli validate [<file>] [--strict]` | Checks a file (default: the current config). Errors = the app would not do what the file says. Warnings = probably a mistake. Notes = worth telling the user. Exit 1 when there are errors (or warnings with `--strict`). |
| `cli apply <file> [--strict]` | Checks `<file>`; if it passes, backs up the current config, writes `<file>` in its place, and restarts every running copy of the app so the change takes effect. Refuses to run on the config file itself. |
| `cli restart [--force]` | After editing the config in place: checks it and restarts the running app. Prefer `apply`. |
| `cli backups` | The versions `apply` and `rollback` kept, newest first. |
| `cli rollback [<backup>] [--force]` | Puts a backup back (default: the newest = undo the last apply), keeping the current version as a new backup, then restarts. |
| `cli providers` | Model providers: ids, display names, default model and address, accepted thinking values, whether an API key is saved. |
| `cli languages` | Target languages of the free Bilibili translation engine. |
| `cli install-skill [--agent <name>]` | Installs this skill to `~/.agents/skills/qduo` and links it for local agents. |
| `cli prompt [--lang zh\|en]` | Prints the set-up prompt the app's AI Setup page copies. |

Add `--json` to any command for machine-readable output. Exit status: 0 done,
1 refused or failed (the message says why), 2 the command line was wrong.

### Sandboxes

If your shell commands run in a sandbox (Codex does by default; Cursor and
Claude Code can), reading works there: this file, the config, the schema, and
`info`, `validate`, `schema`, `backups`, `providers`, `languages`, `prompt`.
Inside a sandbox `info` cannot see the running app or the Keychain and says so.

`apply`, `rollback`, `restart` and `install-skill` write files outside your
workspace and signal the running app, which a sandbox forbids. Inside one they
refuse with a message and change nothing. Run them outside the sandbox: in
Codex request escalated permissions for that one command; elsewhere ask the
user to approve running it unsandboxed. Do not try to get around it by
editing `config.json` directly.

## Workflow

Always work in these steps.

**1. Look first.**

```bash
"$BIN" cli info
cat ~/.config/qduo/config.json            # the path cli info printed
"$BIN" cli schema                          # when unsure about any key or value
```

When the request involves models, run `cli providers`. When it involves apps,
look up their bundle ids (never guess them):

```bash
osascript -e 'id of app "Microsoft Excel"'
mdls -name kMDItemCFBundleIdentifier -r "/Applications/Ghostty.app"
```

**2. Write the whole edited config to a temporary file.** Start from the
current file and change only what the user asked for. Keep everything else
exactly as it is: every other action, its `id`, its position, and keys you do
not recognise.

```bash
cp ~/.config/qduo/config.json /tmp/qduo-config.json
# edit /tmp/qduo-config.json (with jq, python, or by writing the full JSON)
```

**3. Check, then apply.**

```bash
"$BIN" cli validate /tmp/qduo-config.json
"$BIN" cli apply /tmp/qduo-config.json
```

If `validate` reports errors, fix the temporary file and run it again — the
real config has not been touched. If `apply` says the app had just saved a
change made in its settings window, read the config again and redo the edit
on the new version.

**4. Report.** Tell the user what changed (action names, hotkeys, settings),
where the previous version was kept (`apply` prints it), how to undo
(`"$BIN" cli rollback`), and every **note** about script actions. If the app was
not running, say that the change takes effect when it starts. Delete the
temporary file.

## Rules

1. **Never handle API keys.** They are in the macOS Keychain, never in the
   config. Do not ask the user for a key, do not read or write the Keychain,
   and do not put a key in the config. When a provider has no key saved
   (`cli info`, `cli providers`, or a validate warning), tell the user to add it
   in QDuo's Settings › AI Models.
2. **Keep what you were not asked to change.** Never drop actions, reorder the
   ring, rename things or remove unknown keys unless asked. Never change an
   existing action's `id` — other things refer to it. Leave `version` and
   `schemaVersion` alone.
3. **A new action needs a new id**: a fresh UUID from `uuidgen`. Every id in
   the file, children included, must be unique.
4. **Groups are one level deep.** An action inside a group cannot have children.
5. **Script actions run shell commands** on whatever text the user selects.
   Add one only when the user asked for exactly that command, show it to them,
   and mention that QDuo asks before a script runs the first time. Never add
   `urlName` (runs an action from a URL any app or web page can open) unless the
   user asked for it.
6. **Never guess** a bundle id, a Shortcut name (`shortcuts list`), an SF Symbol
   (validate warns when this Mac cannot draw one), a model id (`cli providers`,
   or the provider's documentation), or a translation language (`cli languages`).
7. **Do not edit the config file in place while the app runs** — the app keeps
   the old settings in memory and would write them back. Use `apply`.

## What QDuo can do

When the user asks what is possible, answer from this list.

**Action kinds** (`kind`), details and examples in `references/actions.md`:

| kind | What it does with the selected text |
| --- | --- |
| `ai` | Sends it to a model with `prompt` as the instruction. Default model, or `modelOverride` for this action. |
| `systemTranslate` | Translates into `targetLanguage` with no API key: macOS's own translator (macOS 15+), or `"engine": "bilibili"` (free, online, any macOS). `secondLanguage` for text already in the target language. |
| `openURL` | Opens `url` with `{text}` replaced, e.g. a search; `openIn: "preview"` shows it in a floating mini-browser. |
| `webPreview` | Opens the link in the selection (or searches the text) in the mini-browser. |
| `speak` | Reads it aloud with the system voice or a cloud voice (`reader`, from `speech.readers`). |
| `transform` | A local text operation (`op`): case changes, sort/unique/join lines, trim, simplified ↔ traditional Chinese, pinyin, spacing between CJK and Latin text, JSON pretty/minify, URL encode/decode/clean, count. |
| `shortcut` | Runs a macOS Shortcut by name with the text as input. |
| `script` | Runs a shell command; the text is on stdin and in `$QDUO_TEXT`, stdout is the result. 10 s limit. |
| `keystroke` | Presses one key combination (`keys`) in the app the text was selected in. |
| `copy` | Copies it. |
| `quickLook`, `revealInFinder` | Act on a file path in the selection. |
| `pause`, `settings`, `inspect` | Pause the popup; open QDuo's settings; show the selection's accessibility element. |
| `group` | Holds `children` (a second ring / dropdown). Any action with children is a group that also runs when clicked. |

**Where results go** (`output`, for ai, transform, shortcut, script,
systemTranslate): `panel` (default; shows the result with a Replace button),
`compare` (marks the changes against the selection first — good for rewrites),
`replace`, `append`, `copy`.

**Settings** (sections of the file; `cli schema` documents every key):

- `general` — interface `language` (`en`, `zh-Hans`, null = system), anonymous `analytics`.
- `popup` — `style` (`capsule` bar, `liquidGlass` ring, `donut` 3D ring), `enabled` (false = paused), the popup hotkey (`hotKeyEnabled`, `hotKey`, e.g. `"opt+x"` or `"opt+opt"` for a double tap), `excludedApps` (bundle ids where selecting text never opens the popup), `simulateCopy`, `copyFirstApps`, `terminalApps`, `ignoreAddressBars`, result font size, reading highlight, compare view.
- `wheel` / `donut` / `capsule` — sizes and look of each style.
- `ocr` — screenshot text recognition: `enabled`, `hotKey` (default `shift+cmd+s`), `autoCopy`.
- `models` — the default model: `provider`, `model`, `apiURL`, `thinking`; `custom` for any other OpenAI-, Anthropic- or Gemini-compatible service.
- `speech` — `defaultReader` and the cloud `readers` (their keys are in the Keychain too).
- `history` — record runs (`enabled`), `retentionDays`, `recordCopy`, `excludedApps`.
- `webPreview` — `fallbackToSearch` and `searchEngine` for the webPreview kind.

**Hotkey syntax** (`popup.hotKey`, `ocr.hotKey`, an action's `keys`): written
the way it is spoken, joined with `+`: modifiers `ctrl`, `opt`, `shift`, `cmd`,
then one key (`a`–`z`, `0`–`9`, `f1`–`f20`, `space`, `return`, `tab`, `escape`,
`delete`, `left`, …; the schema lists them all). A modifier written twice
(`"cmd+cmd"`) means a double tap — only for `popup.hotKey` and `ocr.hotKey`.
The two hotkeys must differ.

**Other ways in**: an action with a `urlName` can be run by other apps through
`qduo://run/<urlName>?text=<percent-encoded text>` (only when the user asks
for it — see the rules).

**Not possible**: more than two rings (groups inside groups), and actions
that run on a schedule. Every action works on text: a selection, text read off
the screen with the OCR hotkey, or the `text` of a `qduo://run/…` URL.
