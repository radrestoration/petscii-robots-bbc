#!/usr/bin/env python3
"""The boot loader in the simulator: Master check, shadow Mode 7, the four loads, jump to the game."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim6502 import CPU
B = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'build')
c = CPU(); b = open(os.path.join(B, 'loader.bin'), 'rb').read(); c.m[0x1400:0x1400+len(b)] = b
log, vdu = [], []
c.traps[0xFFF4] = lambda c: setattr(c, 'x', 3)                     # OSBYTE 0: Master 128
c.traps[0xFFF7] = lambda c: log.append(bytes(c.m[c.x | (c.y << 8):][:30]).split(b'\r')[0].decode())
c.traps[0xFFE3] = lambda c: None
c.traps[0xFFEE] = lambda c: vdu.append(c.a)
c.pc = 0x1400; c.sp = 0xFF
for _ in range(100000):
    if c.pc == 0x3000: break
    c.step()
want = ['*LOAD LOW 0E00', '*LOAD MID 3000', '*SRLOAD GFX 8000 5', '*SRLOAD TILES 8000 4', '*SRLOAD SCREENS B800 4']
ok = c.pc == 0x3000 and vdu == [22, 135] and log == want
print('loader:', 'ok' if ok else 'FAILED', log, vdu)
sys.exit(0 if ok else 1)
