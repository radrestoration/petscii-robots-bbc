#!/usr/bin/env python3
"""Mode 1 colour trick preview: synthesise more than 4 colours by dithering the lit pixels of a cell between two palette
colours (checkerboard by pixel parity), per C64 colour.  Compares the solid-colour build with the dithered version, with a
CRT-like horizontal blur on the right.  Writes build/preview/dither_*.png.   usage: dither_preview.py [level letter]"""
import os, sys, itertools, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import c64data
from PIL import Image, ImageFilter, ImageDraw
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); U = f'{R}/upstream/c64'; O = f'{R}/build/preview'
level = (sys.argv[1] if len(sys.argv) > 1 else 'A').upper()
BBC, C64 = c64data.BBC.astype(float), c64data.C64.astype(float)
chars, cols = c64data.tile_tables(c64data.load_tileset(U)); font = np.frombuffer(c64data.load_font(U), np.uint8).reshape(256, 8)
bits = np.unpackbits(font, axis=1).reshape(256, 8, 8)
lv = open(f'{R}/build/data/level{level}.bin', 'rb').read(); mp = np.frombuffer(lv[0x300:], np.uint8).reshape(64, 128); px, py = lv[0x40], lv[0x80]
x0, y0 = min(max(px - 5, 0), 128 - 11), min(max(py - 3, 0), 64 - 7)
use = np.zeros(16); win = mp[y0:y0+7, x0:x0+11]
for t in set(win.flatten()):
    for k in range(9):
        if bits[chars[k][t]].any(): use[cols[k][t] & 15] += bits[chars[k][t]].sum() * (win == t).sum()
def lab(rgb):                                   # sRGB (0-255) -> CIE L*a*b* (D65); mixes are averaged in linear light
    c = np.asarray(rgb, float) / 255; c = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    xyz = c @ np.array([[0.4124, 0.2126, 0.0193], [0.3576, 0.7152, 0.1192], [0.1805, 0.0722, 0.9505]]) / np.array([0.9505, 1.0, 1.089])
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116); return np.array([116 * f[1] - 16, 500 * (f[0] - f[1]), 200 * (f[1] - f[2])])
def lin(rgb):
    c = np.asarray(rgb, float) / 255; return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
def delin(c): c = np.clip(c, 0, 1); return 255 * np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)
def err(c, mix): return ((lab(C64[c]) - lab(mix)) ** 2).sum()
def mixrgb(p, q): return delin((lin(p) + lin(q)) / 2)
def plan(palette, dither):
    """per C64 colour: (colour a, colour b) palette indices (a == b solid); returns plan and weighted error"""
    P = BBC[palette]; out = []; total = 0
    for c in range(16):
        best = min(((err(c, P[a]), a, a) for a in range(4)), key=lambda t: t[0])
        if dither:
            for a, b in itertools.combinations(range(4), 2):
                e = err(c, mixrgb(P[a], P[b]))
                if e < best[0]: best = (e, a, b)
        out.append(best[1:]); total += use[c] * best[0]
    return out, total
def best_palette(dither):
    return min(((plan([0, *s], dither)[1], [0, *s]) for s in itertools.combinations(range(1, 8), 3)), key=lambda t: t[0])
def render(palette, pl):
    P = BBC[palette].astype(np.uint8); img = np.zeros((7*24, 11*24, 3), np.uint8)
    for ty in range(7):
        for tx in range(11):
            t = win[ty, tx]
            for k in range(9):
                cy, cx = divmod(k, 3); c = cols[k][t] & 15; a, b = pl[c]; g = bits[chars[k][t]]
                for y in range(8):
                    for x in range(8):
                        if g[y, x]: img[ty*24 + cy*8 + y, tx*24 + cx*8 + x] = P[a if (x + y) % 2 == 0 else b]
    return img
def show(img, name, blur):
    im = Image.fromarray(img).resize((11*24*3, 7*24*3), Image.NEAREST)           # 3x: pixels clearly visible
    if blur: im = im.filter(ImageFilter.GaussianBlur(2.0))
    im.save(f'{O}/{name}.png'); return im
e0, p0 = best_palette(False); e1, p1 = best_palette(True)
pl0, _ = plan(p0, False); pl1, _ = plan(p1, True)
print('solid  palette', p0, 'error %.0f' % e0); print('dither palette', p1, 'error %.0f (%.0f%% of solid)' % (e1, 100*e1/e0))
print('dither pairs per C64 colour:', [(i, pl1[i]) for i in range(16) if use[i] > 0])
a = show(render(p0, pl0), 'dither_solid', False); b = show(render(p1, pl1), 'dither_dithered', False)
ab = show(render(p0, pl0), 'dither_solid_blur', True); bb = show(render(p1, pl1), 'dither_dithered_blur', True)
W, H = a.size; sheet = Image.new('RGB', (W*2, H*2 + 60), (40, 40, 40)); d = ImageDraw.Draw(sheet)
for i, (lab, im) in enumerate([('solid colours (current)', a), ('dithered pairs', b), ('solid, CRT-ish blur', ab), ('dithered, CRT-ish blur', bb)]):
    x, y = (i % 2) * W, (i // 2) * (H + 30); d.text((x + 8, y + 8 + (0 if i < 2 else 0)), lab, fill=(255, 255, 255)); sheet.paste(im, (x, y + 24))
sheet.save(f'{O}/dither_comparison.png'); print('ok')
