# -*- coding: utf-8 -*-
"""
spec_coef.py —— 系数定标位宽取舍
------------------------------------------------------------------
发现：数值链路（窗/块浮点/log2/px 映射）本身误差 ≤3.4 px（用同一系数时）。
      剩下 19.6 px 的偏差全部来自 2cos(w) 的 Q14 量化：
        Q14 时 c 只有 1 LSB = 6.1e-5，而 60 Hz 频带的极点对 c 极其敏感
        Δf = Δc/(2sin w) * fs/2π = 6.1e-5/(2*0.00785) * 7639 = 29.7 Hz（最坏半 LSB 14.6 Hz）
      ⇒ 60 Hz 那根"柱子"其实测的是 75 Hz。频带间距才 11.8 Hz，直接混淆。

本脚本测 Q14/Q16/Q18/Q20 时：
  ① 低频端频带中心频率的实际误差
  ② 与"精确系数浮点"的柱高偏差
"""

import numpy as np
from spec_ref import FS, NB, FREQS, sig_sine, sig_noise, sig_sweep

N = 1024
SW = 34
WIN_USED = np.round((0.5 - 0.5*np.cos(2*np.pi*(np.arange(N)//16)/64)) * 64).astype(np.int64)
WIN_MEAN = WIN_USED.sum() / N / 64.0   # 注意：窗表是 0..64，除以 64 才是归一化增益
REF_AMP = 32768.0 * N / 2.0 * WIN_MEAN
LOG2_TAB5 = np.round(256*np.log2(1.0 + np.arange(32)/32.0)).astype(np.int64)


def wrap(v, bits=SW):
    v &= (1 << bits) - 1
    if v >= (1 << (bits-1)):
        v -= (1 << bits)
    return v


def log2_q8(v):
    if v <= 0:
        return 0
    p = v.bit_length() - 1
    m = (v >> (p-5)) & 0x1F if p >= 5 else (v << (5-p)) & 0x1F
    return p*256 + int(LOG2_TAB5[m])


def fixed_bars(seg, cq):
    coef = np.round(2.0*np.cos(2*np.pi*FREQS/FS) * (1 << cq)).astype(np.int64)
    ref_q5 = int(round(20*np.log10(REF_AMP) * 32))
    px = np.zeros(NB, dtype=np.int64)
    for i in range(NB):
        c = int(coef[i]); y1 = 0; y2 = 0
        for n, x in enumerate(seg):
            xw = (int(x) * int(WIN_USED[n])) >> 6
            prod = (c*y1 + (1 << (cq-1))) >> cq
            y1n = wrap(xw + prod - y2)
            y2 = y1; y1 = y1n
        a = max(abs(y1), abs(y2))
        e = 0 if a == 0 else max(0, a.bit_length()-1-14)
        ys1, ys2 = y1 >> e, y2 >> e
        t = (c*ys2) >> cq
        mag2 = ys1*ys1 + ys2*ys2 - t*ys1
        if mag2 <= 0:
            continue
        lg = log2_q8(mag2)
        lev = ((lg*385) >> 10) + (192*e + ((42*e) >> 6)) - ref_q5
        tt = lev + 2304
        px[i] = min(max((tt*25) >> 9 if tt > 0 else 0, 0), 100)
    return px


def float_bars(seg):
    win = WIN_USED/64.0
    c = 2.0*np.cos(2*np.pi*FREQS/FS)
    y1 = np.zeros(NB); y2 = np.zeros(NB)
    for xn in seg*win:
        y = xn + c*y1 - y2
        y2 = y1; y1 = y
    mag = np.sqrt(np.maximum(y1*y1+y2*y2-c*y1*y2, 0.0))
    db = 20*np.log10(np.maximum(mag, 1e-9)/REF_AMP)
    return np.clip((db+72)/64*100, 0, 100)


CASES = [("1kHz", sig_sine(1000., 20000., N*4)),
         ("C4", sig_sine(261.63, 20000., N*4)),
         ("E2", sig_sine(82.41, 20000., N*4)),
         ("noise", sig_noise(6000., N*4)),
         ("sweep", sig_sweep(200., 8000., 20000., N*4))]

print("=" * 92)
print("系数定标位宽：低频端实际中心频率误差 + 与精确浮点的柱高偏差")
print("=" * 92)
print("%-6s %-10s %-32s %s" % ("CQ", "频带间距", "前 6 个频带实际频率(标称)", "与精确浮点最大偏差"))
print("-" % ())
for cq in (14, 16, 18, 20):
    coef = np.round(2.0*np.cos(2*np.pi*FREQS/FS)*(1 << cq)).astype(np.int64)
    cf = coef / float(1 << cq)
    w_act = np.arccos(np.clip(cf/2.0, -1, 1))
    f_act = w_act*FS/(2*np.pi)
    errs = []
    for nm, x in CASES:
        for k in range(4):
            seg = x[k*N:(k+1)*N].astype(np.int64)
            errs.append(np.abs(fixed_bars(seg, cq) - float_bars(seg.astype(float))).max())
    s = " ".join("%.1f(%.1f)" % (f_act[i], FREQS[i]) for i in range(4))
    print("Q%-5d %-10.2f %-32s max=%5.1f px  mean=%4.2f"
          % (cq, FREQS[1]-FREQS[0], s, max(errs), np.mean(errs)))
print("-" * 92)
print("判断：Q16 的最坏频率误差 / 频带间距 = %.2f ；Q18 = %.2f"
      % (np.abs(np.arccos(np.clip(np.round(2*np.cos(2*np.pi*FREQS/FS)*65536)/65536/2, -1, 1))
                *FS/(2*np.pi) - FREQS).max() / (FREQS[1]-FREQS[0]),
        np.abs(np.arccos(np.clip(np.round(2*np.cos(2*np.pi*FREQS/FS)*262144)/262144/2, -1, 1))
                *FS/(2*np.pi) - FREQS).max() / (FREQS[1]-FREQS[0])))
