# SPDX-License-Identifier: GPL-3.0-only
"""Shared loaders for the C64 assets of PETSCII Robots (formats verified from C64ROBOTS.ASM,
see tiles_preview.py's docstring) and the first-pass Mode 1 palette."""
import itertools, numpy as np

C64 = np.array([(0,0,0),(255,255,255),(136,57,50),(103,182,189),(139,63,150),(85,160,73),(64,49,141),(191,206,114),
 (139,84,41),(87,66,0),(184,105,98),(80,80,80),(120,120,120),(148,224,137),(120,105,196),(159,159,159)], np.uint8)
BBC = np.array([(0,0,0),(255,0,0),(0,255,0),(255,255,0),(0,0,255),(255,0,255),(0,255,255),(255,255,255)], np.uint8)

def load_tileset(u):
    ts = open(f'{u}/tileset.gfx','rb').read()[2:].ljust(5120, b'\0')   # file is 1 byte short of 20 pages
    return ts

def load_font(u):
    return open(f'{u}/gfxfont.prg','rb').read()[2:2+2048]

def tile_tables(ts):
    page = lambda n: np.frombuffer(ts[n*256:(n+1)*256], np.uint8)
    return [page(2+i) for i in range(9)], [page(11+i) for i in range(9)]    # chars TL..BR, colours TL..BR

def choose_palette(u):
    """3 BBC colours (+black) chosen by weighted nearest-colour error over the tileset's lit pixels;
    returns (physical colours for logical 0..3, cmap: C64 colour -> logical 0..3)."""
    chars, cols = tile_tables(load_tileset(u))
    bits = np.unpackbits(np.frombuffer(load_font(u), np.uint8).reshape(256,8), axis=1).reshape(256,8,8)
    use = np.zeros(16)
    for t in range(256):
        for k in range(9):
            if bits[chars[k][t]].any(): use[cols[k][t] & 15] += bits[chars[k][t]].sum()
    dist = ((C64.astype(int)[:,None]-BBC.astype(int)[None])**2).sum(-1)
    best = min(itertools.combinations(range(1,8),3), key=lambda s: sum(use[c]*min(dist[c][list(s)]) for c in range(16)))
    pal = [0,*best]
    cmap = [0] + [1 + int(np.argmin(dist[c][list(best)])) for c in range(1,16)]
    return pal, cmap
