# -*- coding: utf-8 -*-
"""分析声部层波形：voice_out 与 DDS 输出的谐波结构。

判据：
  波表本身（钢琴槽）= 基频 85.7% + 4 次谐波 13.3%  → 期望 1F 强、4F 约 −9 dB、2F/3F 很弱
  若 voice_out 冒出一大堆谐波/噪声 → 声部层（DDS 插值/SVF）在制造失真，与幅度无关
"""
import numpy as np

P = r"D:\code\fpga-synthesizer\folder-reorg\scratch\agent\probe_voice.txt"

a = []
for line in open(P, encoding="utf-8", errors="ignore"):
    p = line.split()
    if len(p) >= 2:
        try:
            a.append([int(p[0]), int(p[1])])
        except ValueError:
            pass
a = np.array(a, dtype=np.int64)
print("帧数 =", len(a), "（每个发声时隙一行，≈ 每个采样一次）")

voices = a[:, 0].astype(float)
dds = a[:, 1].astype(float)

for nm, y in (("voice_out", voices), ("dds_wave", dds)):
    #  去掉起音段（前 150 帧）
    y = y[150:]
    n = len(y)
    print("\n=== %s ===  n=%d  min=%0.0f max=%0.0f 峰峰=%.1f%%FS"
          % (nm, n, y.min(), y.max(), 100.0 * (y.max() - y.min()) / 2 / 8388608))
    if n < 200:
        continue
    a2 = (y - y.mean()) * np.hanning(n)
    X = np.abs(np.fft.rfft(a2))
    f = np.fft.rfftfreq(n, 1.0 / 48000.0)
    band = (f > 100) & (f < 2000)
    k = np.argmax(np.where(band, X, 0))
    df = 48000.0 / n
    f0 = k * df
    A0 = X[k]
    print("  基频 %.2f Hz（分辨率 %.1f Hz）" % (f0, df))
    for h in range(1, 13):
        kh = int(round(f0 * h / df))
        if kh >= len(X):
            break
        Ah = X[max(0, kh - 1):kh + 2].max()
        print("    %2dF = %7.1f Hz : %+6.1f dB" % (h, f0 * h, 20 * np.log10(Ah / A0 + 1e-12)))
    # 非谐波能量
    mask = (f > 500) & (f < 8000)
    for h in range(1, 25):
        kh = int(round(f0 * h / df))
        mask[max(0, kh - 3):kh + 4] = False
    noise = np.sqrt(np.sum(X[mask] ** 2))
    print("    非谐波能量(0.5~8kHz) 相对基频 = %+.1f dB" % (20 * np.log10(noise / (A0 + 1e-12) + 1e-12)))
    # 过零（估计真实周期数）
    s = np.signbit(y - y.mean())
    zc = int(np.sum(s[1:] != s[:-1]))
    print("    过零 %d 次 → 单音等效 %.1f Hz" % (zc, zc / 2.0 / (n / 48000.0)))
