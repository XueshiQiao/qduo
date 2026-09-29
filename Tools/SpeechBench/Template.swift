/// The config `speech-bench init` writes. Keys starting with "_" are notes for
/// the person filling it in; the tool ignores them.
enum BenchTemplate {
    static let json = #"""
{
  "_说明": "填好各家的 key，把要测的那家 enabled 改成 true，然后运行 scripts/speech-bench.sh run。这个文件含 key，只放在本机，不要提交。",
  "repeat": 3,
  "bufferBudgetMs": 300,
  "_bufferBudgetMs": "实时判定标准：从收到第一段音频起，播放器最多先攒这么多毫秒再开播；之后只要一次都没断粮，就算『跟得上实时』。",
  "outputDir": "",
  "_outputDir": "留空 = 当前目录下 build/speech-bench-results/<时间>/，里面有每次的录音 wav、逐字时间表和汇总。",

  "providers": {
    "volcengine": {
      "enabled": false,
      "_说明": "豆包语音合成 2.0。控制台 console.volcengine.com/speech/new → 实名认证 → 一键开通 → 左侧『API Key 管理』创建。新控制台只填 apiKey；老控制台填 appId + accessKey。",
      "apiKey": "",
      "appId": "",
      "accessKey": "",
      "resourceId": "seed-tts-2.0",
      "voice": "zh_female_vv_uranus_bigtts",
      "speed": 1.0
    },
    "qwen-audio": {
      "enabled": false,
      "_说明": "阿里云百炼 Qwen-Audio TTS。百炼控制台 → API Key。region: cn = 北京，intl = 新加坡（国际站账号用 intl）。它的系统音色是否返回逐字时间，文档没写清，正要靠这次实测确认。",
      "apiKey": "",
      "region": "cn",
      "model": "qwen-audio-3.0-tts-flash",
      "voice": "longanhuan_v3.6",
      "speed": 1.0
    },
    "elevenlabs": {
      "enabled": false,
      "_说明": "elevenlabs.io → Profile → API Keys。voice 必填：在网站 Voices 里挑一个加到 My Voices，复制它的 Voice ID（免费账号不能通过 API 用音色库里的音色，2026-03 以后注册的账号也没有默认音色）。",
      "apiKey": "",
      "voice": "",
      "model": "eleven_flash_v2_5",
      "speed": 1.0
    },
    "elevenlabs-v3": {
      "enabled": false,
      "engine": "elevenlabs",
      "_说明": "同一家换个模型对比。apiKey、voice 同上。",
      "apiKey": "",
      "voice": "",
      "model": "eleven_v3"
    },
    "minimax": {
      "enabled": false,
      "_说明": "MiniMax 开放平台 → 账户管理 → API Keys。region: cn = api.minimax.cn（国内账号），intl = api.minimax.io（国际账号）。默认走双向 WebSocket（transport 写 http 改走 HTTP SSE）。文档没写逐字时间放在哪个字段、什么时候到，这正是要测的。",
      "apiKey": "",
      "region": "cn",
      "model": "speech-2.8-turbo",
      "voice": "Chinese (Mandarin)_News_Anchor",
      "speed": 1.0
    },
    "system": {
      "enabled": true,
      "_说明": "macOS 系统语音，不需要 key，作为对照基线。"
    }
  },

  "texts": [
    { "id": "zh-short", "text": "今天天气不错，我们去公园散步吧。" },
    { "id": "en-short", "text": "The quick brown fox jumps over the lazy dog." },
    { "id": "mixed", "text": "我昨天用 Swift 写了一个 macOS App，发布到了 GitHub 上，大概花了三个小时。" },
    { "id": "numbers", "text": "2024年9月28日，价格是3.5元，温度零下5度，版本号 v2.8.1。" },
    { "id": "en-tech", "text": "On September 28, 2026, Apple released macOS 27.1 with a 3.5x faster Safari. Run softwareupdate -i -a, or visit apple.com/macos for details." },
    { "id": "en-news", "text": "\"We're not there yet,\" said Dr. Lee, the lab's director. Still, the team's model beat its rivals on 7 of 10 benchmarks, according to a report published on Tuesday by the MIT Technology Review." },
    { "id": "mixed-tech", "text": "打开 Xcode 的 Build Settings，把 Swift Language Version 改成 Swift 6，然后 clean build 一下就好了。" },
    { "id": "zh-long", "text": "朗读功能的体验，很大程度上取决于第一个字出来得有多快。用户选中一段文字，点下朗读，如果要等上两三秒才听到声音，就会怀疑是不是没点中。所以我们关心的不只是声音好不好听，还有它从发出请求到开口需要多久，以及开口之后能不能一直跟上播放的速度，中间不卡顿。同时，为了让用户知道念到了哪里，我们还需要每个字的时间信息，好在屏幕上把正在念的字高亮出来。" },
    { "id": "en-long", "text": "A good read-aloud feature is judged in the first second. When someone selects a paragraph and presses play, they expect to hear the first word almost immediately; a two-second pause feels like the button did nothing. After that, the audio has to keep flowing without gaps, and the words on screen should light up in step with the voice, so the listener never loses their place. This paragraph is long enough to show whether a provider keeps up once the first sentence is out of the way." }
  ]
}
"""#
}
