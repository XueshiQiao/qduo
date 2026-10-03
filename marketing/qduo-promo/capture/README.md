# Recording the real popup

Every ring, capsule and panel in the film is the real QDuo popup, recorded from the
Debug build of `main`. Nothing here changes the app or its real config.

## What is here

| File | What it does |
| --- | --- |
| `make_home.py` | Builds `.home/`, a stand-in home folder holding a demo `config.json`: the app's seed actions (with 写作 and a 更多 group), the chosen style, the local fake model, the system voice. The app's History and logs for the run land there too, not in the real ones. |
| `qduo.sh` | `demo <liquidGlass\|donut\|capsule>` quits the running QDuo-Debug and starts it on `.home/`; `restore` starts it normally again. |
| `mock_llm.py` | A local OpenAI-style endpoint on port 11555 that streams fixed answers (`DEMO:<name>` in the action's prompt picks one). The popup, request, stream and panel are all real; only the words are scripted. |
| `demorec.swift` | One program that shows the document window, drives the real mouse through a scene, and records the screen around it with ScreenCaptureKit (only its own window and QDuo-Debug's, plus QDuo's audio). Writes `takes/<scene>.mov` (ProRes, Retina pixels, 60 fps) and `takes/<scene>.json` (capture rectangle, every mouse event's time). |
| `build.sh` | Compiles `demorec` into `bin/`. |
| `extract.sh` | Turns the takes into the 60 fps JPEG frames under `../frames/` that the film plays, plus `frames/manifest.js`. |

## Re-recording

```bash
cd marketing/qduo-promo/capture
python3 mock_llm.py 11555 &            # the fake model
./build.sh
./qduo.sh demo liquidGlass && ./bin/demorec liquid takes
./qduo.sh demo donut       && ./bin/demorec donut takes
./qduo.sh demo capsule     && ./bin/demorec polish takes && ./bin/demorec read takes
./qduo.sh restore
./extract.sh
```

The mouse is taken over during a take: leave it alone. Each take is 7–9 s.

After a re-record the event times move a little. Read them from `takes/<scene>.json`
and update the `map`, `sfx` and `CLICKS` entries in `../cues.js` (and the camera keys
in `../film.js` if the popup landed elsewhere), then rebuild the sound and the film.

## Things that bit

- **The Debug build is ad-hoc signed**, so every rebuild loses its Accessibility grant.
  `qduo.sh` starts it as a child of the terminal, which then lends it the terminal's
  grant. Started through `open`, it would ask for the permission again.
- **The same signing means it cannot read the cloud voices' API keys** (they are in the
  release build's data-protection keychain). The demo reader is therefore the macOS
  system voice (Tingting).
- **A window being captured gets a purple capture badge where its traffic lights go.**
  The document window is borderless and draws its own title bar for that reason.
- QDuo is launched with `CFFIXED_USER_HOME`, which moves `~/.config/qduo`,
  `~/Library/Application Support` and `~/Library/Logs` for that process only.
  UserDefaults are not moved (they go through `cfprefsd`).
