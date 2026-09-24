import Foundation

/// The JSON Schema written next to the config file.
///
/// JSON has no comments, and that is the one real cost of choosing it for a file
/// people edit. A schema buys back more than comments would: an editor offers
/// completion for every key, lists the allowed values of an enum, shows the
/// documentation on hover, and marks a mistake as you type it. And unlike
/// comments, none of it is lost when the app rewrites the file.
///
/// It is regenerated on every launch, so it can never drift behind the app.
enum ConfigSchema {

    static let json = """
    {
      "$schema": "http://json-schema.org/draft-07/schema#",
      "title": "Selection popup configuration",
      "description": "Everything in the app's Settings window. Edit it by hand if you like — the app reads this file at launch, so changes take effect the next time it starts. API keys are NOT here; they live in the macOS Keychain, so this file holds no secrets and can be committed. Note that an action of kind \\"script\\" runs a shell command: read a config from someone else before using it (the app also asks before a script runs for the first time).",
      "type": "object",
      "properties": {
        "$schema": { "type": "string" },
        "version": {
          "type": "integer",
          "description": "Format version of this file. Written by the app; leave it alone."
        },

        "general": {
          "type": "object",
          "description": "App-wide settings.",
          "properties": {
            "language": {
              "type": ["string", "null"],
              "enum": ["en", "zh-Hans", null],
              "description": "Interface language. null means follow the system."
            },
            "analytics": {
              "type": "boolean",
              "description": "Share anonymous usage statistics. No selected text, paths or personal data are ever sent."
            }
          },
          "additionalProperties": true
        },

        "popup": {
          "type": "object",
          "description": "The popup that appears when you select text. It runs whenever the app does — there is no on/off setting; quit the app to stop it.",
          "properties": {
            "style": {
              "type": "string",
              "enum": ["capsule", "wheel", "liquidGlass"],
              "description": "capsule = a bar above the selection. wheel / liquidGlass = a ring centred on the cursor."
            },
            "autoExpandHeight": {
              "type": "boolean",
              "description": "Let a result panel grow to fit its text (up to a maximum, then scroll). Width is always fixed."
            },
            "resultFontSize": {
              "type": "number", "minimum": 11, "maximum": 20,
              "description": "Base font size of the rendered result."
            }
          },
          "additionalProperties": true
        },

        "wheel": {
          "type": "object",
          "description": "Geometry of the ring styles. Ignored by the capsule style. Sizes are in points.",
          "properties": {
            "outerRadius": { "type": "number", "minimum": 90, "maximum": 170,
              "description": "Outer edge of the main ring." },
            "innerRadius": { "type": "number", "minimum": 28, "maximum": 140,
              "description": "The hole in the middle. Kept at least 26 below outerRadius." },
            "subSeam": { "type": "number", "minimum": 0, "maximum": 20,
              "description": "Gap between the main ring and a group's second ring." },
            "subThickness": { "type": "number", "minimum": 34, "maximum": 72,
              "description": "Band width of the second ring." },
            "showIcons": { "type": "boolean", "description": "Draw each action's icon." },
            "showLabels": { "type": "boolean", "description": "Draw each action's name." },
            "autoHideOnExit": { "type": "boolean",
              "description": "Dismiss the ring when the pointer leaves it." }
          },
          "additionalProperties": true
        },

        "ocr": {
          "type": "object",
          "description": "Press a hotkey, drag a box over anything on screen, get the text out of it. Needs the Screen Recording permission.",
          "properties": {
            "enabled": { "type": "boolean", "description": "Register the hotkey." },
            "autoCopy": { "type": "boolean",
              "description": "Also put the recognized text on the clipboard." },
            "hotKey": {
              "type": "string",
              "pattern": "^([a-zA-Z0-9]+\\\\+)*[a-zA-Z0-9]+$",
              "description": "Written the way it is spoken, e.g. \\"shift+cmd+s\\". Modifiers: ctrl, opt, shift, cmd. Keys: a-z, 0-9, f1-f12, space, return, tab, escape, delete, left, right, up, down."
            }
          },
          "additionalProperties": true
        },

        "webPreview": {
          "type": "object",
          "description": "Settings for the 'web preview' kind of action.",
          "properties": {
            "fallbackToSearch": { "type": "boolean",
              "description": "When the selection holds no link, search the web for the text instead." },
            "searchEngine": { "type": "string", "enum": ["bing", "google", "duckduckgo"] }
          },
          "additionalProperties": true
        },

        "models": {
          "type": "object",
          "description": "The default model for AI actions. The API key is NOT here — it is in the Keychain.",
          "properties": {
            "provider": { "type": "string",
              "description": "e.g. deepseek, openai, anthropic, ollama. Changing this resets model and apiURL to that provider's defaults." },
            "model": { "type": "string", "description": "Model id, as the provider spells it." },
            "apiURL": { "type": "string", "description": "Base URL of the provider's API." },
            "thinking": { "type": "string",
              "description": "Reasoning effort. Which values are allowed depends on the provider; anything it does not support is clamped. Use \\"none\\" for fast results." }
          },
          "additionalProperties": true
        },

        "actions": {
          "type": "array",
          "description": "The actions the popup offers, in order. An action with \\"kind\\": \\"group\\" opens a second ring holding its children.",
          "items": { "$ref": "#/definitions/action" }
        }
      },
      "additionalProperties": true,

      "definitions": {
        "action": {
          "type": "object",
          "properties": {
            "id": { "type": "string", "description": "Stable id. Leave it alone; a new action needs a new one." },
            "title": { "type": "string", "description": "What the popup shows." },
            "iconSymbol": { "type": "string", "description": "An SF Symbol name, e.g. \\"doc.on.doc\\"." },
            "kind": {
              "type": "string",
              "enum": ["ai", "copy", "webPreview", "quickLook", "revealInFinder", "openURL", "speak",
                       "transform", "shortcut", "script", "group"],
              "description": "What the action does. ai = send the selection to a model. openURL = open url with {text} filled in. speak = read it aloud. transform = a local text operation (op). shortcut = run a Shortcut. script = run a shell command. group = hold children. The rest act on links and paths."
            },
            "prompt": { "type": "string",
              "description": "For \\"ai\\": the instruction sent with the selection." },
            "url": { "type": "string",
              "description": "For \\"openURL\\": the address. {text} is replaced by the selection, encoded as one query value. e.g. https://www.google.com/search?q={text} or dict://{text}" },
            "openIn": { "type": "string", "enum": ["browser", "preview"],
              "description": "For \\"openURL\\": browser (default) or the popup's preview window. Addresses that are not web pages always open in the app that handles them." },
            "op": { "type": "string",
              "enum": ["uppercase", "lowercase", "titleCase", "sentenceCase", "camelCase", "snakeCase", "kebabCase",
                       "sortLines", "uniqueLines", "reverseLines", "joinLines", "trim", "toSimplified", "toTraditional",
                       "pinyin", "spaceCJK", "jsonPretty", "jsonMinify", "urlEncode", "urlDecode", "cleanURL", "count"],
              "description": "For \\"transform\\": which operation. count always shows its result in the popup." },
            "shortcut": { "type": "string",
              "description": "For \\"shortcut\\": the name of a Shortcut. The selection is its input; its output is the result." },
            "script": { "type": "string",
              "description": "For \\"script\\": a shell command, run by your login shell. The selection is on standard input and in $QDUO_TEXT; what it prints is the result. Times out after 10 seconds." },
            "output": { "type": "string", "enum": ["panel", "replace", "append", "copy"],
              "description": "For ai, transform, shortcut and script: where the result goes. panel (default) shows it in the popup, which offers a Replace button; replace puts it in place of the selection; append puts it after the selection; copy puts it on the clipboard." },
            "modelOverride": {
              "type": "object",
              "description": "Use a different model for THIS action only.",
              "properties": {
                "provider": { "type": "string" },
                "model": { "type": "string" },
                "effort": { "type": "string" }
              },
              "additionalProperties": true
            },
            "children": {
              "type": "array",
              "description": "Only for \\"kind\\": \\"group\\".",
              "items": { "$ref": "#/definitions/action" }
            }
          },
          "required": ["id", "title", "kind"],
          "additionalProperties": true
        }
      }
    }
    """
}
