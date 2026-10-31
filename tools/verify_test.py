#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Play a few steps in the simulator and check that the screen equals an independent rendering of the
virtual screen (VSCR/VCOL) plus the virtual sprites - i.e. the tile fast path, the cell scan and the
sprite compositing agree.  Also reports how many cells/tiles each step drew."""
import os, sys, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim_bbc, c64data
U = os.path.join(sim_bbc.ROOT, 'upstream', 'c64')
g = sim_bbc.Game(); L = g.L; c = g.cpu; m = c.m
font = np.frombuffer(c64data.load_font(U), np.uint8).reshape(256, 8); bits = np.unpackbits(font, axis=1).reshape(256, 8, 8)
pal, cmap = c64data.choose_palette(U)
spr = open(os.path.join(U, 'sprites.gfx'), 'rb').read()[2:]
def reference():
    chs = np.frombuffer(bytes(m[L['VSCR']:L['VSCR']+1280]), np.uint8); cos = np.frombuffer(bytes(m[L['VCOL']:L['VCOL']+1280]), np.uint8)
    img = np.zeros((256, 320), np.uint8)
    for i in range(1280):
        r, cc = divmod(i, 40); img[r*8:r*8+8, cc*8:cc*8+8] = np.where(bits[chs[i]] == 1, cmap[cos[i] & 15], 0)
    V, VP = L['VIC'], L['VSPTR']; en = m[V+0x15]
    for n in range(7, -1, -1):
        if not (en >> n) & 1: continue
        X = m[V+2*n] | (((m[V+0x10] >> n) & 1) << 8); Y = m[V+2*n+1]; p = m[VP+n]; mc = (m[V+0x1C] >> n) & 1; col = m[V+0x27+n]
        d = spr[(p-0x90)*64:(p-0x90)*64+63]
        for y in range(21):
            for x in range(24):
                b = d[y*3 + x//8]
                if not mc: q = col if (b >> (7 - x % 8)) & 1 else -1
                else:
                    qq = (b >> (6 - 2*((x//2) % 4))) & 3; q = -1 if qq == 0 else (m[V+0x25], col, m[V+0x26])[qq-1]
                sx, sy = X - 24 + x, Y - 50 + y
                if q >= 0 and 0 <= sx < 320 and 0 <= sy < 256: img[sy, sx] = cmap[q & 15]
    return img
def settle(sec): g.run(int(sec * 2e6))
c.pc = L['START']; c.sp = 0xFF; settle(2)
fails = 0
def check(label):
    global fails
    settle(1.0)
    bad = int((g.decode() != reference()).sum()); fails += bad > 0
    print('%-22s mismatching pixels: %d' % (label, bad))
g.keys.append(13); settle(4); check('level start')
for k in (137, 137, 137, 138, 138, 136, 139, 139, 139, 137, 137):
    g.keys.append(k); settle(0.7)
check('after 11 moves')
# window near the map edges (the 9-tile window may start above the map or end below it): must still draw, and agree
for x, y in ((22, 3), (22, 61), (6, 30), (122, 30)):
    m[0x9540] = x; m[0x9580] = y
    sv = (c.a, c.x, c.y, c.pc, c.p(), c.sp)
    g.call(L['CACULATE_AND_REDRAW']); g.call(L['DRAW_MAP_WINDOW'])
    c.a, c.x, c.y, c.pc, c.sp = sv[0], sv[1], sv[2], sv[3], sv[5]; c.setp(sv[4]); check('window at map (%d,%d)' % (x, y))
sys.exit(1 if fails else 0)
