# -*- coding: utf-8 -*-
"""
spec_win3.py —— 窗的"可低成本实现"形态取舍
------------------------------------------------------------------
要解决的事：Hann 效果最好（误亮 0），但 1024×16 的表要占 1 块 BSRAM，
            且要 $readmemh 依赖 data/ 下的 hex 文件（找不到就全 0，静默失效）。

本脚本量化：如果把 Hann 换成"便宜形态"，效果退化多少？
  A. 梯形窗（线性斜坡 + 平台）  —— 零表、零乘法，只用计数器比较+移位
  B. 汉宁 6 bit 量化（64 级）    —— 64 项小表，可直接写成 case（~176 LUT）
  C. 汉宁 5 bit 量化（32 级）    —— 32 项小表
  D. 汉宁 8 bit 量化（256 级）   —— 256 项表
  E. 汉宁 精确                    —— 参考

判据：① 1kHz 单音时低端最大误亮  ② 误亮柱数  ③ 白噪频谱是否仍平坦（窗畸变会引入纹波）
"""

import numpy as np
from spec_ref import FS, NB, FREQS, sig_sine, sig_noise

N = 1024


def hann_exact(n):
    k = np.arange(n)
    return 0.5 - 0.5 * np.cos(2 * np.pi * k / n)


def hann_quant(n, bits):
    w = hann_exact(n)
    lev = (2 ** bits) - 1
    return np.round(w * lev) / lev


def trapezoid(n, taper):
    """前后各 taper 比例线性斜坡，中间平台（Tukey 的线性版）"""
    k = np.arange(n, dtype=float)
    L = int(n * taper / 2)
    w = np.ones(n)
    if L > 0:
        w[:L] = np.arange(L) / L
        w[n - L:] = np.arange(L)[::-1] / L
    return w


def evalwin(win, label, x1k, noise):
    def g(seg):
        c = 2.0 * np.cos(2 * np.pi * FREQS / FS)
        y1 = np.zeros(NB); y2 = np.zeros(NB)
        for xn in seg * win:
            y = xn + c * y1 - y2
            y2 = y1; y1 = y
        mag = np.sqrt(np.maximum(y1*y1 + y2*y2 - c*y1*y2, 0.0))
        ref = 32768.0 * N / 2.0 * win.mean()
        return 20 * np.log10(np.maximum(mag, 1e-9) / ref)

    db = g(x1k)
    px = np.clip((db + 72.0) / 64.0 * 100.0, 0, 100)
    b = int(np.argmax(px))
    mask = np.ones(NB, bool); mask[max(0, b-1):b+2] = False
    low_max = db[:13].max()
    noise_std = g(noise).std()
    return label, b, db[b], low_max, int((px[mask] > 25).sum()), noise_std


x1k = sig_sine(1000.0, 20000.0, N)
noise = sig_noise(6000.0, N)

WINS = [
    (hann_exact(N),                       "汉宁-精确"),
    (hann_quant(N, 8),                    "汉宁 8bit(256级)"),
    (hann_quant(N, 7),                    "汉宁 7bit(128级)"),
    (hann_quant(N, 6),                    "汉宁 6bit(64级)"),
    (hann_quant(N, 5),                    "汉宁 5bit(32级)"),
    (trapezoid(N, 0.5),                   "梯形 taper=50%"),
    (trapezoid(N, 0.75),                  "梯形 taper=75%"),
    (trapezoid(N, 1.0),                   "三角(Bartlett)"),
    (np.ones(N),                          "矩形"),
]

print("=" * 100)
print("窗形态取舍（1kHz 单音视为单音输入；白噪视为平坦频谱）")
print("=" * 100)
print("%-18s %-14s %-10s %-16s %-12s %s" %
      ("窗型", "峰值band/dB", "低端最大dB", "低端最大px", "误亮柱数", "白噪谱标准差dB"))
print("-" * 100)
for w, label in WINS:
    label, b, pdb, low, nfalse, nstd = evalwin(w, label, x1k, noise)
    print("%-18s band%2d %6.1f  %8.1f     %8.0f        %4d          %5.2f"
          % (label, b, pdb, low, np.clip((low+72)/64*100, 0, 100), nfalse, nstd))
