# -*- coding: utf-8 -*-
"""
spec_win2.py —— 找"零成本窗"：能在 RTL 里用计数器+移位生成、又足够压住低频误亮
------------------------------------------------------------------
候选（都不需要 ROM 表）：
  · 三角窗 (Bartlett)   w = min(n, N-1-n) 归一化   ← 只要一个 10 位计数器
  · 汉宁窗-递归生成      w = 0.5-0.5cos(2πn/N)     ← 二阶递推 1 乘法
  · 汉宁窗-查表          w 存 1024×16 ROM          ← 参考基准
  · 矩形                 基准
对比指标：① 1kHz 单音时低端频带被压到多少 dB ② 峰值柱高度损失 ③ 主瓣宽度
"""

import numpy as np
from spec_ref import FS, NB, FREQS, sig_sine, sig_noise

N = 1024


def w_rect(n):
    return np.ones(n)


def w_tri(n):
    k = np.arange(n)
    return np.minimum(k, n - 1 - k) / (n / 2.0)      # 0..1..0，均值 0.5


def w_hann(n):
    k = np.arange(n)
    return 0.5 - 0.5 * np.cos(2 * np.pi * k / n)


def goertzel_w(seg, freq, win):
    """带窗的 Goertzel（幅度按 32768*N/2*mean(w) 归一）"""
    c = 2.0 * np.cos(2 * np.pi * np.asarray(freq) / FS)
    xw = seg * win
    y1 = np.zeros(len(freq)); y2 = np.zeros(len(freq))
    for xn in xw:
        y = xn + c * y1 - y2
        y2 = y1; y1 = y
    mag = np.sqrt(np.maximum(y1*y1 + y2*y2 - c*y1*y2, 0.0))
    ref = 32768.0 * len(seg) / 2.0 * win.mean()
    return 20 * np.log10(np.maximum(mag, 1e-9) / ref)


def px_of(db, lo=-72.0, hi=-8.0):
    return np.clip((db - lo) / (hi - lo) * 100.0, 0, 100)


WINS = [("矩形", w_rect), ("三角", w_tri), ("汉宁", w_hann)]

print("=" * 96)
print("零成本窗候选对比（N=%d）" % N)
print("=" * 96)

# --- 1 kHz 单音：看低端压多少 ---
x = sig_sine(1000.0, 20000.0, N)
print("\n【1 kHz amp20000】峰值应在 band16")
for name, wf in WINS:
    win = wf(N)
    db = goertzel_w(x, FREQS, win)
    px = px_of(db)
    b = int(np.argmax(px))
    low = db[0:13]
    print("  %-4s peak band%2d %5.1fdB %3.0fpx | 低端 band0..12 最大 %6.1f dB (%3.0f px) | 误亮(>25px) %d"
          % (name, b, db[b], px[b], low.max(), px_of(low).max(),
             int((np.delete(px, np.s_[max(0,b-1):b+2]) > 25).sum())))

# --- 261.6 Hz：峰值损失 ---
print("\n【C4 261.6Hz amp20000】峰值应在 band8")
for name, wf in WINS:
    win = wf(N)
    db = goertzel_w(sig_sine(261.63, 20000.0, N), FREQS, win)
    px = px_of(db)
    b = int(np.argmax(px))
    print("  %-4s peak band%2d %5.1fdB %3.0fpx | 理论 -4.3dB 损失 %+5.2f dB"
          % (name, b, db[b], px[b], db[b] + 4.3))

# --- 白噪：整体电平是否被压低（能量损失）---
print("\n【白噪 ±6000】平均电平方差")
x = sig_noise(6000.0, N)
for name, wf in WINS:
    win = wf(N)
    db = goertzel_w(x, FREQS, win)
    print("  %-4s 平均 %6.1f dB  标准差 %5.2f dB" % (name, db.mean(), db.std()))

# --- 主瓣宽度：扫频单音，看 -6dB 带宽 ---
print("\n【主瓣宽度】1 kHz 单音在 band16(=1072Hz) 上的响应，扫输入频率")
print("          输入Hz : 响应dB (相对该输入的最大值)")
for name, wf in WINS:
    win = wf(N)
    xs = []
    for f in [700, 800, 900, 1000, 1072, 1150, 1300, 1500]:
        db = goertzel_w(sig_sine(float(f), 20000.0, N), [FREQS[16]], win)
        xs.append((f, db[0]))
    m = max(v for _, v in xs)
    print("  %-4s " % name + " ".join("%5.0f:%+6.1f" % (f, v - m) for f, v in xs))
