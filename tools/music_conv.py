#!/usr/bin/env python3
"""Reference model of the SID -> SN76489 conversion the BBC music player does every 50 Hz frame (the 6502 version is
platform/bbc/music.s; tools/music_conv_test.py checks it against this, write for write).

Input: the 25 SID registers the (translated) C64 player leaves in its shadow registers.  Output: the SN76489 register writes.
What it keeps and what it cannot:
  * notes: pitch is the SID frequency register F (PAL clock, which is what the song data's note table is tuned for: A4 = 440.09 Hz)
    converted to the SN's 10-bit period N = K / F  (K = 125000 * 2^24 / 985248).  Vibrato and slides are in F, so they survive.
    The SN cannot go below 122 Hz (N = 1023): lower notes are folded up whole octaves (a bass line sounds an octave or two higher).
  * loudness: the SID envelope (ADSR, gate) is followed with a linear 16-bit level; the SN has 16 attenuation steps of 2 dB.
    Attack/decay/release times are the SID datasheet's; the real chip's decay is not linear - listen and tune.
  * waveform: everything except noise is a square wave.  A voice with the noise waveform drives the SN's noise channel instead
    (white noise, one of three fixed rates picked from F); with two noise voices the louder wins.  No ring modulation.
  * filter: not modelled, except that a noise voice the song routes through the SID's low-pass filter (reg 23 bit n and reg 24 bit 4:
    the level songs' drum voice) is a low thump on the C64, not hiss: it gets the lowest SN noise rate and FILT_ATT steps less loudness.
  * gain: the level songs (0-3) are mixed about 10 dB lower than the title tune; they are played LEVEL_GAIN attenuation steps louder.
Also writes build/data/music_conv.inc (tables for the 6502 code).
usage: music_conv.py [out dir]"""
import os, sys
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLOCK = 985248
K = round(125000 * 2**24 / CLOCK)             # N = K / F
ATK_MS = [2, 8, 16, 24, 38, 56, 68, 80, 100, 250, 500, 800, 1000, 3000, 5000, 8000]
DR_MS = [6, 24, 48, 72, 114, 168, 204, 240, 300, 750, 1500, 2400, 3000, 9000, 15000, 24000]
def step(ms): return min(65535, round(65535 * 20 / ms))      # 20 ms a frame
ATK = [step(t) for t in ATK_MS]
DR = [step(t) for t in DR_MS]
import math
LEVEL_GAIN = 4                      # attenuation steps (2 dB each) taken off the level songs' sound
FILT_ATT = 2                        # steps added to a low-pass filtered noise voice
THR = [math.ceil(255 * 10 ** (-(a + 0.5) * 0.1)) for a in range(15)]       # level (high byte) >= THR[a]  ->  attenuation a
QT = [round(K / (128 + i)) for i in range(129)]                          # Q(m) = K * 256 / m for m = (128 + i) * 256

def period(f):
    """SN period for SID frequency f (1..65535)"""
    s = 0
    while not f << s & 0x8000: s += 1
    m = f << s & 0xFFFF
    h = (m >> 8) - 128; lo = m & 255
    d = (QT[h] - QT[h + 1]) & 255
    q = QT[h] - ((d * (lo >> 5)) >> 3)
    r = max(4, 8 - s)
    n = (q + (1 << (r - 1))) >> r
    return n if n < 1024 else (q + (1 << r)) >> (r + 1)       # just over the SN's range: one more octave up

def attenuation(level):
    hi = level >> 8
    for a in range(15):
        if hi >= THR[a]: return a
    return 15

class Conv:
    def __init__(self, gain=0):
        self.gain = gain
        self.lvl = [0] * 3; self.phase = [3] * 3; self.gate = [0] * 3
        self.ln = [-1] * 3; self.la = [-1] * 3; self.lr = -1; self.lna = -1
    def frame(self, regs):
        """regs: the 25 SID registers -> list of SN bytes written this frame"""
        out = []; natt = 15; rate = None
        for v in range(3):
            fl, fh, ctrl, ad, sr = regs[7 * v], regs[7 * v + 1], regs[7 * v + 4], regs[7 * v + 5], regs[7 * v + 6]
            g = ctrl & 1
            if g and not self.gate[v]: self.phase[v] = 0
            elif not g and self.gate[v]: self.phase[v] = 3
            self.gate[v] = g
            lvl = self.lvl[v]; ph = self.phase[v]; tgt = (sr >> 4) * 0x1100
            if ph == 0:
                lvl += ATK[ad >> 4]
                if lvl > 65535: lvl = 65535; ph = 1
            elif ph == 1:
                lvl -= DR[ad & 15]
                if lvl <= tgt: lvl = tgt; ph = 2                  # (a borrow is negative here, so also <= tgt)
            elif ph == 2:
                if lvl > tgt: lvl = tgt
            else:
                lvl -= DR[sr & 15]
                if lvl < 0: lvl = 0
            self.lvl[v] = lvl; self.phase[v] = ph
            att = attenuation(lvl) if ctrl & 0xF0 else 15
            f = fl | fh << 8
            if f == 0: att = 15
            if att < 15: att = max(0, att - self.gain)
            if ctrl & 0x80:                                       # noise waveform: the noise channel
                filt = bool(regs[23] >> v & 1 and regs[24] & 0x10)   # through the low-pass filter: low thump, not hiss
                if filt and att < 15: att = min(14, att + FILT_ATT)
                if att < natt: natt = att; rate = 2 if filt else 0 if fh >= 0x80 else 1 if fh >= 0x40 else 2
                att = 15
            if att < 15:
                n = period(f)
                if n != self.ln[v]:
                    out += [0x80 | v << 5 | n & 15, n >> 4]; self.ln[v] = n
            if att != self.la[v]:
                out.append(0x90 | v << 5 | att); self.la[v] = att
        if natt < 15 and rate != self.lr:
            out.append(0xE4 | rate); self.lr = rate
        if natt != self.lna:
            out.append(0xF0 | natt); self.lna = natt
        return out

def write_tables(o):
    os.makedirs(o, exist_ok=True)
    L = ['; generated by tools/music_conv.py', 'MCQ_LO:\t.byte ' + ','.join(str(q & 255) for q in QT), 'MCQ_HI:\t.byte ' + ','.join(str(q >> 8) for q in QT),
         'MCATK_LO:\t.byte ' + ','.join(str(a & 255) for a in ATK), 'MCATK_HI:\t.byte ' + ','.join(str(a >> 8) for a in ATK),
         'MCDR_LO:\t.byte ' + ','.join(str(a & 255) for a in DR), 'MCDR_HI:\t.byte ' + ','.join(str(a >> 8) for a in DR),
         'MCTHR:\t.byte ' + ','.join(str(t) for t in THR),
         'MC_LEVEL_GAIN = %d' % LEVEL_GAIN, 'MC_FILT_ATT = %d' % FILT_ATT]
    open(os.path.join(o, 'music_conv.inc'), 'w').write('\n'.join(L) + '\n')

if __name__ == '__main__':
    write_tables(sys.argv[1] if len(sys.argv) > 1 else os.path.join(R, 'build', 'data'))
    print('K =', K, ' THR =', THR, ' period(7494)=', period(7494), '(A4 should be', round(125000 / 440), ')')
