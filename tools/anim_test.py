#!/usr/bin/env python3
"""The animated tiles (water, fans, server lights, trash compactor) are cached one image per animation phase (make_data.py:
TILEKIND/TSLOT, HAL_TILE_KEY/HAL_ANIM_STEP in hal_main.s).  Checks, in the headless simulator:
  1. every tile of kind 2 / 3 really repeats with period 3 / 2 under the game's own ANIMATE_WATER, starting from its initial
     state (the phase counters start at 0 and the cache is keyed by them);
  2. in a water-rich window of level A, over 8 animation steps, the screen (drawn from the cache) equals an independent rendering
     of the virtual screen (which the game's PLOT_TILE fills from the current tile data) - so no stale or wrong-phase image is shown;
  3. how much display work a redraw takes with the phase cache against the old behaviour (animated tiles drawn cell by cell)."""
import os, sys, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim_bbc
src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'verify_test.py')).read()
exec(src[:src.index('def settle')].replace("sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))", ''))   # g, L, c, m, reference()
def settle(sec): g.run(int(sec * 2e6))
c.pc = L['START']; c.sp = 0xFF; settle(2)
fails = 0
def callsafe(addr):
    sv = (c.a, c.x, c.y, c.pc, c.p(), c.sp); g.call(addr)
    c.a, c.x, c.y, c.pc, c.sp = sv[0], sv[1], sv[2], sv[3], sv[5]; c.setp(sv[4])
# 1. the cache key is a function of the phase counters: whenever they have the same values, the animated tiles' data is the same
#    (and it repeats with period 3 / 2 under the game's own ANIMATE_WATER)
kind = [m[L['TILEKIND'] + i] for i in range(256)]
def snap(i): return tuple(m[0x8200 + k * 256 + i] for k in range(18))          # TILE_DATA_TL..BR, TILE_COLOR_TL..BR
ids = [i for i in range(256) if kind[i] >= 2]
seen = {}; imgs = {i: set() for i in ids}
for n in range(14):
    key = (m[L['KPHASE'] + 2], m[L['KPHASE'] + 3])
    for i in ids:
        k = (key[0] if kind[i] == 2 else key[1], i); s_ = snap(i)
        if seen.setdefault(k, s_) != s_: fails += 1; print('tile %d: same phase, different data' % i)
        imgs[i].add(s_)
    m[L['WATER_TIMER']] = 19; callsafe(L['ANIMATE_WATER'])
for i in ids:
    if len(imgs[i]) != (3 if kind[i] == 2 else 2): fails += 1; print('tile %d: %d images, expected %d' % (i, len(imgs[i]), 3 if kind[i] == 2 else 2))
print('phase keys: %d animated tiles (kind 2: %s, kind 3: %s): %s' % (len(ids), [i for i in ids if kind[i] == 2], [i for i in ids if kind[i] == 3], 'ok' if not fails else 'FAIL'))
# 2. a water-rich window of level A (window = 11x9 tiles around the player)
lv = open(os.path.join(sim_bbc.B, 'data', 'levelA.bin'), 'rb').read(); mp = np.frombuffer(lv[0x300:], np.uint8).reshape(64, 128)
best = max(((int((mp[y - 4:y + 5, x - 5:x + 6] == 204).sum()), x, y) for y in range(8, 56) for x in range(8, 120)))
print('water-rich window: %d of 99 tiles are water, around map (%d,%d)' % best)
g.keys.append(13); settle(4)
def jump(x, y):
    m[0x9540] = x; m[0x9580] = y
    sv = (c.a, c.x, c.y, c.pc, c.p(), c.sp); g.call(L['CACULATE_AND_REDRAW']); g.call(L['DRAW_MAP_WINDOW'])
    c.a, c.x, c.y, c.pc, c.sp = sv[0], sv[1], sv[2], sv[3], sv[5]; c.setp(sv[4])
jump(best[1], best[2])
for n in range(8):
    m[L['ANIMATE']] = 1; settle(0.45)                     # (an animation step every 20 frames = 0.4 s), then freeze it so the redraw can finish
    m[L['ANIMATE']] = 0; settle(0.6)
    bad = int((g.decode() != reference()).sum()); fails += bad > 0
    print('step %d (phases %d,%d): mismatching pixels %d' % (n, m[L['KPHASE'] + 2], m[L['KPHASE'] + 3], bad))
# 3. what the player feels: the latency of a scroll step (key press -> last tile/cell drawn) in that water-rich window, as in
#    step_timing.py, with the animation running
def step(x, y, window=1_500_000):
    """move the window to map (x,y) as a scroll step does (the player moved), then count how long the screen takes to be drawn"""
    jump(x, y); t0 = c.cycles; last = t0; blits = cells = 0; end = t0 + window
    d = [L['DRAWIDX_%d' % i] for i in range(5)]
    while c.cycles < end:
        pc = c.pc
        if pc == L['HAL_BLIT_CRIT']: blits += 1; last = c.cycles
        if pc in d: cells += 1; last = c.cycles
        c.step()
        if c.cycles >= g.next_irq and not c.i:
            g.next_irq += 40000
            if c.m[0x220] | (c.m[0x221] << 8) == L['EVT']: g.vsync()
    return last - t0, blits, cells
def scroll(label):
    m[L['ANIMATE']] = 0; jump(best[1], best[2]); settle(1.0)       # (animation off: just the cost of drawing the scrolled window)
    r = [step(best[1] + dx, best[2] + dy) for dx, dy in ((1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1), (0, 0))]
    av = sum(x[0] for x in r) / len(r) / 2000
    print('scroll steps over water, %-22s: average latency %5.0f ms   (tiles %2.0f, cells %3.0f per step)' % (label, av, sum(x[1] for x in r) / len(r), sum(x[2] for x in r) / len(r)))
    return av
# ... and the stall every 20 frames when the animation advances: cycles from the phase change until the screen has caught up (the end
# of the first burst of tile/cell drawing, a burst ending at a gap of 150000 cycles without any)
def anim_stall():
    d = [L['DRAWIDX_%d' % i] for i in range(5)]; ph0 = m[L['KPHASE'] + 2]; t0 = c.cycles; done = None; last = None; blits = cells = 0
    while c.cycles < t0 + 4_000_000:
        pc = c.pc
        if done is not None:
            if pc == L['HAL_BLIT_CRIT']: blits += 1; last = c.cycles
            if pc in d: cells += 1; last = c.cycles
            if last is not None and c.cycles - last > 150_000: break
        c.step()
        if c.cycles >= g.next_irq and not c.i:
            g.next_irq += 40000
            if c.m[0x220] | (c.m[0x221] << 8) == L['EVT']: g.vsync()
        if done is None and m[L['KPHASE'] + 2] != ph0: done = c.cycles
    return (last - done) / 2000, blits, cells
def stall(label):
    m[L['ANIMATE']] = 1; jump(best[1], best[2]); settle(1.0); anim_stall()
    r = [anim_stall() for _ in range(5)]
    av = sum(x[0] for x in r) / len(r)
    print('animation step in the window, %-22s: screen caught up after %4.0f ms (%3.0f tiles, %4.0f cells drawn)' % (label, av, sum(x[1] for x in r) / len(r), sum(x[2] for x in r) / len(r)))
    return av
new_ = scroll('cached phases'); snew = stall('cached phases')
for i in ids: m[L['TILEKIND'] + i] = 1; m[0x9400 + i] = 255          # (the old behaviour: animated tiles are never cached, drawn cell by cell)
old_ = scroll('never cached (before)'); sold = stall('never cached (before)')
fails += new_ >= old_ or snew >= sold
sys.exit(1 if fails else 0)
