import Foundation

/// The message a user pastes into an AI coding agent so it can configure the
/// app: where the skill, the command line and the config file are on this Mac,
/// the order to work in, and the user's request.
///
/// Written in the user's language — Chinese when the app is in Chinese,
/// English otherwise. The skill itself is English: agents read it, not people.
enum AgentPrompt {

    enum Language: String, Codable {
        case zh, en

        /// The app's language setting (`general.language`), else the system's.
        static func current(configLanguage: String? = nil) -> Language {
            if let configLanguage { return configLanguage.hasPrefix("zh") ? .zh : .en }
            return (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? .zh : .en
        }
    }

    struct Paths: Equatable {
        let skillFile: String
        let cli: String
        let config: String
    }

    static func build(_ language: Language, paths: Paths, request: String? = nil) -> String {
        let request = request?.trimmingCharacters(in: .whitespacesAndNewlines)
        let filled = (request?.isEmpty == false) ? request : nil
        let cli = "\"\(paths.cli)\" cli"
        switch language {
        case .zh:
            return """
            请帮我配置 macOS 上的 \(Brand.name)（选中文字后弹出一圈动作的效率工具：翻译、润色、搜索、朗读、文本处理等）。

            这台 Mac 上的路径：
            - 配置说明（Skill）："\(paths.skillFile)"
            - 命令行工具："\(paths.cli)"
            - 配置文件："\(paths.config)"

            请按这个顺序做：
            1. 先完整读一遍 "\(paths.skillFile)"，需要时再读同一目录下 references/ 里的文档。
            2. 运行 \(cli) info 查看当前状态，再读配置文件和它旁边的 config.schema.json。
            3. 把改好的完整配置写到一个临时文件，先用 \(cli) validate <临时文件> 检查，没有错误后再用 \(cli) apply <临时文件> 写入。apply 会先备份旧配置，再重启正在运行的 \(Brand.name) 让新配置生效；改错了用 \(cli) rollback 退回上一版。如果你的命令在沙箱里运行：读文件、info、validate 在沙箱里就能做；apply、rollback、restart 要写配置文件并重启 App，必须在沙箱外运行，请为这几条命令申请在沙箱外运行。
            4. 不要向我要 API Key，也不要读写钥匙串；需要 Key 时请提醒我到 \(Brand.name) 设置里的「AI 模型」页面自己填写。
            5. 只改我要求的部分，其他动作和设置保持原样。改完告诉我改了什么、备份在哪里、怎么撤销。
            6. 如果下面「我的需求」写了内容，就照着做；如果是空的，先读一遍我现在的配置，简单介绍一下我有哪些动作，再问我想改什么。

            我的需求：\(filled ?? "")
            """
        case .en:
            return """
            Help me configure \(Brand.name) on macOS (a popup of actions that appears when I select text: translate, polish, search, read aloud, text tools and more).

            Paths on this Mac:
            - Skill guide: "\(paths.skillFile)"
            - Command line: "\(paths.cli)"
            - Config file: "\(paths.config)"

            Work in this order:
            1. Read "\(paths.skillFile)" in full first, and the files in its references/ folder when you need them.
            2. Run \(cli) info to see the current state, then read the config file and the config.schema.json beside it.
            3. Write the complete edited config to a temporary file, check it with \(cli) validate <temp file>, and once it has no errors put it in place with \(cli) apply <temp file>. apply backs up the old config and restarts the running \(Brand.name) so the new one takes effect; \(cli) rollback undoes it. If your commands run in a sandbox: reading files, info and validate work inside it; apply, rollback and restart write the config and restart the app, so request to run those outside the sandbox.
            4. Never ask me for an API key and never touch the Keychain; if a key is needed, tell me to enter it myself on the AI Models page of \(Brand.name)'s settings.
            5. Change only what I ask for and keep every other action and setting as it is. Afterwards tell me what changed, where the backup is and how to undo it.
            6. If "My request" below is filled in, do it; if it is empty, read my current config, briefly describe the actions I have, and ask what I want to change.

            My request: \(filled ?? "")
            """
        }
    }

    // MARK: - Examples

    /// Ready-made requests the settings page offers, each copied as a whole prompt.
    struct Example: Identifiable, Equatable {
        let id: String
        let symbol: String
        let zh: String
        let en: String

        func text(_ language: Language) -> String { language == .zh ? zh : en }
    }

    static let examples: [Example] = [
        Example(id: "explore", symbol: "magnifyingglass",
                zh: "先只看不改：介绍一下我现在有哪些动作、各自做什么，再说说 \(Brand.name) 还能做哪些我没用上的事，给我推荐三个适合我的动作。",
                en: "Read only, change nothing: tell me what actions I have and what each one does, what else \(Brand.name) can do that I am not using, and recommend three actions that would suit me."),
        Example(id: "translate", symbol: "translate",
                zh: "加一个「译成日语」动作：用免费的翻译引擎，目标语言日语；如果选中的文字已经是日语，就翻译成简体中文。放在翻译动作的旁边。",
                en: "Add a \"To Japanese\" action that uses a free translation engine with Japanese as the target; when the selected text is already Japanese, translate it into English instead. Put it next to my translate action."),
        Example(id: "writing", symbol: "pencil.and.outline",
                zh: "加一个叫「写作」的分组，里面放三个 AI 动作：改成正式语气、改成口语、精简。结果先用对比视图显示改了哪里，我确认后再替换原文。",
                en: "Add a group called \"Writing\" with three AI actions inside: make it formal, make it casual, make it shorter. Show each result as a comparison with the changes marked, so I can check before replacing the text."),
        Example(id: "search", symbol: "globe",
                zh: "加一个叫「搜索」的分组，里面放 Google、GitHub、维基百科、B 站四个搜索动作，并把我现在单独的搜索动作也挪进去。",
                en: "Add a group called \"Search\" with Google, GitHub, Wikipedia and YouTube searches inside, and move my existing search action into it."),
        Example(id: "apps", symbol: "keyboard",
                zh: "把弹出快捷键设成双击 Option；在终端（我装了哪个就用哪个）和 Excel 里选中文字时不要自动弹出。",
                en: "Set the popup hotkey to a double tap of Option, and stop the popup from appearing automatically when I select text in my terminal app (whichever I have installed) and in Excel."),
        Example(id: "rollback", symbol: "clock.arrow.circlepath",
                zh: "列出最近几次的配置备份，告诉我每次大概改了什么；然后帮我退回到上一个版本。",
                en: "List my recent config backups and roughly what changed in each, then roll back to the previous version."),
    ]
}
