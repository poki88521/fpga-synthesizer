# -*- coding: utf-8 -*-
"""
rec_detail.py —— 对单个录音做“逐层剥”分析
  1) 时域包络（10 ms 块的 RMS）—— 先看“震荡”在时域上长什么样
  2) 低频谱（100~2000 Hz）全部强峰 —— 确认到底弹了哪些音
  3) 长窗包络谱（1~2 s 窗，0.5~1 Hz 分辨率）—— 调制频率到底是多少
  4) 调制深度 vs 窗长 —— 排除“衰减被当成调制”
"""
import sys
import numpy as np
from scipy import signal as sps
from scipy.io import wavfile


def load_wav(path):
    fs, x = wavfile.read(path)
    if x.dtype.kind == 'i':
        x = x.astype(np.float64) / float(2 ** (8 * x.dtype.itemsize - 1))
    elif x.dtype.kind == 'u':
        x = (x.astype(np.float64) - 128.0) / 128.0
    else:
        x = x.astype(np.float64)
    if x.ndim > 1:
        x = x.mean(axis=1)
    return fs, x


def detrend_linear(x):
    n = x.size
    t = np.arange(n, dtype=float)
    tm, xm = t.mean(), x.mean()
    den = np.sum((t - tm) ** 2)
    b = np.sum((t - tm) * (x - xm)) / den if den > 0 else 0.0
    return x - (xm + b * (t - tm))


def welch(x, fs, nper):
    nper = int(min(nper, x.size))
    if nper < 64:
        return np.array([0.0]), np.array([0.0])
    return sps.welch(x, fs=fs, window="hann", nperseg=nper,
                     noverlap=nper // 2, detrend="constant", scaling="density")


def peaks(f, p, fmin, fmax, n=12, rel_db=-30.0):
    m = (f >= fmin) & (f <= fmax)
    fm, pm = f[m], p[m]
    if pm.size < 5:
        return []
    ref = pm.max()
    idx, _ = sps.find_peaks(pm, height=ref * 10 ** (rel_db / 10), distance=2)
    out = []
    for i in idx:
        fi = fm[i]
        if 0 < i < pm.size - 1:
            y0, y1, y2 = (np.log(pm[i - 1] + 1e-30), np.log(pm[i] + 1e-30),
                          np.log(pm[i + 1] + 1e-30))
            den = y0 - 2 * y1 + y2
            if abs(den) > 1e-12:
                d = float(np.clip(0.5 * (y0 - y2) / den, -0.5, 0.5))
                fi = fm[i] + d * (fm[1] - fm[0])
        out.append((float(fi), float(10 * np.log10(pm[i] / ref + 1e-30))))
    out.sort(key=lambda t: -t[1])
    return out[:n]


def main():
    path = sys.argv[1]
    fs, x = load_wav(path)
    N = x.size
    print("=" * 96)
    print("%s  fs=%d  %.2f s  peak=%.4f FS" % (path, fs, N / fs, np.max(np.abs(x))))
    print("=" * 96)

    # --- 1) 时域包络：10 ms 块 RMS ---
    blk = int(0.010 * fs)
    nb = N // blk
    rms = np.sqrt(np.array([np.mean(x[i * blk:(i + 1) * blk] ** 2) for i in range(nb)]))
    print("\n[1] 时域包络（10 ms/点, dB re 最大值）。看有没有周期性起伏：")
    dbv = 20 * np.log10(rms / rms.max() + 1e-12)
    line = ""
    for i in range(0, nb, max(1, nb // 120)):
        c = " .:-=+*#%@"[int(np.clip((dbv[i] + 60) / 60 * 9, 0, 9))]
        line += c
    print("    " + line)
    print("    (10 ms/pt, 共 %.2f s; 字符越靠右=越响)" % (nb * 0.01))
    # 数字版：找稳定段
    print("    前 40 点 dB: " + " ".join("%.0f" % v for v in dbv[:40]))

    # --- 2) 低频谱：确认弹了哪些音 ---
    seg = x[int(2.0 * fs):int(2.0 * fs) + int(min(2.0, N / fs - 2.1) * fs)]
    nper = int(min(seg.size, 32768))
    f, p = welch(seg, fs, nper)
    print("\n[2] 低频谱（窗 %.1f ms, 分辨率 %.2f Hz）100~2500 Hz 强峰：" %
          (1000 * nper / fs, fs / nper))
    low = peaks(f, p, 100, 2500, 25, -45)
    for fi, lv in low:
        #  标出它接近哪个音的哪次分音
        tags = []
        for name, f0 in (("C4", 261.6256), ("E4", 329.6276), ("C5", 523.2511),
                         ("G4", 391.9954), ("Eb4", 311.1270)):
            k = fi / f0
            if abs(k - round(k)) < 0.02 and round(k) >= 1:
                tags.append("%s%dF" % (name, round(k)))
        print("    %9.2f Hz  %6.0f dB   %s" % (fi, lv, " ".join(tags)))

    # --- 3) 长窗包络谱 ---
    print("\n[3] 长窗包络谱（去线性趋势）—— 调制频率：")
    for win in (0.5, 1.0, 2.0):
        w = int(win * fs)
        if w > seg.size:
            continue
        nper2 = int(min(w, 65536))
        e = np.abs(sps.hilbert(seg[:w] - seg[:w].mean()))
        f2, p2 = welch(detrend_linear(e), fs, nper2)
        m = f2 <= 300
        ef, ep = f2[m], p2[m]
        pk = peaks(ef, ep, 0.4, 300, 8, -25)
        dep = 100 * (np.percentile(e, 98) - np.percentile(e, 2)) / (
            np.percentile(e, 98) + np.percentile(e, 2) + 1e-12)
        print("    窗 %.1f s (%.2f Hz 分辨率) 包络深度 %5.1f%% : %s" %
              (win, fs / nper2, dep,
               "  ".join("%.2fHz(%.0fdB)" % t for t in pk) or "无峰"))

    # --- 4) 调制深度 vs 窗长（区分“衰减”与“真调制”）---
    print("\n[4] 相邻 50 ms 块的包络起伏（同一个稳态段内，排除衰减）：")
    st = int(2.5 * fs)
    for k in range(6):
        s = x[st + k * int(0.5 * fs): st + (k + 1) * int(0.5 * fs)]
        if s.size < fs * 0.4:
            break
        e = np.abs(sps.hilbert(s - s.mean()))
        # 50 ms 滑窗包络的起伏
        w50 = int(0.05 * fs)
        ne = e.size // w50
        r = np.array([np.mean(e[i * w50:(i + 1) * w50]) for i in range(ne)])
        print("    %.1f-%.1fs: 50ms 包络 min/max = %.3f/%.3f 起伏 %.1f%%"
              % (2.5 + k * 0.5, 3.0 + k * 0.5, r.min(), r.max(),
                 100 * (r.max() - r.min()) / (r.max() + r.min() + 1e-12)))
        print("        序列: " + " ".join("%.0f" % (1000 * v) for v in r))


if __name__ == "__main__":
    main()
