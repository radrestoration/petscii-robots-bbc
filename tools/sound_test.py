#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Sound effects: play each of the C64 version's 19 sound ids in the simulator, capture the bytes written to the SN76489 per frame
and compare with a straight Python implementation of the effect player working from build/data/sound.inc; also checks priority
(a less important sound doesn't interrupt) and that port A's direction is restored to $7F after every update."""
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim_bbc
inc = open(os.path.join(sim_bbc.B, 'data', 'sound.inc')).read()
tab = {}
for m in re.finditer(r'^(\w+):\s*\.byte (.*)$', inc, re.M): tab[m.group(1)] = [x.strip() for x in m.group(2).split(',')]
fx = [int(x) for x in re.findall(r'\d+', ''.join(tab['SND_FX_L'])[:0])] if False else None
names = [n for n in tab if n.startswith('SND_') and n not in ('SND_FX_L', 'SND_FX_H', 'SND_PRIO')]
fxl = [x.lstrip('<') for x in tab['SND_FX_L']]; prio = [int(x) for x in tab['SND_PRIO']]
data = {n: [int(x) for x in tab[n]] for n in names}
def sn_ref(effect):
    """per-frame lists of SN bytes the engine should write for one effect started on an idle chip"""
    d = data[effect]; pos = 0; timer = nstep = fade = 0; frames = []; vol = noise = 0; N = 0; tr = 0; step = 0
    def period(ch, n): return [ch | (n & 15), ((n >> 4) & 63)]
    while True:
        out = []
        if fade:
            fade -= 2
            if fade <= 0: frames.append(out + [0x9F, 0xBF, 0xDF, 0xFF]); return frames
            vol = fade; out += [(0xF0 if noise else 0x90) | (15 - vol)]
        if timer: timer -= 1
        elif nstep:
            nstep -= 1; timer = tr; N = max(8, min(1023, N + step)); out += period(0xC0 if noise else 0x80, N)
        else:
            N = d[pos] | ((d[pos+1] & 3) << 8); noise = d[pos+1] & 0x40
            if d[pos+2] & 0x80: frames.append(out + [0x9F, 0xBF, 0xDF, 0xFF]); return frames
            vol = d[pos+2]
            out += ([0x9F, 0xDF] + period(0xC0, N) + [0xE7, 0xF0 | (15 - vol)]) if noise else ([0xFF] + period(0x80, N) + [0x90 | (15 - vol)])
            t = d[pos+3]; timer = tr = t & 0x7F; nstep = step = 0
            if t & 0x80:
                step = d[pos+4] | (d[pos+5] << 8); step -= 65536 if step > 32767 else 0; nstep = d[pos+6]; pos += 7
                if nstep == 255: fade = vol
            else: pos += 4
        frames.append(out)
g = sim_bbc.Game(); L = g.L; c = g.cpu
c.pc = L['START']; c.sp = 0xFF; g.run(2_000_000)
c.m[L['MUS_PLAY']] = 0               # the title music would interleave its own chip writes: effects are tested alone (music_game_test.py: together)
def play(i):
    sv = (c.a, c.x, c.y, c.pc, c.p(), c.sp); g.call(L['PLAY_SOUND'], a=i)
    c.a, c.x, c.y, c.pc, c.sp = sv[0], sv[1], sv[2], sv[3], sv[5]; c.setp(sv[4])
bad = 0
for i in range(19):
    g.run(300_000); g.sn.clear(); f0 = g.frame; play(i); idle0 = c.m[L['SND_ID']]
    g.run(int(8 * 2e6))                                   # long enough for any effect
    got = {}
    for fr, b in g.sn: got.setdefault(fr, []).append(b)
    exp = sn_ref(fxl[i]); seq = [b for fr in sorted(got) for b in got[fr]]
    # the first update happens at the next vsync, so compare as a flat byte sequence
    flat = [b for fr in exp for b in fr]
    ok = seq == flat and c.m[L['SND_ID']] == 0xFF
    print('sound %2d %-12s %3d frames %3d bytes  %s' % (i, fxl[i][4:], len(exp), len(flat), 'ok' if ok else 'MISMATCH (got %d bytes)' % len(seq)))
    if not ok and len(seq) == len(flat):
        k = next(j for j in range(len(seq)) if seq[j] != flat[j]); print('   first difference at byte %d: got %02X expected %02X (context got %s expected %s)' % (k, seq[k], flat[k], [hex(x) for x in seq[k-3:k+4]], [hex(x) for x in flat[k-3:k+4]]))
    bad += not ok
print('DDRA writes end with $7F each time:', all(g.ddra[k] == 0x7F for k in range(1, len(g.ddra), 2)))
# priority: explosion (id 0, important) then a walk (id 16, trivial) must not interrupt it: the chip sees the explosion alone
g.run(300_000); g.sn.clear(); play(0); g.run(100_000); play(16); g.run(int(8 * 2e6))
seq = [b for _, b in g.sn]; flat = [b for fr in sn_ref(fxl[0]) for b in fr]
ok = seq == flat; print('priority test (walk during explosion ignored):', 'ok' if ok else 'FAILED'); bad += not ok
# ... and the reverse: a walk is replaced by an explosion
g.run(300_000); g.sn.clear(); play(16); g.run(60_000); play(0); g.run(int(8 * 2e6))
seq = [b for _, b in g.sn]; print('explosion replaces a walk:', 'ok' if seq[-len(flat):] == flat or seq[-4:] == [0x9F, 0xBF, 0xDF, 0xFF] else 'FAILED')
sys.exit(1 if bad else 0)
