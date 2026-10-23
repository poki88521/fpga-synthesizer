# -*- coding: utf-8 -*-
"""深入分析 C24（DAC 之前）与 L17（DDS）波形：基频、谐波结构、有没有 2x 分量。"""
import os
import numpy as np

D = r"D:\code\fpga-synthesizer\folder-reorg\material\waveform"


def load(fn):
    rows, start, inc = [], None, None
    for i, line in enumerate(open(os.path.join(D, fn), encoding="utf-8", errors="ignore")):
        p = line.strip().split(",")
        if i == 0:
            continue
        if i == 1:
            start, inc = float(p[2]), float(p[3])
            continue
        if len(p) >= 2 and p[1] != "":
            try:
                rows.append(float(p[1]))
            except ValueError:
                pass
    return np.array(rows), inc


def amp_at(f, y, dt, df_tol=1.0):
    """在频率 f 处的幅度（用 Hann 窗的 DFT，附近取最大）。"""
    n = len(y)
    a = (y - y.mean()) * np.hanning(n)
    t = np.arange(n) * dt
    w = np.exp(-2j * np.pi * f * t)
    return abs(np.dot(a, w)) * 2.0 / n


for fn in ("c24.csv", "l17.csv"):
    y, dt = load(fn)
    n = len(y)
    freqs = np.fft.rfftfreq(n, dt)
    a = (y - y.mean()) * np.hanning(n)
    X = np.abs(np.fft.rfft(a))
    df = 1.0 / (n * dt)
    print("=" * 72)
    print("%s   %d 点  %.1f kSa/s  %.1f ms   分辨率 %.2f Hz"
          % (fn, n, 1 / dt / 1e3, n * dt * 1e3, df))

    # 找基频：在 100~1200 Hz 内找最大峰，并用抛物线插值细化
    band = (freqs > 100) & (freqs < 1200)
    k = np.argmax(np.where(band, X, 0))
    if 1 <= k < len(X) - 1:
        y0, y1, y2 = np.log(X[k - 1] + 1e-9), np.log(X[k] + 1e-9), np.log(X[k + 1] + 1e-9)
        d = 0.5 * (y0 - y2) / (y0 - 2 * y1 + y2)
    else:
        d = 0.0
    f0 = (k + d) * df
    A0 = amp_at(f0, y, dt)
    print("  基频（100~1200Hz 最强峰）= %.1f Hz   幅度 %.4f V" % (f0, A0))
    print("  谐波结构（相对基频 dB）:")
    for h in range(1, 9):
        fh = f0 * h
        if fh > 1 / (2 * dt):
            break
        Ah = amp_at(fh, y, dt)
        db = 20 * np.log10(Ah / A0 + 1e-12)
        bar = "#" * max(0, int((db + 40) / 2))
        print("     %dF = %7.1f Hz : %+6.1f dB  %s" % (h, fh, db, bar))
    # 专门看 2 倍频（旧的 2x bug 特征：2F 明显强于 F）
    print("  → 2F/F = %+0.1f dB   （若 > +3 dB，说明还有 2 倍音高问题）"
          % (20 * np.log10(amp_at(2 * f0, y, dt) / A0 + 1e-12)))
    print()
