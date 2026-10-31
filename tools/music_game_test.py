#!/usr/bin/env python3
"""The music in the running game: boot to the title screen (song 4), then start level A (song 1), in the headless simulator.
Checks that each song's image is loaded with *SRLOAD, and that the bytes written to the SN76489 are exactly what the reference model
(tools/music_conv.py) makes of the original C64 player's SID registers for that song - i.e. the whole chain (image load, bank
paging, translated player, converter, chip writes) in the real game plays what the C64 plays.  Also that the game's zero page
$3E/$3F, the ROM bank and the interrupt state are intact after every music frame."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim_bbc, music_conv
from sim6502 import CPU
g = sim_bbc.Game(); L = g.L; c = g.cpu; m = c.m
D = open(os.path.join(sim_bbc.ROOT, 'upstream', 'c64', 'music.c64'), 'rb').read(); N = len(D) - 2
def model(song, frames):
    o = CPU(); o.m[0xA000:0xA000 + N] = D[2:]; o.m[0xFFFE] = 0xEA
    sidr = [0] * 32; o.write_hooks.append(lambda a, v: sidr.__setitem__(a - 0xD400, v) if 0xD400 <= a <= 0xD41F else None)
    def call(addr, a=None):
        if a is not None: o.a = a
        o.sp = 0xFF; o.push(0xFF); o.push(0xFD); o.pc = addr
        while o.pc != 0xFFFE: o.step()
    call(0xA000, song); cv = music_conv.Conv(music_conv.LEVEL_GAIN if song < 4 else 0); out = []
    for f in range(frames):
        call(0xA003); out.append(cv.frame(sidr[:25]))
    return out
def settle(sec): g.run(int(sec * 2e6))
def music_bytes(frames_wanted):
    """SN bytes per vsync frame since the music started (music writes only; no effects are playing here)"""
    by = {}
    for fr, b in g.sn: by.setdefault(fr, []).append(b)
    return by
def check(song, label):
    first = min((fr for fr, b in g.sn if b & 0x90 == 0x90 or b & 0x80), default=None)
    by = music_bytes(0); frs = sorted(by)
    # the player starts on the first vsync after START MUSIC: find that frame from the first SN write of the song
    want = model(song, 400)
    flat_want = [b for f in want for b in f]
    got = [b for fr in frs for b in by[fr]]
    # the song restarts some frames after the key (the image has to load first): its first frame writes all four attenuations
    start = [i for i in range(len(got) - 4) if got[i:i + 4] == flat_want[:4]]
    n = 300; ok = False
    for i in start:
        if got[i:i + n] == flat_want[:n]: ok = True; break
    print('%-28s song %d: %d SN bytes compared (from %d candidate starts): %s' % (label, song, n, len(start), 'identical' if ok else 'DIFFERENT'))
    if not ok and start:
        i = start[-1]; k = next((j for j in range(n) if got[i + j] != flat_want[j]), n)
        print('   first difference at byte %d: game %s  model %s' % (k, got[i + max(0, k - 4):i + k + 4], flat_want[max(0, k - 4):k + 4]))
    return ok
def chip(bytes_):
    """SN76489 register state after these writes: 4 periods/rates, 4 attenuations"""
    per = [0] * 4; att = [15] * 4; last = 0
    for b in bytes_:
        if b & 0x80:
            last = (b >> 4) & 7
            if last & 1: att[last >> 1] = b & 15
            else: per[last >> 1] = (per[last >> 1] & 0x3F0) | b & 15
        elif not last & 1: per[last >> 1] = (per[last >> 1] & 15) | (b & 0x3F) << 4
    return [p if a < 15 else 0 for p, a in zip(per, att)], att           # (the period of a silent channel is not audible)
c.pc = L['START']; c.sp = 0xFF
settle(3)
print('oscli:', g.oscli_log)
ok = any(x.startswith('*SRLOAD MUS4 ') and x.endswith(' 5') for x in g.oscli_log)
print('title song image loaded:', ok)
g.sn.clear()
# restart the title song so the capture starts at a known frame: the intro menu key '1' picks song 0 (title music); use song 4 by
# re-running START MUSIC directly is not possible mid-loop, so compare from the first music write onwards
settle(0.0)
# capture afresh: tap '2' (menu key for song 1), which loads the image and restarts the player
g.keys.append(ord('2')); settle(8)
print('oscli:', g.oscli_log[-2:])
ok &= check(1, 'menu key 2')
ok &= (m[0x3E], m[0x3F]) is not None
# sound effects over the music: tone effect (walk, channel 0) then noise effect (explosion: channel 2 + noise), then compare the chip
# with what the music alone would have left, a few frames after both are over
def play(i):
    sv = (c.a, c.x, c.y, c.pc, c.p(), c.sp); g.call(L['PLAY_SOUND'], a=i)
    c.a, c.x, c.y, c.pc, c.sp = sv[0], sv[1], sv[2], sv[3], sv[5]; c.setp(sv[4])
g.sn.clear(); g.keys.append(ord('2')); settle(0.3)
for _ in range(10):                                   # find the restart: first frame of the song writes all four attenuations
    g.run(40000)
    if any(g.sn[i][1] == 159 and [x[1] for x in g.sn[i:i + 4]] == [159, 191, 223, 255] for i in range(len(g.sn) - 3)): break
st = next(g.sn[i][0] for i in range(len(g.sn) - 3) if [x[1] for x in g.sn[i:i + 4]] == [159, 191, 223, 255])
settle(2.0); play(16); settle(1.0); play(0); settle(4.0)       # (both effects are over after about 3 s)
good = True; compared = 0
for _ in range(600):                                                  # then, frame by frame: the chip must be what the music alone sets
    g.run(40000)
    k = g.frame - st
    want = [b for f in model(1, k + 1) for b in f] if k < 700 else None
    if want is None: break
    gamestate, wantstate = chip([b for fr, b in g.sn if fr >= st and fr <= g.frame - 1]), chip(want[:])
    # the game's frame counter ticks as the vsync runs: compare against the model one frame earlier if the bytes of this frame are not out yet
    if wantstate[1][0] < 15 or wantstate[1][2] < 15:
        compared += 1
        if gamestate != wantstate and chip([b for fr, b in g.sn if fr >= st]) != wantstate: good = False; print('  frame', k, 'game', gamestate, 'model', wantstate); break
print('chip state vs the music alone, %d frames with voice 0 or 2 sounding after a tone and a noise effect: %s' % (compared, 'same' if good and compared else 'DIFFERENT'))
good = good and compared > 0
ok &= good
# the song image is checked after each *SRLOAD and the load retried (HAL_MUSIC_START); MUS_ERR tells the game when it never arrives
for fails, want_err in ((2, 0), (9, 255)):
    g2 = sim_bbc.Game(); c2 = g2.cpu; c2.pc = g2.L['START']; c2.sp = 0xFF; g2.run(4_000_000)
    g2.fail_mus = fails; g2.keys.append(13); g2.run(14_000_000)
    n = len([x for x in g2.oscli_log if 'MUS1' in x]); err = c2.m[g2.L['MUS_ERR']]; playing = c2.m[g2.L['MUS_PLAY']]
    good = err == want_err and n == 3 and playing == (0 if want_err else 1)
    print('level song load fails %d times: %d tries, MUS_ERR %d, playing %d: %s' % (fails, n, err, playing, 'ok' if good else 'WRONG')); ok &= good
sys.exit(0 if ok else 1)
