#!/usr/bin/env python3
"""Cursor keys held down without any character in the OS keyboard buffer (as if the OS's cursor-key mode were off) must still move
the player and the intro menu selection: HAL_GETKEY scans them directly."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim_bbc
g = sim_bbc.Game(); L = g.L; c = g.cpu; m = c.m
c.pc = L['START']; c.sp = 0xFF; g.run(2_000_000)
col0 = bytes(m[L['VCOL']:L['VCOL'] + 1000])
g.held = {0x29}; g.run(1_200_000); g.held = set(); g.run(500_000)          # cursor down held in the intro menu: the highlight moves (colours change)
print('intro menu highlight moved:', bytes(m[L['VCOL']:L['VCOL'] + 1000]) != col0)
g.held = {0x39}; g.run(1_200_000); g.held = set(); g.run(500_000)           # cursor up: back to START GAME
g.keys.append(13); g.run(6_000_000)                                          # start game
def peek(a): return m[a] if g.rom == 4 else g.banks[4][a - 0x8000]     # bank 4 may be paged out at the instant we look
x0 = peek(0x9540)
g.held = {0x79}; g.run(3_000_000); g.held = set(); g.run(500_000)           # cursor right held for 1.5 s
x1 = peek(0x9540)
print('player x %d -> %d' % (x0, x1)); sys.exit(0 if x1 > x0 else 1)
