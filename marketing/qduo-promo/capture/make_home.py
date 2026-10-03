#!/usr/bin/env python3
"""Build an isolated home for the QDuo-Debug recording run.

QDuo reads ~/.config/qduo/config.json and keeps its History under
~/Library/Application Support. Launched with CFFIXED_USER_HOME pointing here, the
app reads a demo config instead and records its History here, so recording never
touches the real config or the real History. API keys stay in the Keychain.

Usage: make_home.py <style>    style = liquidGlass | donut | capsule
"""
import json, os, sys, uuid
HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.join(HERE, '.home')
REAL = os.path.expanduser('~/.config/qduo/config.json')
MOCK_PORT = 11555
style = sys.argv[1] if len(sys.argv) > 1 else 'liquidGlass'
assert style in ('liquidGlass', 'donut', 'capsule'), style

def uid(name):  # stable ids, so every take shows the same actions
    return str(uuid.uuid5(uuid.NAMESPACE_URL, 'qduo-promo/' + name)).upper()

def ai(title, icon, prompt, **extra):
    return dict(id=uid(title), schemaVersion=1, kind='ai', title=title, iconSymbol=icon, prompt=prompt, **extra)

# The app's own seed set (DefaultActions.seed), with Explain swapped for a custom
# "写作" AI action, and the files/web group swapped for a "更多" group of AI actions.
actions = [
    ai('翻译', 'character.bubble', 'DEMO:translate'),
    ai('润色', 'wand.and.stars', 'DEMO:polish', output='compare'),
    ai('写作', 'square.and.pencil', 'DEMO:write'),
    dict(id=uid('更多'), schemaVersion=1, kind='group', title='更多', iconSymbol='square.grid.2x2', children=[
        ai('解释', 'lightbulb', 'DEMO:explain'),
        ai('总结', 'text.quote', 'DEMO:summarize'),
        ai('中译英', 'textformat', 'DEMO:toEnglish'),
    ]),
    dict(id=uid('搜索'), schemaVersion=1, kind='openURL', title='搜索', iconSymbol='magnifyingglass',
         url='https://www.google.com/search?q={text}'),
    dict(id=uid('朗读'), schemaVersion=1, kind='speak', title='朗读', iconSymbol='speaker.wave.2.fill'),
    dict(id=uid('复制'), schemaVersion=1, kind='copy', title='复制', iconSymbol='doc.on.doc'),
]

real = json.load(open(REAL))
cfg = {k: v for k, v in real.items() if k not in ('actions', '$schema')}  # geometry, capsule, speech readers
cfg['actions'] = actions
cfg['models'] = {'provider': 'ollama', 'apiURL': f'http://127.0.0.1:{MOCK_PORT}/api/chat',
                 'model': 'qwen2.5:7b', 'thinking': 'none'}
popup = dict(real.get('popup', {}))
popup.update(style=style, enabled=True, hotKeyEnabled=False, compareView='diff', readingHighlight='pill')
cfg['popup'] = popup
cfg['ocr'] = dict(real.get('ocr', {}), enabled=False)
# Read aloud with one of the user's own cloud readers (READER=<name>, default
# MiniMax). Its key is read from the Keychain, which only a build signed with the
# team's keychain group can do — see qduo.sh.
want = os.environ.get('READER', 'MiniMax')
speech = dict(real.get('speech', {}))
match = [r for r in speech.get('readers', []) if r.get('name') == want]
assert match, f'no reader named {want}'
speech['defaultReader'] = match[0]['id']
cfg['speech'] = speech

os.makedirs(os.path.join(HOME, '.config/qduo'), exist_ok=True)
json.dump(cfg, open(os.path.join(HOME, '.config/qduo/config.json'), 'w'), ensure_ascii=False, indent=2)
# Every take reads aloud live: drop the demo home's speech cache, so the panel
# shows the reader working rather than a "cached" replay.
import shutil
shutil.rmtree(os.path.join(HOME, 'Library/Caches/QDuo/Speech'), ignore_errors=True)
print(HOME)
