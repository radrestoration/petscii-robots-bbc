#!/usr/bin/env python3
"""Overview map (f7): boot to level A, press f7, check the 128x64 picture (one white pixel per tile that can't be walked on,
plus the blinking player dot) against the map data, return to the game.  Writes build/preview/map*.png."""
import os, sys, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim_bbc, c64data
from PIL import Image
g = sim_bbc.Game(); L = g.L; c = g.cpu; m = c.m
U = os.path.join(sim_bbc.ROOT, 'upstream', 'c64')
pal, cmap = c64data.choose_palette(U); rgb = np.array([c64data.BBC[p] for p in pal], np.uint8)
ts = open(os.path.join(sim_bbc.B, 'data', 'tiles.bin'), 'rb').read(); attr = np.frombuffer(ts[256:512], np.uint8)
lv = open(os.path.join(sim_bbc.B, 'data', 'levelA.bin'), 'rb').read(); mp = np.frombuffer(lv[0x300:], np.uint8).reshape(64, 128)
walls = ((attr[mp] & 1) == 0)
px, py = lv[0x40], lv[0x80]
def settle(sec): g.run(int(sec * 2e6))
def shot(name): Image.fromarray(rgb[g.decode()]).resize((640, 512), Image.NEAREST).save(os.path.join(sim_bbc.B, 'preview', name))
def block():                                   # screen pixels of the map block: cells (12,2), 16 x 8 -> 128 x 64 logical colours
    return g.decode()[(3 + 2) * 8:(3 + 2 + 8) * 8, 12 * 8:28 * 8]   # +3 rows: the 25-row screen is centred (start row 29)
c.pc = L['START']; c.sp = 0xFF; settle(2); g.keys.append(13); settle(4)
fails = 0
g.keys.append(int(os.environ.get('MAPKEY', 199))); settle(3); shot('map1.png')            # f7 (OS code 199 -> PETSCII 136)
b = block(); white = pal.index(7) if 7 in pal else 3
ref = walls.copy()
for dy, dx in ((0, 0), (0, 1), (1, 1), (1, 0)):             # the player's 2x2 dot may be on or off: compare away from it
    pass
mask = np.ones_like(ref); mask[py:py+2, px:px+2] = False
bad = int(((b == white) != ref)[mask].sum()); print('map picture: %d wrong pixels of %d (walls: %d)' % (bad, int(mask.sum()), int(ref.sum()))); fails += bad > 0
# the dot blinks: sample the 2x2 at the player over a couple of seconds
seen = set()
for _ in range(40):
    settle(0.1); d = block()[py:py+2, px:px+2]; seen.add(int((d == white).sum()))
print('player dot lit-pixel counts seen:', sorted(seen)); fails += not ({0, 4} <= seen)
g.keys.append(13); settle(5); shot('map2.png')              # any other key returns to the game
print('back in game: pc=$%04X' % c.pc)
sys.exit(1 if fails else 0)
