#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Is the game window the right piece of the map?  After moving (keys) and after jumping the player around, compare the virtual
screen (VSCR/VCOL) of every window tile with the cells of the map tile that should be there (tiles with a unit on them are
skipped).  Catches off-by-one errors in the window origin, the edge-row clamp and the skip-replot shortcut, which the
screen-vs-virtual-screen check in verify_test.py cannot see."""
import os, sys, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim_bbc, c64data
U = os.path.join(sim_bbc.ROOT, 'upstream', 'c64')
ts = c64data.load_tileset(U); chars, cols = c64data.tile_tables(ts)
g = sim_bbc.Game(); L = g.L; c = g.cpu; m = c.m
lv = open(os.path.join(sim_bbc.B, 'data', 'levelA.bin'), 'rb').read(); mp = np.frombuffer(lv[0x300:], np.uint8).reshape(64, 128)
ANIMATED = {20, 21, 22, 143, 148, 196, 197, 200, 201, 204, 221}      # tile data the game rewrites (water, fans...)
def peek(a): return m[a] if g.rom == 4 else g.banks[4][a - 0x8000]
def settle(s): g.run(int(s * 2e6))
def check(label):
    # let any refresh in progress finish and the game idle, then read the game's own idea of the window
    settle(1.0)
    wx = peek(0x28) if False else m[0x28]; wy = m[0x29]               # MAP_WINDOW_X / Y (zero page, always visible)
    vs = bytes(m[L['VSCR']:L['VSCR'] + 1280]); vc = bytes(m[L['VCOL']:L['VCOL'] + 1280])
    pre = [m[0x1D00 + i] for i in range(99)]                           # MAP_PRECALC
    bad = 0
    for ty in range(9):
        for tx in range(11):
            if pre[ty * 11 + tx]: continue                             # a unit is drawn over this tile
            ry = (ty + wy) & 255; ry = 0 if ry >= 128 else ry; my = min(ry, 63)    # rows above/below the map repeat the edge rows
            t = int(mp[my, (tx + wx) & 255 if (tx + wx) < 128 else 0]) if 0 <= tx + wx < 128 else None
            if t is None or t in ANIMATED: continue
            for k in range(9):
                cy, cx = divmod(k, 3); i = (ty * 3 + cy) * 40 + tx * 3 + cx
                if vs[i] != chars[k][t] or (vc[i] & 15) != (cols[k][t] & 15): bad += 1; break
    print('%-28s window (%3d,%3d): %d tiles differ from the map' % (label, wx, wy, bad)); return bad
c.pc = L['START']; c.sp = 0xFF; settle(2); g.keys.append(13); settle(5)
fails = check('level start')
for k, name in ((137, 'right'), (137, 'right'), (138, 'down'), (138, 'down'), (138, 'down'), (136, 'left'), (139, 'up'), (139, 'up'), (139, 'up')):
    g.keys.append(k); settle(0.8); fails += check('after %s' % name) > 0
for x, y in ((22, 4), (22, 3), (22, 60), (5, 30), (60, 20)):
    m[0x9540] = x; m[0x9580] = y
    sv = (c.a, c.x, c.y, c.pc, c.p(), c.sp); g.call(L['CACULATE_AND_REDRAW']); g.call(L['DRAW_MAP_WINDOW'])
    c.a, c.x, c.y, c.pc, c.sp = sv[0], sv[1], sv[2], sv[3], sv[5]; c.setp(sv[4])
    fails += check('player moved to (%d,%d)' % (x, y)) > 0
sys.exit(1 if fails else 0)
