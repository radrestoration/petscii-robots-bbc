#!/usr/bin/env python3
"""Mode 1 (BBC) quantisation preview of the C64 tileset and map windows.
Formats checked against C64ROBOTS.ASM: tileset.gfx = 2-byte load addr + 20 pages
(DESTRUCT, ATTRIB, 9 char pages TL..BR, 9 colour pages TL..BR); gfxfont.prg =
load addr + 256 chars x 8 bytes at $F000 (1st 2K used); level = load addr +
$300 unit bytes + 8K map (128x64)."""
import sys, itertools, numpy as np
from PIL import Image
U = sys.argv[1] if len(sys.argv) > 1 else '../upstream/c64'
OUT = sys.argv[2] if len(sys.argv) > 2 else '../build/preview'
ts = open(f'{U}/tileset.gfx','rb').read()[2:].ljust(5120,b'\0')   # file is 1 byte short of 20 pages; last colour entry unused
page = lambda n: np.frombuffer(ts[n*256:(n+1)*256], np.uint8)
attrib, chars, cols = page(1), [page(2+i) for i in range(9)], [page(11+i) for i in range(9)]
font = np.frombuffer(open(f'{U}/gfxfont.prg','rb').read()[2:2+2048], np.uint8).reshape(256,8)
bits = np.unpackbits(font, axis=1).reshape(256,8,8)       # [char,y,x]
C64 = np.array([(0,0,0),(255,255,255),(136,57,50),(103,182,189),(139,63,150),(85,160,73),(64,49,141),(191,206,114),
 (139,84,41),(87,66,0),(184,105,98),(80,80,80),(120,120,120),(148,224,137),(120,105,196),(159,159,159)],np.uint8)
BBC = np.array([(0,0,0),(255,0,0),(0,255,0),(255,255,0),(0,0,255),(255,0,255),(0,255,255),(255,255,255)],np.uint8)
print('colour nibble values present:', sorted(set(int(v) for c in cols for v in c)))
# usage of each C64 colour by non-blank cells of all tiles
use = np.zeros(16)
for t in range(256):
    for k in range(9):
        if bits[chars[k][t]].any(): use[cols[k][t] & 15] += bits[chars[k][t]].sum()
d = lambda a,b: ((a.astype(int)[:,None]-b.astype(int)[None])**2).sum(-1)
dist = d(C64, BBC)                                        # 16 x 8
best = min(itertools.combinations(range(1,8),3),
           key=lambda s: sum(use[c]*min(dist[c][list(s)]) for c in range(16)))
pal = [0,*best]; print('Mode 1 colours (BBC physical):', pal, ' usage by C64 colour:', use.astype(int).tolist())
cmap = [pal.index(pal[1+int(np.argmin(dist[c][list(best)]))]) if c else 0 for c in range(16)]
def tile(t, m1):
    img = np.zeros((24,24,3),np.uint8)
    for k in range(9):
        cy,cx = divmod(k,3); c = int(cols[k][t]) & 15
        rgb = BBC[pal[cmap[c]]] if m1 else C64[c]
        m = bits[chars[k][t]].astype(bool)
        img[cy*8:cy*8+8, cx*8:cx*8+8][m] = rgb
    return img
for m1,name in ((0,'c64'),(1,'mode1')):
    sheet = np.zeros((16*24,16*24,3),np.uint8)
    for t in range(256): sheet[t//16*24:t//16*24+24, t%16*24:t%16*24+24] = tile(t,m1)
    Image.fromarray(sheet).resize((16*24*2,16*24*2),Image.NEAREST).save(f'{OUT}/tileset_{name}.png')
lv = open(f'{U}/level-a','rb').read()[2:]; mp = np.frombuffer(lv[0x300:0x300+8192],np.uint8).reshape(64,128)
print('level-a unit-area bytes', len(lv[:0x300]), 'map bytes', len(lv[0x300:]))
for m1,name in ((0,'c64'),(1,'mode1')):
    w = np.zeros((7*24,11*24,3),np.uint8)
    for y in range(7):
        for x in range(11): w[y*24:y*24+24, x*24:x*24+24] = tile(mp[y+2,x+2],m1)
    Image.fromarray(w).resize((11*24*3,7*24*3),Image.NEAREST).save(f'{OUT}/window_{name}.png')
