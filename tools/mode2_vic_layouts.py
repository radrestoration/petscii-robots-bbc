#!/usr/bin/env python3
"""Mode 2 layouts in the VIC-20 manner: 8x8-pixel cells (each 8 pixels wide = 4 bytes), VIC-20 tileset/font, 8 colours, no
down-sampling; how many tiles fit?  Mode 2 memory: a cell is 32 bytes, so cols x rows x 32 <= 20480 (the 20 KB shadow screen).
  L1  20 cols x 32 rows (standard Mode 2):           6 x 9 tiles
  L2  22 cols x 29 rows (CRTC widened to 88 chars):  7 x 8 tiles
  L3  25 cols x 25 rows (CRTC overscan to 100 chars, the VIC-20 version's own 25x25): 8 x 7 tiles
Shown with Mode 2 pixels 4:1 wide as on a 4:3 monitor (overscan layouts exceed the nominal 640 px width).  Writes
build/preview/vic_L*.png and vic_layouts.png.   usage: mode2_vic_layouts.py"""
import os, sys, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import c64data
from PIL import Image, ImageDraw
import importlib.util
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); U = f'{R}/upstream'; O = f'{R}/build/preview'
BBC = c64data.BBC; VIC_TO_BBC = [0, 7, 1, 6, 5, 2, 4, 3]
def load_vic():
    ts = open(f'{U}/vic20/tileset.vic', 'rb').read()[2:].ljust(5120, b'\0'); chars, cols = c64data.tile_tables(ts)
    font = np.frombuffer(open(f'{U}/vic20/gfxfont.prg', 'rb').read()[2:2+2048], np.uint8).reshape(256, 8)
    return chars, cols, np.unpackbits(font, axis=1).reshape(256, 8, 8)
chars, cols, glyph = load_vic()
lv = open(f'{R}/build/data/levelA.bin', 'rb').read(); mp = np.frombuffer(lv[0x300:], np.uint8).reshape(64, 128); px, py = lv[0x40], lv[0x80]
def layout(ncols, nrows, tw, th, label):
    ch = np.full((nrows, ncols), 32); co = np.zeros((nrows, ncols), int)
    x0, y0 = px - tw//2, py - th//2
    for ty in range(th):
        for tx in range(tw):
            t = 97 if (x0+tx, y0+ty) == (px, py) else mp[y0+ty, x0+tx]
            for k in range(9):
                cy, cx = divmod(k, 3); ch[ty*3+cy, tx*3+cx] = chars[k][t]; co[ty*3+cy, tx*3+cx] = cols[k][t]
    def text(r, c, s, colour=1):
        for i, chr_ in enumerate(s):
            if c+i < ncols: ch[r, c+i] = ord(chr_) - 64 if chr_.isalpha() else ord(chr_); co[r, c+i] = colour
    win_rows = th*3; win_cols = tw*3
    text(win_rows + 0, 0, 'INFORMATION', 1)
    text(win_rows + 1, 0, 'WELCOME TO ROBOTS', 2)
    if nrows > win_rows + 3: text(win_rows + 2, 0, 'BY DAVID MURRAY', 2)
    if ncols > win_cols: text(0, win_cols, 'W' if ncols - win_cols == 1 else 'WE', 1)
    img = np.zeros((nrows*8, ncols*8), np.uint8)
    for r in range(nrows):
        for c in range(ncols):
            g = glyph[ch[r, c]]; img[r*8:r*8+8, c*8:c*8+8] = np.where(g == 1, VIC_TO_BBC[co[r, c] & 7], 0)
    img[win_rows*8, :win_cols*8] = 4                      # blue rule under the window
    if ncols > win_cols: img[:win_rows*8, win_cols*8] = 4
    canvas = np.zeros((256, ncols*8), np.uint8); canvas[:img.shape[0]] = img
    rgb = BBC[canvas]; im = Image.fromarray(rgb).resize((ncols*8*4, 480), Image.NEAREST)
    im.save(f'{O}/vic_{label}.png'); return im
L = [('L1', 20, 32, 6, 9, 'L1: 20x32, 6x9 tiles (54)'), ('L2', 22, 29, 7, 8, 'L2: 22 cols (CRTC R1=88), 7x8 tiles (56)'),
     ('L3', 25, 25, 8, 7, 'L3: 25x25 (CRTC overscan R1=100), 8x7 tiles (56)')]
ims = [(t, layout(c, r, w, h, n)) for n, c, r, w, h, t in L]
W = max(i.width for _, i in ims); sheet = Image.new('RGB', (W * 1, sum(i.height + 30 for _, i in ims)), (40, 40, 40)); d = ImageDraw.Draw(sheet); y = 0
for t, i in ims: d.text((8, y + 8), t + '   (cell aspect on a 4:3 monitor: 2.1 : 1)', fill=(255, 255, 255)); sheet.paste(i, (0, y + 30)); y += i.height + 30
sheet.save(f'{O}/vic_layouts.png'); print('ok', sheet.size)
