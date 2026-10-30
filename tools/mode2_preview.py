#!/usr/bin/env python3
"""Mode 2 (160x256, 8 colours) previews for comparison with the current Mode 1 build.  Writes build/preview/mode2_*.png
(all shown at 4:3 as a monitor would: 640x480).  No game code involved: tiles are composed from the level map.
  A  Mode 1 as built (from the simulator's screen: needs build/preview/play.png from tools/play_test.py)
  B  Mode 2, C64 layout (40 columns of 4-pixel cells), C64 art down-sampled 8->4 pixels, 8 colours per cell
  C  Mode 2, VIC-20 style (20 columns of 8-pixel cells = wide pixels, full glyph detail), C64 art, 6x7 tile window
  D  as C but with the VIC-20 version's own tileset/font
  E  as B but with the VIC-20 art
usage: mode2_preview.py"""
import os, sys, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import c64data
from PIL import Image, ImageDraw
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); U = f'{R}/upstream'; O = f'{R}/build/preview'
os.makedirs(O, exist_ok=True)
BBC = c64data.BBC
def nearest8(rgb): return int(np.argmin(((BBC.astype(int) - np.array(rgb, int))**2).sum(1)))
C64_TO_BBC = [nearest8(c) for c in c64data.C64]
VIC_TO_BBC = [0, 7, 1, 6, 5, 2, 4, 3]            # VIC-20 colours 0-7: black white red cyan purple green blue yellow
def load(game):
    d = f'{U}/{game}'
    ts = open(f'{d}/tileset.gfx' if game == 'c64' else f'{d}/tileset.vic', 'rb').read()[2:].ljust(5120, b'\0')
    chars, cols = c64data.tile_tables(ts)
    font = np.frombuffer(open(f'{d}/gfxfont.prg', 'rb').read()[2:2+2048], np.uint8).reshape(256, 8)
    return chars, cols, np.unpackbits(font, axis=1).reshape(256, 8, 8)
lv = open(f'{R}/build/data/levelA.bin', 'rb').read(); mp = np.frombuffer(lv[0x300:], np.uint8).reshape(64, 128)
px, py = lv[0x40], lv[0x80]
def down(glyph):                                   # 8x8 bits -> 8 rows x 4 pixels, lit if either source pixel is lit
    return (glyph[:, 0::2] | glyph[:, 1::2])
def cells(art, tx0, ty0, w, h, tmap, player_tile=None):
    """character grid (3h x 3w) of (glyph-index, colour) for a w x h tile window at map (tx0,ty0)"""
    chars, cols, _ = art; ch = np.zeros((3*h, 3*w), int); co = np.zeros((3*h, 3*w), int)
    for ty in range(h):
        for tx in range(w):
            t = mp[ty0 + ty, tx0 + tx]
            if player_tile is not None and (tx0 + tx, ty0 + ty) == (px, py): t = player_tile
            for k in range(9):
                cy, cx = divmod(k, 3); ch[ty*3+cy, tx*3+cx] = chars[k][t]; co[ty*3+cy, tx*3+cx] = cols[k][t]
    return ch, co
def render(ch, co, glyphs, cmap, cell_w, canvas_cols, canvas_rows, downsample):
    W = canvas_cols * (4 if downsample else 8)   # Mode 2 pixels
    img = np.zeros((canvas_rows * 8, W), np.uint8); cw = 4 if downsample else 8
    for r in range(ch.shape[0]):
        for c in range(ch.shape[1]):
            g = glyphs[ch[r, c]]; g = down(g) if downsample else g
            img[r*8:r*8+8, c*cw:c*cw+cw] = np.where(g == 1, cmap[co[r, c] & 15 if cmap is C64_TO_BBC else co[r, c] & 7], 0)
    return img
def to_png(img256, name, w_px):
    # place on a 256-line canvas, show 4:3
    full = np.zeros((256, w_px), np.uint8); full[:img256.shape[0], :img256.shape[1]] = img256
    rgb = BBC[full]
    Image.fromarray(rgb).resize((640, 480), Image.NEAREST).save(f'{O}/{name}.png'); return Image.open(f'{O}/{name}.png')
c64, vic = load('c64'), load('vic20')
# B: C64 layout, 4-pixel cells, C64 art; window 11x7 at the top-left like the game, centred on the player
tx0, ty0 = px - 5, py - 3
ch, co = cells(c64, tx0, ty0, 11, 7, mp)
imgB = render(ch, co, c64[2], C64_TO_BBC, 4, 40, 25, True)
# player sprite (3 hi-res layers, 24x21) over the centre tile
spr = open(f'{U}/c64/sprites.gfx', 'rb').read()[2:]
def sprite(imgB, base_ptr, cols_layers, x0, y0, down_):
    for i, colour in enumerate(cols_layers):
        d = spr[(base_ptr + i - 0x90)*64:(base_ptr + i - 0x90)*64 + 63]
        for y in range(21):
            row = [(d[y*3 + x//8] >> (7 - x % 8)) & 1 for x in range(24)]
            if down_: row = [row[2*k] | row[2*k+1] for k in range(12)]
            for x, b in enumerate(row):
                if b: imgB[y0 + y, x0 + x] = C64_TO_BBC[colour]
sprite(imgB, 0xA7, (6, 14, 10), 15*4, 9*8, True)
b = to_png(imgB, 'mode2_B_c64_downsampled', 160)
# C: VIC-20 style cells (8-pixel wide cells, so 20 columns): 6x7 tile window, C64 art
tx0, ty0 = px - 3, py - 3
ch, co = cells(c64, tx0, ty0, 6, 7, mp)
imgC = render(ch, co, c64[2], C64_TO_BBC, 8, 20, 25, False)
sprite(imgC, 0xA7, (6, 14, 10), 9*8, 9*8, False)
c = to_png(imgC, 'mode2_C_c64_wide', 160)
# D: same with the VIC-20 art (player is a tile there)
ch, co = cells(vic, tx0, ty0, 6, 7, mp, player_tile=97)
imgD = render(ch, co, vic[2], VIC_TO_BBC, 8, 20, 25, False)
d_ = to_png(imgD, 'mode2_D_vic20_wide', 160)
# E: C64 layout 4-pixel cells with VIC-20 art
tx0, ty0 = px - 5, py - 3
ch, co = cells(vic, tx0, ty0, 11, 7, mp, player_tile=97)
imgE = render(ch, co, vic[2], VIC_TO_BBC, 4, 40, 25, True)
e = to_png(imgE, 'mode2_E_vic20_downsampled', 160)
# contact sheet
tiles = [('B  Mode 2, 40x25 of 4px cells, C64 art', b), ('E  same, VIC-20 art', e), ('C  Mode 2, 20x25 of 8px cells, C64 art (6x7 tiles)', c), ('D  same, VIC-20 art', d_)]
a_path = f'{O}/play.png'
if os.path.exists(a_path): tiles.insert(0, ('A  Mode 1 as built (4 colours)', Image.open(a_path).resize((640, 480), Image.NEAREST)))
cols_n = 2; rows_n = (len(tiles) + 1) // 2
sheet = Image.new('RGB', (1280, rows_n * 520), (40, 40, 40)); dr = ImageDraw.Draw(sheet)
for i, (label, im) in enumerate(tiles):
    x, y = (i % cols_n) * 640, (i // cols_n) * 520; sheet.paste(im.convert('RGB'), (x, y + 40)); dr.text((x + 8, y + 12), label, fill=(255, 255, 255))
sheet.save(f'{O}/mode2_comparison.png'); print('wrote', [t[0] for t in tiles])

# F: the real game screen (VSCR/VCOL from the simulator after the level starts) in Mode 2 with 4-pixel cells - shows the panel/text
import sim_bbc
g = sim_bbc.Game(); L = g.L; m = g.cpu.m
g.cpu.pc = L['START']; g.cpu.sp = 0xFF; g.run(2_000_000); g.keys.append(13); g.run(6_000_000)
chs = np.frombuffer(bytes(m[L['VSCR']:L['VSCR']+1000]), np.uint8).reshape(25, 40); cos = np.frombuffer(bytes(m[L['VCOL']:L['VCOL']+1000]), np.uint8).reshape(25, 40)
imgF = render(chs.astype(int), cos.astype(int), c64[2], C64_TO_BBC, 4, 40, 25, True)
sprite(imgF, 0xA7, (6, 14, 10), 15*4, 9*8, True)
f = to_png(imgF, 'mode2_F_real_screen', 160)
imgF8 = render(chs.astype(int), cos.astype(int), c64[2], C64_TO_BBC, 8, 40, 25, False)
Image.fromarray(BBC[imgF8]).resize((640, 480), Image.NEAREST).save(f'{O}/ideal_8colour_320px.png')
