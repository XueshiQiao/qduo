# QDuo actions — recipes

`actions` is the top-level array of the config, in the order the popup shows
them. Each entry is an object; `id`, `title` and `kind` are required. The JSON
Schema (`cli schema`, or `config.schema.json` beside the config) describes
every field; this file shows what correct actions look like.

Fields every action may have:

| Field | Meaning |
| --- | --- |
| `id` | Unique, stable. A new action gets a fresh UUID (`uuidgen`). Never change an existing one. |
| `title` | The name shown in the popup. Keep it short: it has to fit a ring slot. |
| `kind` | What it does (below). |
| `iconSymbol` | An SF Symbol name, e.g. `"character.bubble"`. `cli validate` warns when this Mac cannot draw it. |
| `iconImage` | Optional own PNG (128×128) in `~/.config/qduo/icons/`, drawn instead of the symbol. |
| `children` | Makes it a group (see below). |
| `urlName` | Lets other apps run it via `qduo://run/<urlName>?text=…`. Only when the user asks. |
| `schemaVersion` | Written by the app. Leave it alone; omit it on new actions. |

The app writes a few fields on its own (`schemaVersion`, sometimes an empty
`prompt` left behind on a non-AI action). Leave them as they are.

## ai — send the text to a model

```json
{
  "id": "5D1C3A9E-6B1F-4E8F-9C1A-2B7D3E4F5A6B",
  "title": "Polish",
  "iconSymbol": "wand.and.stars",
  "kind": "ai",
  "prompt": "You are a writing editor. Rewrite the user's text to be clearer, more fluent and natural, preserving its original language and meaning. Output ONLY the polished text, with no quotes, labels, or explanation.",
  "output": "compare"
}
```

- `prompt` is the system instruction; the selected text is the user message.
  End prompts that produce a replacement with "Output ONLY …" so the result
  can replace the selection cleanly.
- `output`: `panel` (default), `compare` (show the changes, then Replace — the
  right choice for rewrites), `replace`, `append`, `copy`.
- Different model for this action only — all three keys are required, or the
  override is ignored:

```json
"modelOverride": { "provider": "anthropic", "model": "claude-sonnet-5-5", "reasoningEffort": "" }
```

`provider` is one of the ids from `cli providers`; `reasoningEffort` one of
the thinking values it lists for that provider (`""` = the model's default,
`"none"` = off where offered). Check that the provider has a key saved; if not,
tell the user to add it in Settings › AI Models. Ask the user or check the
provider's documentation for model ids — do not invent them.

## systemTranslate — translate without an API key

```json
{ "id": "…", "title": "To Japanese", "iconSymbol": "translate", "kind": "systemTranslate",
  "engine": "bilibili", "targetLanguage": "ja", "secondLanguage": "en" }
```

- No `engine` = macOS's own on-device translator (macOS 15 and later only).
  `"engine": "bilibili"` = Bilibili's free online translator: any macOS, the
  text is sent to Bilibili. `cli languages` lists its languages.
- `targetLanguage` is required: `"zh"` (Simplified Chinese), `"zh-TW"`
  (Traditional), `"en"`, `"ja"`, `"ko"`, `"fr"`, `"de"`…
- `secondLanguage`: what to do when the text is already in the target
  language. Absent = the system's second preferred language; `"none"` = do not
  translate; any language id = translate into that.
- `output` works as for `ai`.

## openURL — search or open something with the text

```json
{ "id": "…", "title": "GitHub", "iconSymbol": "chevron.left.forwardslash.chevron.right",
  "kind": "openURL", "url": "https://github.com/search?q={text}" }
```

- `{text}` is replaced by the selection, encoded as one query value.
- `"openIn": "preview"` opens web pages in QDuo's floating mini-browser
  instead of the default browser.
- Other schemes work too: `"dict://{text}"` (Dictionary),
  `"obsidian://new?content={text}"`, `"maps://?q={text}"`.
- `"url": "{text}"` alone opens the selection itself when it is a web address.

Common searches: Google `https://www.google.com/search?q={text}`, Bing
`https://www.bing.com/search?q={text}`, DuckDuckGo `https://duckduckgo.com/?q={text}`,
Wikipedia `https://en.wikipedia.org/w/index.php?search={text}`, Baidu
`https://www.baidu.com/s?wd={text}`, Bilibili `https://search.bilibili.com/all?keyword={text}`,
YouTube `https://www.youtube.com/results?search_query={text}`, ChatGPT
`https://chatgpt.com/?q={text}`, Claude `https://claude.ai/new?q={text}`.

## transform — a local text operation

```json
{ "id": "…", "title": "UPPERCASE", "iconSymbol": "textformat.size.larger",
  "kind": "transform", "op": "uppercase", "output": "replace" }
```

`op`: `uppercase`, `lowercase`, `titleCase`, `sentenceCase`, `camelCase`,
`snakeCase`, `kebabCase`, `sortLines`, `uniqueLines`, `reverseLines`,
`joinLines`, `trim`, `toSimplified`, `toTraditional`, `pinyin`, `spaceCJK`
(spaces between Chinese/Japanese and Latin text), `jsonPretty`, `jsonMinify`,
`urlEncode`, `urlDecode`, `cleanURL` (removes tracking parameters), `count`
(always shown in the panel). The settings templates use `"output": "replace"`
for every op except `count`.

## speak — read aloud

```json
{ "id": "…", "title": "Speak", "iconSymbol": "speaker.wave.2.fill", "kind": "speak" }
```

Without `reader`, `speech.defaultReader` is used. `"reader": "system"` is the
macOS voice; any other value must be the `id` of an entry in `speech.readers`.
Cloud readers need API keys — set up by the user in Settings › Speech.

## shortcut — run a macOS Shortcut

```json
{ "id": "…", "title": "Make Note", "iconSymbol": "command", "kind": "shortcut",
  "shortcut": "Make Note", "output": "panel" }
```

`shortcut` is the exact name; `shortcuts list` prints them. The selection is
the Shortcut's input, its output is the result.

## script — run a shell command

```json
{ "id": "…", "title": "Word count", "iconSymbol": "terminal", "kind": "script",
  "script": "wc -w | tr -d ' '", "output": "panel" }
```

Run by the user's login shell; the selection is on standard input and in
`$QDUO_TEXT`; what it prints is the result; 10-second limit. Only add a script
the user asked for, show it to them, and mention that QDuo asks before it runs
for the first time.

## keystroke — press keys in the app the text was selected in

```json
{ "id": "…", "title": "Delete", "iconSymbol": "keyboard", "kind": "keystroke", "keys": "delete" }
```

`keys` is ONE combination: `"cmd+b"`, `"shift+cmd+k"`, `"delete"`. No double taps here.

## The rest

```json
{ "id": "…", "title": "Copy", "iconSymbol": "doc.on.doc", "kind": "copy" }
{ "id": "…", "title": "Web Preview", "iconSymbol": "safari", "kind": "webPreview" }
{ "id": "…", "title": "Quick Look", "iconSymbol": "eye", "kind": "quickLook" }
{ "id": "…", "title": "Show in Finder", "iconSymbol": "folder", "kind": "revealInFinder" }
{ "id": "…", "title": "Pause", "iconSymbol": "pause.circle", "kind": "pause" }
{ "id": "…", "title": "Settings", "iconSymbol": "gearshape", "kind": "settings" }
{ "id": "…", "title": "Inspect", "iconSymbol": "scope", "kind": "inspect" }
```

## Groups

A group folds several actions into one slot; pointing at it opens a second
ring (or a dropdown in the capsule style).

```json
{
  "id": "…",
  "title": "Writing",
  "iconSymbol": "pencil.and.outline",
  "kind": "group",
  "children": [
    { "id": "…", "title": "Formal", "iconSymbol": "checkmark.seal", "kind": "ai",
      "prompt": "Rewrite the user's text in a formal, professional tone. Keep its language and meaning. Output ONLY the rewritten text.",
      "output": "compare" },
    { "id": "…", "title": "Casual", "iconSymbol": "text.bubble", "kind": "ai",
      "prompt": "Rewrite the user's text in a friendly, casual tone. Keep its language and meaning. Output ONLY the rewritten text.",
      "output": "compare" }
  ]
}
```

- `"kind": "group"` runs nothing when clicked. An action of any other kind with
  `children` is a group that also runs when clicked.
- One level only: children cannot have children.
- To move an existing action into a group, move the whole object (same `id`)
  from `actions` into the group's `children`.
- An empty group that should stay a group: `"kind": "group"`, or `"group": true`
  on another kind.
