#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Boot the BBC build in the simulator: START -> HAL init -> intro screen; dump the screen to build/preview/."""
import os, sys, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim_bbc, c64data
from PIL import Image
g = sim_bbc.Game(); L = g.L; c = g.cpu
c.pc = L['START']; c.sp = 0xFF
secs = float(sys.argv[1]) if len(sys.argv) > 1 else 3
g.run(int(secs * 2_000_000))
print('pc=$%04X cycles=%d ticks=%d' % (c.pc, c.cycles, c.m[L['TICKS']]))
print('vdu:', g.vdu[:20], ' oscli:', g.oscli_log)
got = g.decode()
pal, cmap = c64data.choose_palette(os.path.join(sim_bbc.ROOT, 'upstream', 'c64'))
rgb = np.array([c64data.BBC[p] for p in pal], np.uint8)
os.makedirs(os.path.join(sim_bbc.B, 'preview'), exist_ok=True)
Image.fromarray(rgb[got]).resize((640, 400), Image.NEAREST).save(os.path.join(sim_bbc.B, 'preview', 'intro.png'))
