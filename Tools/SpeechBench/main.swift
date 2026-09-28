import Foundation

// speech-bench — measures cloud TTS providers for QDuo's read-aloud.
//
//   speech-bench init                 write the config template (never overwrites)
//   speech-bench run [options]        measure every enabled provider
//       --only volcengine,elevenlabs  just these providers
//       --text zh-short,mixed         just these texts
//       --repeat 3                    attempts per provider × text (first is cold)
//       --config <path>               default ~/.config/qduo/speech-bench.json
//
// What each number means is in Tools/SpeechBench/README.md.

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
let defaultConfig = ("~/.config/qduo/speech-bench.json" as NSString).expandingTildeInPath

func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let configPath = (option("--config").map { ($0 as NSString).expandingTildeInPath }) ?? defaultConfig

switch arguments.first {
case "init":
    if FileManager.default.fileExists(atPath: configPath) {
        print("already exists, left untouched: \(configPath)")
    } else {
        try FileManager.default.createDirectory(atPath: (configPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(BenchTemplate.json.utf8).write(to: URL(fileURLWithPath: configPath))
        // The file holds API keys: readable by the owner only.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
        print("wrote \(configPath) — fill in the keys, then: speech-bench run")
    }
case "run":
    await Bench.run(configPath: configPath,
                    only: option("--only").map { Set($0.split(separator: ",").map(String.init)) },
                    texts: option("--text").map { Set($0.split(separator: ",").map(String.init)) },
                    repeatOverride: option("--repeat").flatMap(Int.init))
default:
    print("""
    usage: speech-bench init | run [--only a,b] [--text id,id] [--repeat n] [--config path]
    providers: \(TTSEngineRegistry.all.keys.sorted().joined(separator: ", "))
    """)
}
