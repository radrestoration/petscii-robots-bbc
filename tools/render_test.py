#!/usr/bin/env python3
"""Cell renderer + software sprites vs an independent Python reference (C64 font/colours -> logical
colours).  Writes build/preview/render_test.png.  usage: render_test.py"""
import os, sys, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim_bbc, c64data
from PIL import Image
U = os.path.join(sim_bbc.ROOT, 'upstream', 'c64')
bbc = sim_bbc.BBC(); L = bbc.L; m = bbc.cpu.m
font = np.frombuffer(c64data.load_font(U), np.uint8).reshape(256, 8)
bits = np.unpackbits(font, axis=1).reshape(256, 8, 8)
pal, cmap = c64data.choose_palette(U)
ts = c64data.load_tileset(U); chars, cols = c64data.tile_tables(ts)
lv = open(os.path.join(sim_bbc.B, 'data', 'levelA.bin'), 'rb').read(); mp = np.frombuffer(lv[0x300:], np.uint8).reshape(64, 128)
VSCR, VCOL = L['VSCR'], L['VCOL']
def ref(chs, cos):
    img = np.zeros((256, 320), np.uint8)
    for i in range(1280):
        r, c = divmod(i, 40); g = bits[chs[i]]
        img[r*8:r*8+8, c*8:c*8+8] = np.where(g == 1, cmap[cos[i] & 15], 0)
    return img
# scene: a level-a map window (tiles drawn like PLOT_TILE) + some text
chs = np.full(1280, 32, np.uint8); cos = np.zeros(1280, np.uint8)
for ty in range(7):
    for tx in range(11):
        t = mp[ty + 20, tx + 40]
        for k in range(9):
            cy, cx = divmod(k, 3); i = (ty*3 + cy)*40 + tx*3 + cx
            chs[i] = chars[k][t]; cos[i] = cols[k][t]
for j, ch in enumerate(b'HELLO PETSCII ROBOTS'): chs[23*40 + 4 + j] = ch - 64 if 65 <= ch <= 90 else ch; cos[23*40 + 4 + j] = 1
m[VSCR:VSCR+1280] = chs.tobytes(); m[VCOL:VCOL+1280] = cos.tobytes()
cyc = bbc.call(L['HAL_REFRESH'])
got = bbc.decode(); exp = ref(chs, cos)
bad = int((got != exp).sum()); print('full redraw: %d cycles (%.0f ms at 2 MHz), mismatching pixels: %d' % (cyc, cyc/2000, bad))
# incremental: change a few cells
chs[100], cos[100] = 5, 1; chs[600], cos[600] = 9, 3
m[VSCR:VSCR+1280] = chs.tobytes(); m[VCOL:VCOL+1280] = cos.tobytes()
cyc = bbc.call(L['HAL_REFRESH']); got = bbc.decode(); exp = ref(chs, cos)
print('2 cells changed: %d cycles, mismatching pixels: %d' % (cyc, int((got != exp).sum())))
palrgb = np.array([c64data.BBC[p] for p in pal], np.uint8)
os.makedirs(os.path.join(sim_bbc.B, 'preview'), exist_ok=True)
Image.fromarray(palrgb[got]).resize((640, 400), Image.NEAREST).save(os.path.join(sim_bbc.B, 'preview', 'render_test.png'))

# ---- sprites composed into cells vs an independent reference compositor ----
spr = open(os.path.join(U, 'sprites.gfx'), 'rb').read()[2:]
def sprite_pixels(p, mc, colour, mc0, mc1):
    """24x21 array of C64 colour or -1 (transparent) for sprite pointer p"""
    d = spr[(p - 0x90)*64:(p - 0x90)*64 + 63]; out = np.full((21, 24), -1, int)
    for y in range(21):
        for x in range(24):
            b = d[y*3 + x//8]
            if not mc:
                if (b >> (7 - x % 8)) & 1: out[y, x] = colour
            else:
                q = (b >> (6 - 2*((x//2) % 4))) & 3
                if q: out[y, x] = (mc0, colour, mc1)[q-1]
    return out
def ref_sprites(base, sprites):
    img = base.copy()
    for n in sorted(sprites, reverse=True):
        p, X, Y, mc, colour, mc0, mc1 = sprites[n]
        px = sprite_pixels(p, mc, colour, mc0, mc1)
        for y in range(21):
            for x in range(24):
                if px[y, x] >= 0:
                    sx, sy = X - 24 + x, Y - 50 + y
                    if 0 <= sx < 320 and 0 <= sy < 256: img[sy, sx] = cmap[px[y, x] & 15]
    return img
V = L['VIC']; VP = L['VSPTR']
sprites = {5: (0xA7, 144, 122, 0, 6, 0, 0), 6: (0xA8, 144, 122, 0, 14, 0, 0), 7: (0xA9, 144, 122, 0, 10, 0, 0),
           1: (0x94, 296, 64, 1, 1, 1, 12), 2: (0x95, 320, 64, 1, 6, 1, 12), 0: (0x90, 48, 74, 0, 7, 0, 0)}
en = 0; mcb = 0; msb = 0
for n, (p, X, Y, mc, colour, mc0, mc1) in sprites.items():
    m[VP+n] = p; m[V+2*n] = X & 255; m[V+2*n+1] = Y; m[V+0x27+n] = colour
    en |= 1 << n; mcb |= mc << n; msb |= (X >> 8) << n
m[V+0x15] = en; m[V+0x1C] = mcb; m[V+0x10] = msb; m[V+0x25] = 1; m[V+0x26] = 12
cyc = bbc.call(L['HAL_REFRESH']); got = bbc.decode()
exp = ref_sprites(ref(chs, cos), sprites)
badspr = int((got != exp).sum()); print('sprites over the scene: %d cycles, mismatching pixels: %d' % (cyc, badspr))
# move the player layers one tile right and the cursor away: old footprints must be repaired
for n in (5, 6, 7): m[V+2*n] = 168
m[V+0x15] = en & ~1
sprites2 = {k: v for k, v in sprites.items() if k != 0}
for n in (5, 6, 7): sprites2[n] = sprites[n][:1] + (168,) + sprites[n][2:]
cyc = bbc.call(L['HAL_REFRESH']); got = bbc.decode(); exp = ref_sprites(ref(chs, cos), sprites2)
badspr2 = int((got != exp).sum()); print('sprites moved: %d cycles, mismatching pixels: %d' % (cyc, badspr2))
Image.fromarray(palrgb[got]).resize((640, 400), Image.NEAREST).save(os.path.join(sim_bbc.B, 'preview', 'render_test_sprites.png'))
sys.exit(1 if (bad or badspr or badspr2) else 0)
