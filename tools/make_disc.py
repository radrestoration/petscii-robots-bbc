#!/usr/bin/env python3
"""Package the BBC build as a bootable DFS .ssd: !BOOT (the loader), LOW, MID, GFX, TILES and
LEVEL-A..LEVEL-N.  usage: make_disc.py out.ssd"""
import os, sys, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_bbc_ssd import build_ssd
B = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'build')
rd = lambda p: open(os.path.join(B, p), 'rb').read()
mid = rd('robots-mid.bin'); assert 0x3000 + len(mid) <= 0x8000, 'MID overflows into the sideways window'
files = [('!BOOT', 0x1400, 0x1400, rd('loader.bin')), ('LOW', 0x0E00, 0x0E00, rd('robots-low.bin')),
         ('MID', 0x3000, 0x3000, mid), ('GFX', 0, 0, rd('robots-gfx.bin')), ('TILES', 0, 0, rd('data/tiles.bin'))]
for p in sorted(glob.glob(os.path.join(B, 'data', 'level?.bin'))):
    files.append(('LEVEL-' + p[-5].upper(), 0, 0, open(p, 'rb').read()))
open(sys.argv[1], 'wb').write(build_ssd(files, title='ROBOTS', boot_option=2))
print('wrote %s: %s' % (sys.argv[1], ', '.join('%s %d' % (n, len(d)) for n, _, _, d in files)))
