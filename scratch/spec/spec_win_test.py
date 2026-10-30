# -*- coding: utf-8 -*-
"""
spec_win_test.py —— 窗函数对比实验（决定 RTL 要不要加窗）
------------------------------------------------------------------
问题：1 kHz 单音时，低 14 个频带都在 -38 ~ -46 dBFS（约 40~55 px），
      整个左半边被"点亮"。原因怀疑：
        ① 矩形窗对非整周期信号的"均值不为 0" → 60 Hz 频带（极点近乎 z=1）
           实际上在积分输入的平均值 ⇒ 高频单音也在低频端产生巨大响应
        ② 矩形窗旁瓣只有 -13 dB
      对策候选：Hann 窗 / 前置高通滤波器 / 两者都上

输出：每种方案下 4 个测试信号的柱高数组，直接肉眼比较
"""

import numpy as np
from spec_ref import FS, NB, FREQS, omega, sig_sine, sig_noise, sig_sweep, goertzel_block_float

N = 1024


def win_none(n):
    return np.ones(n)


def win_hann(n):
    k = np.arange(n)
    return 0.5 - 0.5 * np.cos(2 * np.pi * k / n)


def hpf(x, fc=30.0):
    """一阶高通（RTL 里就是 y = a*(y_prev + x - x_prev)，1 乘 1 加）"""
    a = 1.0 / (1.0 + 2 * np.pi * fc / FS)
    y = np.zeros_like(x)
    yp, xp = 0.0, 0.0
    for i, xn in enumerate(x):
        v = a * (yp + xn - xp)
        y[i] = v
        yp, xp = v, xn
    return y


def bars(x, wfunc, use_hpf, db_lo=-72.0, db_hi=-8.0):
    xw = x.astype(float)
    if use_hpf:
        xw = hpf(xw)
    win = wfunc(N)
    xw = xw * win
    mag, y1, y2 = goertzel_block_float(xw)
    ref = 32768.0 * N / 2.0 * win.mean()
    db = 20 * np.log10(np.maximum(mag, 1e-9) / ref)
    px = np.clip((db - db_lo) / (db_hi - db_lo) * 100.0, 0, 100)
    return px, db


CASES = [
    ("1kHz amp20000", lambda: sig_sine(1000.0, 20000.0, N)),
    ("C4 261.6Hz amp20000", lambda: sig_sine(261.63, 20000.0, N)),
    ("白噪", lambda: sig_noise(6000.0, N)),
    ("弱音 1kHz amp328 (0.01FS)", lambda: sig_sine(1000.0, 328.0, N)),
    ("低音 E2 82.4Hz amp20000", lambda: sig_sine(82.41, 20000.0, N)),
]

PLANS = [
    ("矩形窗", win_none, False),
    ("Hann", win_hann, False),
    ("高通30+矩形", win_none, True),
    ("高通30+Hann", win_hann, True),
]

print("=" * 100)
print("窗函数 / 高通 对比（N=%d，显示范围 %g..%g dBFS，0..100 px）" % (N, -72, -8))
print("=" * 100)

for cname, mk in CASES:
    x = mk()
    print("\n### %s" % cname)
    for pname, wf, hp in PLANS:
        px, db = bars(x, wf, hp)
        b = int(np.argmax(px))
        print("  %-12s peak band %2d (%5.0fHz) %3.0fpx | dB %s"
              % (pname, b, FREQS[b], px[b],
                 " ".join("%5.1f" % d for d in db)))
        print("  %-12s %s px: %s" % ("", " " * 0,
              " ".join("%3.0f" % p for p in px)))
    print()

# 旁瓣目测统计：峰值以外，高出 25px 的柱子有多少根
print("=" * 100)
print("汇总：'误亮点'统计（除峰值 ±1 带以外，>25px 的柱子数 / 32）")
print("-" * 100)
for cname, mk in CASES:
    x = mk()
    row = []
    for pname, wf, hp in PLANS:
        px, _ = bars(x, wf, hp)
        b = int(np.argmax(px))
        mask = np.ones(NB, bool)
        mask[max(0, b - 1):b + 2] = False
        row.append("%s=%2d" % (pname, int((px[mask] > 25).sum())))
    print("  %-28s %s" % (cname, "  ".join(row)))
