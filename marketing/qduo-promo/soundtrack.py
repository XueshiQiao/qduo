#!/usr/bin/env python3
"""The film's sound, as three separate stems plus a mix.

  assets/audio/music.wav  background music, the film's length, synthesised here (swap it freely)
  assets/audio/sfx.wav    sound effects, every one placed on a cue from cues.js
  assets/audio/voice.wav  the read-aloud voice, cut from the real recording
  assets/audio/mix.wav    the three together: music ducked under the voice, then
                          limited — what render.mjs puts in the MP4

Run with the project venv (numpy, scipy):
  .venv/bin/python soundtrack.py                 # rebuild everything
  .venv/bin/python soundtrack.py --music my.mp3  # keep sfx + voice, remix over your music
  .venv/bin/python soundtrack.py --mix-only      # remix existing stems (after editing one)
"""
import argparse, json, os, subprocess, sys
import numpy as np
from scipy import signal
from scipy.io import wavfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'assets/audio')
SR = 48000
CUES = json.loads(open(os.path.join(HERE, 'cues.js')).read().split('window.CUES =', 1)[1].split('};', 1)[0] + '}')
DUR = CUES['duration']
N = int(DUR * SR)
rng = np.random.default_rng(7)  # fixed seed: the same sound every run


def t_axis(sec):
    return np.arange(int(sec * SR)) / SR


def env_adsr(n, a, d, s, r, sustain_len=None):
    """Attack/decay/sustain/release envelope over n samples (times in seconds)."""
    a, d, r = int(a * SR), int(d * SR), int(r * SR)
    hold = max(0, n - a - d - r) if sustain_len is None else int(sustain_len * SR)
    e = np.concatenate([np.linspace(0, 1, max(a, 1)), np.linspace(1, s, max(d, 1)), np.full(hold, s), np.linspace(s, 0, max(r, 1))])
    return np.pad(e, (0, max(0, n - len(e))))[:n]


def lowpass(x, hz, order=2):
    return signal.sosfilt(signal.butter(order, hz, 'low', fs=SR, output='sos'), x)


def highpass(x, hz, order=2):
    return signal.sosfilt(signal.butter(order, hz, 'high', fs=SR, output='sos'), x)


def bandpass(x, lo, hi, order=2):
    return signal.sosfilt(signal.butter(order, [lo, hi], 'band', fs=SR, output='sos'), x)


def place(bus, x, at, gain=1.0, pan=0.0):
    """Add mono or stereo x into a stereo bus at `at` seconds, equal-power pan."""
    if x.ndim == 1:
        l, r = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
        x = np.stack([x * l, x * r], 1) * np.sqrt(2)
    i = int(round(at * SR))
    if i >= len(bus):
        return
    j = min(len(bus), i + len(x))
    bus[max(i, 0):j] += x[max(0, -i):j - i] * gain


def reverb(x, seconds=1.6, damp=4500, mix=0.25, predelay=0.012):
    """Convolution with a synthetic room: decaying, darkening stereo noise."""
    n = int(seconds * SR)
    t = np.arange(n) / SR
    ir = rng.standard_normal((n, 2)) * np.exp(-t * 6.9 / seconds)[:, None]
    ir = np.stack([lowpass(ir[:, c], damp) for c in range(2)], 1)
    ir = np.pad(ir, ((int(predelay * SR), 0), (0, 0)))
    ir /= np.sqrt((ir ** 2).sum(0, keepdims=True))
    wet = np.stack([signal.fftconvolve(x[:, c], ir[:, c])[:len(x)] for c in range(2)], 1)
    return x * (1 - mix) + wet * mix * 1.6


def midi(n):
    return 440.0 * 2 ** ((n - 69) / 12)


# ---------------------------------------------------------------- music ----
BPM = 112
BEAT = 60 / BPM
BAR = 4 * BEAT
# Bright, unhurried: Cmaj9 – Am9 – Fmaj9 – G6/9, then home to Cmaj9 for the end card.
CHORDS = [[48, 55, 59, 62, 64], [45, 52, 55, 59, 60], [41, 48, 52, 55, 57], [43, 50, 52, 57, 59]]
ROOTS = [36, 45, 41, 43]


def e_piano(f, dur, vel=1.0):
    """FM electric piano: a bell-ish attack that mellows, with a soft tine."""
    t = t_axis(dur)
    idx = 2.2 * np.exp(-t * 9) + 0.25
    mod = np.sin(2 * np.pi * f * t) * idx
    tone = np.sin(2 * np.pi * f * t + mod) + 0.18 * np.sin(2 * np.pi * f * 4.0 * t) * np.exp(-t * 26)
    return tone * env_adsr(len(t), 0.003, 0.5, 0.35, 0.25) * vel * np.exp(-t * 1.1)


def pad_voice(f, dur):
    """Warm pad: five detuned band-limited saws, slow attack, dark filter."""
    t = t_axis(dur)
    out = np.zeros(len(t))
    for det in (-7, -3, 0, 4, 8):
        ff = f * 2 ** (det / 1200)
        for h in range(1, int(5000 / ff)):
            out += np.sin(2 * np.pi * ff * h * t + rng.uniform(0, 6.28)) / h
    return lowpass(out, 1800) * env_adsr(len(t), 0.6, 0.4, 0.8, 0.9) / 5


def kick():
    t = t_axis(0.45)
    f = 52 + 110 * np.exp(-t * 32)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 7.5)
    click = highpass(rng.standard_normal(len(t)), 2500) * np.exp(-t * 180) * 0.15
    return np.tanh((body + click) * 1.4)


def snap():
    t = t_axis(0.25)
    n = bandpass(rng.standard_normal(len(t)), 1200, 6500)
    bursts = sum(np.exp(-np.clip(t - d, 0, None) * 70) * (t >= d) for d in (0, 0.009, 0.019))
    return n * bursts * 0.5 + np.sin(2 * np.pi * 220 * t) * np.exp(-t * 40) * 0.12


def hat(open_=False):
    t = t_axis(0.3 if open_ else 0.06)
    return highpass(rng.standard_normal(len(t)), 7500, 4) * np.exp(-t * (14 if open_ else 75)) * 0.5


def sub_bass(f, dur):
    t = t_axis(dur)
    x = np.sin(2 * np.pi * f * t) + 0.25 * np.sin(4 * np.pi * f * t)
    return np.tanh(x * 1.3) * env_adsr(len(t), 0.01, 0.15, 0.7, 0.08)


def music():
    pads, keys, drums, bass = (np.zeros((N + SR * 3, 2)) for _ in range(4))
    side = np.ones(N + SR * 3)  # sidechain gain the kick pumps on the pad and keys
    bars = int(np.ceil(DUR / BAR)) + 1
    end_at = CUES['scenes'][-1]['start']        # end card: the music resolves here
    for b in range(bars):
        t0 = b * BAR
        if t0 >= DUR:
            break
        ch = CHORDS[b % 4]  # the end card's home chord is laid separately below
        if t0 >= end_at - 0.05:
            break
        # Pad: one chord per bar.
        for n in ch[:4]:
            place(pads, pad_voice(midi(n + 12), min(BAR, end_at - t0) + 0.9), t0, 0.075, pan=rng.uniform(-.5, .5))
        # Keys: a gentle broken-chord figure on eighths, voiced up an octave.
        pattern = [0, 2, 4, 3, 1, 4, 2, 3]
        for k, step in enumerate(pattern):
            at = t0 + k * BEAT / 2
            if at >= end_at - 0.02:
                break
            vel = 0.9 if k % 2 == 0 else 0.62
            place(keys, e_piano(midi(ch[step] + 24), 0.9, vel), at, 0.11, pan=(-.35 if k % 2 else .35))
        # Drums and bass from bar 2 (the first bar is just keys and pad).
        if b >= 1:
            for beat in range(4):
                at = t0 + beat * BEAT
                if at >= end_at - 0.05:
                    break
                place(drums, kick(), at, 0.24)
                i = int(at * SR)
                side[i:i + int(0.28 * SR)] = np.minimum(side[i:i + int(0.28 * SR)], 1 - 0.38 * np.exp(-np.arange(int(0.28 * SR)) / SR * 14))
                if beat in (1, 3):
                    place(drums, snap(), at, 0.32, pan=0.05)
                for e in range(2):
                    swing = 0.02 if e else 0
                    place(drums, hat(open_=(beat == 3 and e == 1)), at + e * BEAT / 2 + swing, 0.2 if e else 0.14, pan=0.3)
            root = ROOTS[b % 4]
            for at, dur in ((0, 1.5), (1.5, 1.0), (2.5, 1.5)):
                if t0 + at * BEAT < end_at - 0.05:
                    place(bass, sub_bass(midi(root), dur * BEAT * 0.95), t0 + at * BEAT, 0.1)
    # End card: home chord, held, keys spelling it out once, a soft low boom.
    for n in CHORDS[0]:
        place(pads, pad_voice(midi(n + 12), DUR - end_at + 1.5), end_at - 0.05, 0.09, pan=rng.uniform(-.5, .5))
    for k, n in enumerate([60, 64, 67, 71, 74, 79]):
        place(keys, e_piano(midi(n + 12), 2.4, 0.8), end_at + 0.05 + k * 0.07, 0.11, pan=(k - 2.5) * 0.15)
    place(bass, sub_bass(midi(36), 2.4), end_at, 0.17)
    place(drums, kick(), end_at, 0.34)
    pads *= side[:, None]
    keys *= (0.6 + 0.4 * side)[:, None]
    pads = np.stack([highpass(pads[:, c], 180) for c in range(2)], 1)
    mixb = reverb(pads, 2.4, 3500, 0.45) + reverb(keys, 1.8, 6000, 0.3) * 1.5 + reverb(drums, 0.8, 6000, 0.12) + bass
    # Keep the low end tidy: nothing under 35 Hz, and a gentle dip in the 200 Hz mud.
    mixb = np.stack([highpass(mixb[:, c], 35) - 0.25 * bandpass(mixb[:, c], 150, 320) for c in range(2)], 1)[:N]
    # The very end fades out; the very start fades in over a beat.
    fade = np.ones(N)
    fade[:int(0.25 * SR)] = np.linspace(0, 1, int(0.25 * SR))
    fade[-int(1.2 * SR):] *= np.linspace(1, 0, int(1.2 * SR)) ** 1.5
    return mixb * fade[:, None]


# ----------------------------------------------------------------- sfx -----
def glass_tone(f, dur, decay, partials=((1, 1), (2.76, .35), (5.4, .12))):
    """A struck glass body: inharmonic partials, each with its own decay."""
    t = t_axis(dur)
    return sum(a * np.sin(2 * np.pi * f * r * t) * np.exp(-t * decay * (1 + r * 0.6)) for r, a in partials)


def sfx_press():
    t = t_axis(0.03)
    return highpass(rng.standard_normal(len(t)), 3000) * np.exp(-t * 400) * 0.35 + np.sin(2 * np.pi * 1800 * t) * np.exp(-t * 300) * 0.1


def sfx_click():
    """A crisp trackpad-style click: two very short transients, the second softer."""
    t = t_axis(0.06)
    one = bandpass(rng.standard_normal(len(t)), 1500, 9000) * np.exp(-t * 520)
    tone = np.sin(2 * np.pi * 2300 * t) * np.exp(-t * 260) * 0.35
    out = one + tone
    out[int(0.011 * SR):] += (one * 0.45)[:len(out) - int(0.011 * SR)]
    return out * 0.8


def sfx_pop(style):
    if style == 'liquid':
        # A drop into water: a rising bubble tone with a glassy shimmer on top.
        t = t_axis(0.55)
        f = 520 * (1 + 0.75 * (1 - np.exp(-t * 28)))
        bub = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 13)
        return bub * 0.55 + glass_tone(1760, 0.55, 9) * 0.16 + glass_tone(2640, 0.55, 12) * 0.08
    if style == 'donut':
        # A heavier glass object set down: low thunk plus a ringing rim.
        t = t_axis(0.8)
        thunk = np.sin(2 * np.pi * (160 + 120 * np.exp(-t * 40)) * t) * np.exp(-t * 18) * 0.6
        return thunk + glass_tone(1320, 0.8, 4.5) * 0.28 + glass_tone(1980, 0.8, 6) * 0.12
    # Capsule: a quick soft pill pop.
    t = t_axis(0.25)
    f = 700 + 500 * (1 - np.exp(-t * 60))
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 22) * 0.55 + glass_tone(2100, 0.25, 16) * 0.1


def sfx_tick():
    t = t_axis(0.05)
    return np.sin(2 * np.pi * 3200 * t) * np.exp(-t * 160) * 0.22 + highpass(rng.standard_normal(len(t)), 6000) * np.exp(-t * 500) * 0.05


def sfx_unfold():
    out = np.zeros(int(0.6 * SR))
    for k, n in enumerate((84, 88, 91)):
        x = glass_tone(midi(n), 0.6 - k * 0.045, 7) * 0.22
        i = int(k * 0.045 * SR)
        out[i:i + len(x)] += x[:len(out) - i]
    return out


def sfx_panel():
    """The panel sliding in: a short airy swish rising into a soft tone."""
    t = t_axis(0.32)
    n = rng.standard_normal(len(t))
    sweep = np.zeros(len(t))
    for k in range(0, len(t), 480):
        f = 900 + 3800 * (k / len(t))
        seg = bandpass(n[k:k + 960], f * 0.7, min(f * 1.4, 20000))
        sweep[k:k + len(seg)] += seg[:len(sweep) - k] * np.hanning(len(seg))[:len(sweep) - k]
    shape = np.sin(np.pi * np.clip(t / 0.28, 0, 1)) ** 2
    return sweep * shape * 0.22 + glass_tone(1568, 0.32, 10) * np.clip((t - 0.1) * 10, 0, 1) * 0.07


def sfx_type(dur):
    """Text streaming in: soft, slightly irregular key taps."""
    out = np.zeros(int((dur + 0.1) * SR))
    at = 0.0
    while at < dur:
        t = t_axis(0.03)
        tap = bandpass(rng.standard_normal(len(t)), 2500, 8000) * np.exp(-t * 350) * rng.uniform(0.05, 0.11)
        i = int(at * SR)
        out[i:i + len(tap)] += tap[:len(out) - i]
        at += rng.uniform(0.045, 0.085)
    return out


def sfx_replace():
    """Text swapped in place: a bright upward shimmer resolving on a chime."""
    t = t_axis(0.9)
    out = np.zeros(len(t))
    for k, n in enumerate((79, 83, 86, 91, 95)):
        x = glass_tone(midi(n), 0.9 - k * 0.04, 6) * (0.12 + 0.02 * k)
        i = int(k * 0.04 * SR)
        out[i:] += x[:len(out) - i]
    air = highpass(rng.standard_normal(len(t)), 5000) * np.exp(-t * 9) * np.clip(t * 20, 0, 1) * 0.05
    return out + air


def sfx_whoosh():
    """Scene change: band-passed noise swelling and passing, centre frequency gliding."""
    d = 0.55
    t = t_axis(d)
    n = rng.standard_normal(len(t))
    out = np.zeros(len(t))
    for k in range(0, len(t), 480):
        f = 400 + 2600 * np.sin(np.pi * k / len(t))
        seg = bandpass(n[k:k + 960], f * 0.6, f * 1.6)
        out[k:k + len(seg)] += seg[:len(out) - k] * np.hanning(len(seg))[:len(out) - k]
    shape = np.sin(np.pi * t / d) ** 3
    st = np.stack([out * shape * (1 - t / d * 0.6), out * shape * (0.4 + t / d * 0.6)], 1)
    return st * 0.28


def sfx_logo():
    """The end card: a warm bell chord with a long tail."""
    t = t_axis(2.4)
    out = np.zeros(len(t))
    for k, n in enumerate((72, 76, 79, 84)):
        out += glass_tone(midi(n), 2.4, 1.6, ((1, 1), (2.0, .25), (3.01, .1))) * 0.13 * np.clip((t - k * 0.03) * 400, 0, 1)
    return out


def sfx():
    bus = np.zeros((N + SR * 3, 2))
    for c in CUES['sfx']:
        k, at = c['kind'], c['t']
        if k == 'press':
            place(bus, sfx_press(), at, 0.5, pan=-.1)
        elif k == 'release':
            place(bus, sfx_press(), at, 0.35, pan=-.1)
        elif k == 'click':
            place(bus, sfx_click(), at, 0.85, pan=.1)
        elif k == 'pop':
            place(bus, sfx_pop(c['style']), at, 0.8)
        elif k == 'tick':
            place(bus, sfx_tick(), at, 0.8, pan=rng.uniform(-.3, .3))
        elif k == 'unfold':
            place(bus, sfx_unfold(), at, 0.9)
        elif k == 'panel':
            place(bus, sfx_panel(), at, 0.9)
        elif k == 'type':
            place(bus, sfx_type(c['dur']), at, 0.9, pan=.05)
        elif k == 'replace':
            place(bus, sfx_replace(), at, 0.8)
        elif k == 'whoosh':
            place(bus, sfx_whoosh(), at - 0.3, 1.0)
        elif k == 'logo':
            place(bus, sfx_logo(), at, 0.9)
    return reverb(bus, 1.1, 7000, 0.18)[:N]


# --------------------------------------------------------------- voice -----
def voice():
    v = CUES['voice']
    src = os.path.join(HERE, 'capture/takes', v['take'] + '.mov')
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-ss', str(v['takeFrom']), '-t', str(v['takeTo'] - v['takeFrom']),
                          '-i', src, '-map', '0:a', '-f', 'f32le', '-ac', '2', '-ar', str(SR), '-'],
                         capture_output=True, check=True).stdout
    x = np.frombuffer(raw, np.float32).reshape(-1, 2).astype(np.float64)
    bus = np.zeros((N, 2))
    place(bus, x, v['film'])
    return bus


# ----------------------------------------------------------------- mix -----
def read_audio(path):
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-f', 'f32le', '-ac', '2', '-ar', str(SR), '-'],
                         capture_output=True, check=True).stdout
    x = np.frombuffer(raw, np.float32).reshape(-1, 2).astype(np.float64)
    return np.pad(x, ((0, max(0, N - len(x))), (0, 0)))[:N]


def save(path, x):
    # 16-bit PCM: what every editor opens, at half the size of float.
    wavfile.write(path, SR, (np.clip(x, -1, 1) * 32767).round().astype(np.int16))


def rms_db(x):
    return 20 * np.log10(np.sqrt(np.mean(x ** 2)) + 1e-12)


def mix(music_x, sfx_x, voice_x):
    # Music sits under everything; it dips 7 dB while the voice speaks.
    level = np.abs(voice_x).max(1)
    active = signal.convolve(level > 0.01, np.ones(int(0.25 * SR)), 'same') > 0
    duck = 1 - 0.55 * lowpass(active.astype(float), 6, 1)
    m = music_x * 10 ** ((-21 - rms_db(music_x)) / 20) * duck[:, None]
    s = sfx_x * (0.5 / (np.abs(sfx_x).max() + 1e-9))
    v = voice_x * (0.85 / (np.abs(voice_x).max() + 1e-9))
    out = m + s + v
    # Bring the loudest moment to -1 dBFS, then soft-clip only what pokes above
    # -3 dBFS (a tanh knee), so the body of the mix is untouched.
    out = out * (0.89 / max(np.abs(out).max(), 1e-9))
    knee = 0.7
    mag = np.abs(out)
    over = mag > knee
    out[over] = np.sign(out[over]) * (knee + (1 - knee) * np.tanh((mag[over] - knee) / (1 - knee)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--music', help='use this audio file as the music stem')
    ap.add_argument('--mix-only', action='store_true', help='remix the stems already in assets/audio')
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    p = {k: os.path.join(OUT, k + '.wav') for k in ('music', 'sfx', 'voice', 'mix')}
    if a.mix_only or a.music:
        m = read_audio(a.music) if a.music else read_audio(p['music'])
        s, v = read_audio(p['sfx']), read_audio(p['voice'])
    else:
        m, s, v = music(), sfx(), voice()
        save(p['music'], m * (0.7 / np.abs(m).max()))
        save(p['sfx'], s * (0.7 / np.abs(s).max()))
        save(p['voice'], v)
    out = mix(m, s, v)
    save(p['mix'], out)
    print(f'mix: {DUR}s stereo {SR} Hz, peak {20*np.log10(np.abs(out).max()):.1f} dBFS, rms {rms_db(out):.1f} dBFS'
          + (f' (music from {a.music})' if a.music else ''))


if __name__ == '__main__':
    main()
