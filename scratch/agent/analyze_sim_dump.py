# -*- coding: utf-8 -*-
"""分析整链仿真的数字域 dump（probe_full.txt）。

每行 4 列（每个采样帧一行，约 48 kHz）：
    sample_l            送 DAC 的最终 16 位
    voice_aud[23:0]     泳道 0 的 VCA 输出（Q1.23）
    dbg_va_r            8 泳道 VCA 输出之和（= E25 探针看到的信号，Q1.23）
    ch_l                通道层输出（效果器之前，Q1.23）

判据：
    · sample_l 干净（THD 低、无跳变、无削顶） → RTL 没问题，"炸"只在硬件侧
    · sample_l 脏                              → 纯逻辑 bug，可在几分钟内迭代
"""
import os
import numpy as np

P = r"D:\code\fpga-synthesizer\folder-reorg\scratch\agent\probe_full.txt"


def load():
    a = []
    nx = [0, 0, 0, 0]
    for line in open(P, encoding="utf-8", errors="ignore"):
        p = line.split()
        if len(p) < 4:
            continue
        row = []
        for i in range(4):
            try:
                row.append(int(p[i]))
            except ValueError:
                row.append(0)          # 'x' / 'z' → 记 0，并单独统计
                nx[i] += 1
        a.append(row)
    if any(nx):
        print("!! dump 中有未初始化(X)的值：sample_l=%d  voice_aud0=%d  dbg_va_r=%d  ch_l=%d"
              % tuple(nx))
    return np.array(a, dtype=np.int64)


def stats(name, y, fs=48000.0, full=32768.0):
    n = len(y)
    print("  %-10s n=%-5d  min=%9d max=%9d  mean=%9.0f  峰峰=%.1f%%FS"
          % (name, n, y.min(), y.max(), y.mean(), 100.0 * (y.max() - y.min()) / (2 * full)))
    d = np.diff(y)
    if d.std() > 0:
        print("              |Δ|max=%.0f  RMS(Δ)=%.0f  比值=%.1f  （干净周期波约 3~6）"
              % (np.abs(d).max(), d.std(), np.abs(d).max() / d.std()))
    clip = int(np.sum(np.abs(y) >= full - 8))
    print("              接近满量程(|x|>=%d)的采样 = %d" % (full - 8, clip))


def spectrum(name, y, fs=48000.0, fmin=100, fmax=1200):
    n = len(y)
    a = (y - y.mean()) * np.hanning(n)
    X = np.abs(np.fft.rfft(a))
    f = np.fft.rfftfreq(n, 1.0 / fs)
    df = fs / n
    band = (f > fmin) & (f < fmax)
    k = np.argmax(np.where(band, X, 0))
    # 抛物线细化
    if 1 <= k < len(X) - 1:
        y0, y1, y2 = np.log(X[k - 1] + 1e-9), np.log(X[k] + 1e-9), np.log(X[k + 1] + 1e-9)
        dd = 0.5 * (y0 - y2) / (y0 - 2 * y1 + y2)
    else:
        dd = 0.0
    f0 = (k + dd) * df
    A0 = X[k]
    print("  %-10s 基频 %.2f Hz（分辨率 %.1f Hz）" % (name, f0, df))
    tot = np.sum(X[band] ** 2)
    harm = 0.0
    for h in range(1, 9):
        fh = f0 * h
        if fh >= fs / 2:
            break
        kh = int(round(fh / df))
        Ah = X[max(0, kh - 1):kh + 2].max() if kh < len(X) else 0
        harm += Ah ** 2
        if h <= 6:
            print("      %dF=%7.2f Hz : %+6.1f dB" % (h, fh, 20 * np.log10(Ah / A0 + 1e-12)))
    # 非谐波能量（1~8 kHz 内、避开谐波 ±3 bin）
    mask = (f > 500) & (f < 8000)
    for h in range(1, 17):
        kh = int(round(f0 * h / df))
        mask[max(0, kh - 3):kh + 4] = False
    noise = np.sqrt(np.sum(X[mask] ** 2))
    print("      非谐波能量(0.5~8kHz) 相对基频 = %.1f dB" % (20 * np.log10(noise / (A0 + 1e-12) + 1e-12)))
    print("      谐波/总能量 = %.1f%%" % (100.0 * harm / (tot + 1e-12)))


a = load()
print("dump 行数 = %d  （约 %.1f ms @48 kHz）" % (len(a), len(a) / 48.0))
if len(a) < 100:
    raise SystemExit("数据太少，仿真可能没跑完")

sl, va0, vas, chl = a[:, 0], a[:, 1], a[:, 2], a[:, 3]

print("\n=== 1. 全局统计 ===")
stats("sample_l", sl, full=32768)
stats("voice_aud0", va0, full=8388608)
stats("dbg_va_r", vas, full=8388608)
stats("ch_l", chl, full=8388608)

print("\n=== 2. 找发声段（|sample_l| 超过 1%% FS 的地方）===")
thr = 328
idx = np.where(np.abs(sl) > thr)[0]
if len(idx) < 100:
    print("  !! 没有检测到发声段（仿真里可能没有音符 / MIDI 没进）")
    raise SystemExit(0)
i0, i1 = idx[0], idx[-1]
print("  发声区间 = 第 %d ~ %d 帧（%.1f ~ %.1f ms）" % (i0, i1, i0 / 48.0, i1 / 48.0))

#  取中后段（避开起音瞬态）
c0 = i0 + (i1 - i0) // 2
seg = slice(c0, min(c0 + 4800, len(sl)))
print("  分析窗口 = 第 %d ~ %d 帧（%.1f ms）" % (c0, min(c0 + 4800, len(sl)), (min(c0 + 4800, len(sl)) - c0) / 48.0))

print("\n=== 3. 稳态段统计（这就是炸不炸的数字证据）===")
stats("sample_l", sl[seg], full=32768)
stats("ch_l", chl[seg], full=8388608)
stats("dbg_va_r", vas[seg], full=8388608)

print("\n=== 4. 稳态段频谱 ===")
spectrum("sample_l", sl[seg])
spectrum("ch_l", chl[seg])
spectrum("dbg_va_r", vas[seg])

print("\n=== 5. 空闲段（发声之前）—— 探针在空闲时看到什么 ===")
if i0 > 200:
    stats("sample_l", sl[:i0 - 50], full=32768)
    stats("voice_aud0", va0[:i0 - 50], full=8388608)
    stats("dbg_va_r", vas[:i0 - 50], full=8388608)
else:
    print("  发声太早，没有空闲段可看")
