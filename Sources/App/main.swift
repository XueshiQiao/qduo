import Cocoa

// `<executable> cli …` is the command line for AI agents and scripts
// (`AgentCLI`). It must branch off before NSApplication exists: no menu bar
// icon, no window, no input monitors — it does its job and exits.
if AgentCLI.shouldHandle(CommandLine.arguments) {
    exit(AgentCLI.run(CommandLine.arguments, env: .live))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
