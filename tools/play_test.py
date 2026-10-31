#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Drive the BBC build in the simulator: intro -> START GAME -> level A, optionally some moves; dump PNGs.
usage: play_test.py [keys...]   keys are OS characters or names: up down left right fire"""
import os, sys, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim_bbc, c64data
from PIL import Image
NAMES = {'up': 139, 'down': 138, 'left': 136, 'right': 137, 'ret': 13, 'space': 32, 'esc': 27}
g = sim_bbc.Game(); L = g.L; c = g.cpu
pal, cmap = c64data.choose_palette(os.path.join(sim_bbc.ROOT, 'upstream', 'c64')); rgb = np.array([c64data.BBC[p] for p in pal], np.uint8)
def shot(name):
    Image.fromarray(rgb[g.decode()]).resize((640, 400), Image.NEAREST).save(os.path.join(sim_bbc.B, 'preview', name))
def settle(sec=1.0): g.run(int(sec * 2_000_000))
c.pc = L['START']; c.sp = 0xFF
settle(2)
seq = sys.argv[1:] or ['ret']
for i, k in enumerate(seq):
    g.keys.append(NAMES.get(k, ord(k) if len(k) == 1 else 0)); settle(1.5 if i == 0 else 0.7)
settle(2); shot('play.png')
print('oscli:', g.oscli_log, 'pc=$%04X ticks=%d' % (c.pc, c.m[L['TICKS']]))
