#!/usr/bin/env python3
"""Write ../cues.js from the recorder's logs (takes/<take>.json).

The plan below says where each take sits in the film; every sound-effect time and
click position is then read off the take's own event log, so a re-record only
needs the plan's numbers touched (and often not even those).
"""
import json, os, subprocess
import numpy as np   # run with the project venv: .venv/bin/python capture/make_cues.py
HERE = os.path.dirname(os.path.abspath(__file__))

# Each shot plays its take at real speed from `take_from`, starting at film time `film`.
SHOTS = [
    dict(take='liquid', film=0.0, take_from=1.4, take_to=9.6),
    dict(take='donut', take_from=2.3, take_to=10.9),
    dict(take='polish', take_from=2.35, take_to=11.6),
    dict(take='read', take_from=2.3, take_to=10.8),
]
END_CARD = 3.15
# Scene copy (left-hand text) changes, as offsets in take seconds from the shot.
# A scene starts at that take moment; see film.js for each scene's words.
SCENES = [('intro', 'liquid', None), ('translate', 'liquid', 'click.translate'),
          ('dimension', 'donut', None), ('write', 'donut', 'click.write'),
          ('polish', 'polish', None), ('read', 'read', None)]
LEAD = 0.25  # a scene's words arrive this long before the click that names it

takes = {s['take']: json.load(open(os.path.join(HERE, 'takes', s['take'] + '.json'))) for s in SHOTS}
t = 0.0
for s in SHOTS:
    s['film'] = round(t, 3)
    t += s['take_to'] - s['take_from']
    s['end'] = round(t, 3)
duration = round(t + END_CARD, 3)


def film_t(shot, take_t):
    return round(shot['film'] + take_t - shot['take_from'], 3)


def onset(take, t0, t1, threshold=0.18):
    """First moment in [t0, t1] (take seconds) where the picture visibly changes:
    when a submenu actually unfolds on screen. The log only says when the pointer
    got there, and the app opens the submenu a little before or after that."""
    w, h = 450, 390
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-ss', str(t0), '-t', str(t1 - t0), '-i',
                          os.path.join(HERE, 'takes', take + '.mov'), '-vf', f'fps=60,scale={w}:{h},format=gray',
                          '-f', 'rawvideo', '-'], capture_output=True, check=True).stdout
    f = np.frombuffer(raw, np.uint8).reshape(-1, h, w).astype(float)
    d = np.abs(np.diff(f, axis=0)).mean((1, 2))
    hit = np.nonzero(d > threshold)[0]
    return t0 + (hit[0] + 1) / 60 if len(hit) else None


def ring_highlights(take):
    """When each ring slot visibly lights up (blue caption pixels move to a new
    slot), in take seconds. The log is written as the pointer crosses into a slot;
    the highlight shows a frame or two later and fades in."""
    d = takes[take]
    rect = d['rect']
    x, y, w, h = [float(v) for v in ev(take, 'popup')['frame'].strip('()').split(',')]
    cx, cy = (x + w / 2 - rect[0]) * 2, (y + h / 2 - rect[1]) * 2
    hov = [e for e in d['events'] if e['event'] == 'hover']
    t0, t1, R = hov[0]['t'] - 0.3, hov[-1]['t'] + 0.4, 260
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-ss', str(t0), '-t', str(t1 - t0), '-i',
                          os.path.join(HERE, 'takes', take + '.mov'), '-vf',
                          f'fps=60,crop={2*R}:{2*R}:{cx-R}:{cy-R},format=rgb24', '-f', 'rawvideo', '-'],
                         capture_output=True, check=True).stdout
    f = np.frombuffer(raw, np.uint8).reshape(-1, 2 * R, 2 * R, 3).astype(int)
    yy, xx = np.mgrid[-R:R, -R:R]
    ang, rad = np.degrees(np.arctan2(xx, -yy)) % 360, np.hypot(xx, yy)
    ring = (rad > 120) & (rad < 224)
    out, prev = [], None
    for i, fr in enumerate(f):
        blue = (fr[..., 2] > 200) & (fr[..., 0] < 80) & (fr[..., 1] > 100) & ring
        if blue.sum() < 30:
            continue
        slot = int(np.median(ang[blue]) // (360 / 7))
        if slot != prev:
            out.append(t0 + i / 60)
            prev = slot
    return out


# How long after a slot starts to light the tick should land: the liquid glass
# highlight fades in, so its tick sits a little later than the 3D ring's.
TICK_LAG = {'liquid': 0.06, 'donut': 0.02}


def ev(take, name):
    return next(e for e in takes[take]['events'] if e['event'] == name)


shot_of = {s['take']: s for s in SHOTS}
scenes = []
for sid, take, at in SCENES:
    s = shot_of[take]
    start = s['film'] if at is None else film_t(s, ev(take, at)['t']) - LEAD
    scenes.append(dict(id=sid, start=round(start, 3)))
scenes.append(dict(id='end', start=SHOTS[-1]['end']))
for a, b in zip(scenes, scenes[1:]):
    a['end'] = b['start']
scenes[-1]['end'] = duration

sfx, clicks = [], {}
for s in SHOTS:
    take, rect = s['take'], takes[s['take']]['rect']
    style = {'liquid': 'liquid', 'donut': 'donut'}.get(take, 'capsule')
    clicks[take] = []
    if s['film'] > 0:
        sfx.append(dict(t=s['film'], kind='whoosh'))
    for e in takes[take]['events']:
        if not (s['take_from'] <= e['t'] <= s['take_to']):
            continue
        ft, name = film_t(s, e['t']), e['event']
        if name == 'select.down':
            sfx.append(dict(t=ft, kind='press'))
        elif name == 'select.up':
            sfx.append(dict(t=ft, kind='release'))
        elif name == 'popup':
            sfx.append(dict(t=ft, kind='pop', style=style))
        elif name == 'hover' and style != 'capsule':
            continue                      # ring ticks come from the picture, below
        elif name == 'hover':
            # Ring slots light as the pointer crosses into them, which is when the
            # recorder logs it. Capsule buttons light at their edge, but the log is
            # written near their centre: about 0.08 s late at the glide's speed.
            sfx.append(dict(t=round(ft - (0.08 if style == 'capsule' else 0), 3), kind='tick'))
        elif name == 'hover.more' and take != 'read':
            # From the moment the pointer entered the group slot, find on screen when
            # the submenu actually unfolds.
            enter = max(x['t'] for x in takes[take]['events'] if x['event'] == 'hover' and x['t'] <= e['t'] - 0.05)
            seen = onset(take, enter - 0.1, e['t'] + 0.5)
            sfx.append(dict(t=film_t(s, seen if seen else e['t']), kind='unfold'))
        elif name.startswith('click.') and not name.endswith('.up'):
            sfx.append(dict(t=ft, kind='click'))
            clicks[take].append(dict(t=round(e['t'], 3), x=round(e['x'] - rect[0]), y=round(e['y'] - rect[1])))
            if name == 'click.replace':
                sfx.append(dict(t=round(ft + 0.08, 3), kind='replace'))
            else:
                sfx.append(dict(t=round(ft + 0.13, 3), kind='panel'))
# Ring ticks: one per slot as it visibly lights.
for s in SHOTS:
    if s['take'] in TICK_LAG:
        for t in ring_highlights(s['take']):
            if s['take_from'] <= t <= s['take_to']:
                sfx.append(dict(t=round(film_t(s, t) + TICK_LAG[s['take']], 3), kind='tick'))
# Text streaming in after an AI action (the mock streams 30 ms a character).
STREAM = {'click.translate': 31, 'click.write': 70, 'click.polish': 26}
for s in SHOTS:
    for e in takes[s['take']]['events']:
        if e['event'] in STREAM and s['take_from'] <= e['t'] <= s['take_to']:
            sfx.append(dict(t=round(film_t(s, e['t']) + 0.28, 3), kind='type', dur=round(STREAM[e['event']] * 0.03, 2)))
sfx.append(dict(t=SHOTS[-1]['end'], kind='whoosh'))
sfx.append(dict(t=round(SHOTS[-1]['end'] + 0.15, 3), kind='logo'))
sfx.sort(key=lambda c: c['t'])
# One tick per button: a glide can log the button it starts on a second time.
dedup = []
for c in sfx:
    if c['kind'] == 'tick' and dedup and any(d['kind'] == 'tick' and c['t'] - d['t'] < 0.2 for d in dedup[-3:]):
        continue
    dedup.append(c)
sfx = dedup

# The read-aloud voice: everything the read take heard from its click on.
r = shot_of['read']
voice_from = ev('read', 'click.read')['t']
voice = dict(take='read', film=film_t(r, voice_from), takeFrom=round(voice_from, 3), takeTo=r['take_to'])

cues = dict(duration=duration, scenes=scenes,
            shots=[dict(take=s['take'], start=s['film'], end=s['end'],
                        map=[[s['film'], s['take_from']], [s['end'], s['take_to']]]) for s in SHOTS],
            voice=voice, sfx=sfx)
out = os.path.join(HERE, '..', 'cues.js')
with open(out, 'w') as f:
    f.write('/* GENERATED by capture/make_cues.py from capture/takes/*.json — edit the plan there.\n'
            ' * Film seconds throughout; a shot\'s `map` pairs [film, take] seconds. Read by\n'
            ' * film.js (window.CUES, window.CLICKS) and soundtrack.py (the JSON after "="). */\n')
    f.write('window.CUES = ' + json.dumps(cues, ensure_ascii=False, indent=1) + ';\n\n')
    f.write('window.CLICKS = ' + json.dumps(clicks) + ';\n')
print(f'duration {duration}s; scenes', [(s["id"], s["start"]) for s in scenes])
print('shots', [(s['take'], s['film'], s['end']) for s in SHOTS])
print('clicks', clicks)
