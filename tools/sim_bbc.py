# SPDX-License-Identifier: GPL-3.0-only
"""Headless BBC Master harness on sim6502.py: main RAM, shadow RAM (ACCCON bit 2 'X' swaps
&3000-&7FFF), sideways banks (ROMSEL swaps &8000-&BFFF), load the linked images, call routines,
decode the shadow Mode 1 screen.  No emulator, no display.  Layout per source/platform/bbc/defs.s."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim6502 import CPU

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
B = os.path.join(ROOT, 'build')

def labels(path=os.path.join(B, 'robots.dbg')):
    """symbol addresses from ld65's --dbgfile (ca65 -g); -Ln only lists exported symbols"""
    import re
    d = {}
    for l in open(path):
        if l.startswith('sym\t'):
            f = dict(kv.split('=', 1) for kv in l.split('\t', 1)[1].strip().split(','))
            if f.get('type') == 'lab' and 'val' in f: d[f['name'].strip('"')] = int(f['val'], 16)
    for l in open(os.path.join(ROOT, 'source', 'platform', 'bbc', 'defs.s')):     # equates
        m = re.match(r'^(\w+)\s*=\s*\$([0-9A-Fa-f]+)', l)
        if m: d.setdefault(m.group(1), int(m.group(2), 16))
    return d

class BBC:
    def __init__(self, data=os.path.join(B, 'data')):
        self.cpu = CPU(); self.L = labels()
        m = self.cpu.m
        for off, name in ((0x0E00, 'robots-low.bin'), (0x3000, 'robots-mid.bin')):
            b = open(os.path.join(B, name), 'rb').read(); m[off:off+len(b)] = b
        self.banks = {n: bytearray(0x4000) for n in range(16)}
        g = open(os.path.join(B, 'robots-gfx.bin'), 'rb').read(); self.banks[5][:len(g)] = g
        self.crtc = {12: 0x06, 13: 0x00}; self.crtc_sel = 0; self.sn = []; self.ddra = []; self.frame = 0
        self.rom = 0; self.shadow = bytearray(0x5000); self.x = 0
        self.cpu.write_hooks.append(self._hook)
        self.select_bank(4)
        scr = open(os.path.join(B, 'robots-scr.bin'), 'rb').read(); m[0xB800:0xB800+len(scr)] = scr     # compressed screens: bank 4 at &B800
        self.log = []
    def select_bank(self, n):
        m = self.cpu.m
        self.banks[self.rom][:] = m[0x8000:0xC000]; self.rom = n; m[0x8000:0xC000] = self.banks[n]
    def _hook(self, a, v):
        if a == 0xFE30: self.select_bank(v & 15)
        elif a == 0xFE00: self.crtc_sel = v
        elif a == 0xFE40 and v == 0: self.sn.append((self.frame, self.cpu.m[0xFE41]))      # SN76489 /WE strobe: the byte on port A
        elif a == 0xFE43: self.ddra.append(v)
        elif a == 0xFE01: self.crtc[self.crtc_sel] = v
        elif a == 0xFE34:
            x = (v >> 2) & 1
            if x != self.x:
                m = self.cpu.m; main = bytes(m[0x3000:0x8000]); m[0x3000:0x8000] = self.shadow; self.shadow[:] = main; self.x = x
    def call(self, addr, a=0, x=0, y=0, maxcyc=50_000_000):
        c = self.cpu; sentinel = 0xFFF0
        c.a, c.x, c.y = a, x, y
        c.push((sentinel - 1) >> 8); c.push((sentinel - 1) & 0xFF); c.pc = addr
        c.i = 0
        start = c.cycles
        while c.pc != sentinel:
            c.step()
            if c.cycles - start > maxcyc: raise RuntimeError('runaway at $%04X' % c.pc)
        return c.cycles - start
    def screen_ram(self):
        """the 20 KB shadow screen (&3000-&7FFF as the CPU sees it with X=1)"""
        return bytes(self.cpu.m[0x3000:0x8000]) if self.x else bytes(self.shadow)
    def decode(self, scrtop_off=0, cols=40, rows=32):
        """-> rows*8 x cols*8 array of logical colours 0..3 from the Mode 1 shadow screen"""
        import numpy as np
        s = self.screen_ram(); img = np.zeros((rows*8, cols*8), np.uint8)
        for r in range(rows):
            for c in range(cols):
                base = scrtop_off + (r*cols + c)*16
                for half in (0, 1):
                    for y in range(8):
                        b = s[base + half*8 + y]
                        for p in range(4):
                            img[r*8+y, c*8+half*4+p] = (((b >> (7-p)) & 1) << 1) | ((b >> (3-p)) & 1)
        start = ((self.crtc[12] << 8 | self.crtc[13]) * 8 - 0x3000) // 640          # CRTC start address, in cell rows (wraps)
        return np.roll(img, -start * 8, axis=0)


class Game(BBC):
    """BBC + the OS entry points the HAL uses (trapped), the data banks loaded, and a 50 Hz vsync."""
    def __init__(self):
        super().__init__()
        d = os.path.join(B, 'data'); self.osbyte_log = []; self.vdu = []; self.oscli_log = []
        self.keys = []                       # OS keyboard buffer (characters)
        self.held = set()                    # internal key numbers currently down
        scr = open(os.path.join(B, 'robots-scr.bin'), 'rb').read(); self.cpu.m[0xB800:0xB800+len(scr)] = scr
        tiles = open(os.path.join(d, 'tiles.bin'), 'rb').read()
        self.cpu.m[0x8000:0x8000+len(tiles)] = tiles          # bank 4 is the one paged in
        self.load_level('A')
        c = self.cpu; m = c.m
        m[0xFFF2] = 0x60                      # RTS: the default EVNTV target (handlers are entered by JSR)
        m[0x0220] = 0xF2; m[0x0221] = 0xFF
        c.traps[0xFFEE] = lambda c: self.vdu.append(c.a)
        c.traps[0xFFF4] = self._osbyte
        c.traps[0xFFF7] = self._oscli
        self.next_irq = 40000
        self.fail_mus = 0                    # test: this many song loads silently deliver nothing
        self.load_frames = 0                 # vsync events delivered during each *SRLOAD (0 = the load is instantaneous)
    def load_level(self, ch):
        d = open(os.path.join(B, 'data', 'level%s.bin' % ch), 'rb').read()
        self.banks[4][0x1500:0x1500+len(d)] = d
        if self.rom == 4: self.cpu.m[0x9500:0x9500+len(d)] = d
    def _osbyte(self, c):
        a, x, y = c.a, c.x, c.y; self.osbyte_log.append((a, x, y))
        if a == 0x91:                         # get byte from keyboard buffer
            if self.keys: c.y = self.keys.pop(0); c.c = 0
            else: c.c = 1
        elif a == 0x81:                       # INKEY(-n)
            n = (x ^ 0xFF)
            if x >= 0x80 and n in self.held: c.x = c.y = 0xFF
            else: c.x = c.y = 0
    def _oscli(self, c):
        s = bytes(c.m[c.x | (c.y << 8):][:80]).split(b'\r')[0].decode(); self.oscli_log.append(s)
        p = s.split()
        if p[0].upper() != '*SRLOAD': return
        # A real *SRLOAD takes the disc a while, with interrupts on: the vsync event fires meanwhile, and the MOS has the target bank
        # paged in for the copy.  `load_frames` events are delivered with that bank paged, as on the machine (the handler has to cope).
        bank = int(p[3]) if len(p) > 3 else None
        old = self.rom
        if bank is not None and self.load_frames and c.m[0x0220] | (c.m[0x0221] << 8) == self.L['EVT']:
            self.select_bank(bank)
            for _ in range(self.load_frames): self.vsync()
            self.select_bank(old)
        if p[1].upper().startswith('MUS') and self.fail_mus:      # (test: the disc read does not deliver the image)
            self.fail_mus -= 1
        elif p[1].upper().startswith('MUS'):      # a song image into a sideways bank
            img = open(os.path.join(B, p[1].upper()), 'rb').read(); addr = int(p[2], 16)
            if self.rom == bank: self.cpu.m[addr:addr + len(img)] = img
            else: self.banks[bank][addr - 0x8000:addr - 0x8000 + len(img)] = img
        else:                                   # honour level loads
            self.load_level(p[1][-1].upper())
    def run(self, cycles):
        """run the main program for `cycles`, taking a vsync event every 20 ms"""
        c = self.cpu; end = c.cycles + cycles
        while c.cycles < end:
            c.step()
            if c.cycles >= self.next_irq and not c.i:      # SEI'd critical sections defer it, as on the real machine
                self.next_irq += 40000
                if c.m[0x0220] | (c.m[0x0221] << 8) == self.L['EVT']: self.vsync()   # only once the game has hooked it
    def vsync(self):
        self.frame += 1
        c = self.cpu; sv = (c.a, c.x, c.y, c.pc, c.p(), c.sp)
        self.call(self.L['EVT'], a=4, x=c.x, y=c.y)
        c.a, c.x, c.y, c.pc, c.sp = sv[0], sv[1], sv[2], sv[3], sv[5]; c.setp(sv[4])
