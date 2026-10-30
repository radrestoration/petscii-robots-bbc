#!/usr/bin/env python3
"""Latency of a movement step in the simulator: cycles from the key press to the last tile/cell drawn for that step, and the
cycles the display code itself used.  usage: step_timing.py"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim_bbc
g = sim_bbc.Game(); L = g.L; c = g.cpu
c.pc = L['START']; c.sp = 0xFF; g.run(2_000_000); g.keys.append(13); g.run(6_000_000)
def hal_pc(pc): return (L['HAL_REFRESH'] <= pc < L['HAL_REFRESH'] + 0x1200) or 0x0E00 <= pc < 0x1200 or pc >= 0x8000
def step(key, window=2_000_000):
    g.keys.append(key); t0 = c.cycles; last = t0; hal = 0; blits = cells = 0; end = t0 + window
    d = [L['DRAWIDX_%d' % i] for i in range(5)]
    while c.cycles < end:
        pc = c.pc; c0 = c.cycles
        if pc == L['HAL_BLIT_CRIT']: blits += 1; last = c.cycles
        if pc in d: cells += 1; last = c.cycles
        c.step()
        if hal_pc(pc): hal += c.cycles - c0
        if c.cycles >= g.next_irq and not c.i:
            g.next_irq += 40000
            if c.m[0x220] | (c.m[0x221] << 8) == L['EVT']: g.vsync()
    return last - t0, hal, blits, cells
res = [step(k) for k in (137, 137, 138, 138, 136, 139)]
for r in res: print('key->last draw %6d cycles (%3.0f ms)   display code %6d cycles   tiles %2d cells %2d' % (r[0], r[0] / 2000, r[1], r[2], r[3]))
print('average latency %.0f ms' % (sum(r[0] for r in res) / len(res) / 2000))
