# -*- coding: utf-8 -*-
"""
rec_fm.py —— 测录音里的“音高抖动”(FM/wow) 和“两音拍频”(差频)，区分 AM / FM / 无

做法：
  1) 对每个谐波做带通（±8%），取 Hilbert 相位 → 瞬时频率 → 去线性趋势 → 谱
     ⇒ 若有固定频率的峰 = 音高在抖（FM）；峰随频段成比例 = 声学；恒定 = 伪影/时钟
  2) 直接找“差频包络”：把每根谐波解调后，看两根谐波之间的相位差是否随时间走
     ⇒ 这是真·拍频（两个分音频率不同）的唯一直接证据
  3) 对照：所有强峰两两求差，看是否存在“恒定 Δ”的一对
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


def peaks(f, p, fmin, fmax, n=10, rel_db=-25.0):
    m = (f >= fmin) & (f <= fmax)
    fm, pm = f[m], p[m]
    if pm.size < 5:
        return []
    ref = pm.max()
    idx, _ = sps.find_peaks(pm, height=ref * 10 ** (rel_db / 10), distance=3)
    out = []
    for i in idx:
        out.append((float(fm[i]), float(10 * np.log10(pm[i] / ref + 1e-30))))
    out.sort(key=lambda t: -t[1])
    return out[:n]


def bp_fft(x, fs, fc, bw):
    """
    FFT 域带通（矩形）。⚠ 本机 scipy 的 sosfiltfilt/BLAS 路径会崩（0xC06D007F），
    所以滤波一律走 pocketfft（自包含，安全）。
    """
    n = x.size
    X = np.fft.rfft(x)
    fr = np.fft.rfftfreq(n, 1.0 / fs)
    m = np.abs(fr - fc) <= bw / 2
    X[~m] = 0
    return np.fft.irfft(X, n)


def main():
    path = sys.argv[1]
    seg_s = float(sys.argv[2]) if len(sys.argv) > 2 else 2.0
    dur_s = float(sys.argv[3]) if len(sys.argv) > 3 else 6.0
    fs, x = load_wav(path)
    a = int(seg_s * fs)
    b = min(x.size, a + int(dur_s * fs))
    s = x[a:b]
    print("=" * 100)
    print("%s   分析 %.1f~%.1fs（%.1f s）" % (path, seg_s, b / fs, s.size / fs))

    #  ---- 先定位强谐波 ----
    nper = int(min(s.size, 65536))
    f, p = welch(s, fs, nper)
    cand = peaks(f, p, 150, 4000, 12, -30)
    print("\n强峰（用于逐根测 FM）：")
    for fi, lv in cand:
        print("   %9.2f Hz  %5.0f dB" % (fi, lv))

    #  ---- 每根载波：带通 → 瞬时频率谱 ----
    print("\n[1] 每根载波的瞬时频率抖动（去线性趋势后的谱峰）")
    print("    %-10s %-9s %-9s %-26s %s" % ("载波Hz", "中频Hz", "抖动std", "抖动谱(最强3峰)", "折合音分"))
    for fc, lv in cand[:6]:
        bw = max(6.0, 0.10 * fc)
        y = bp_fft(s, fs, fc, bw)
        z = sps.hilbert(y)
        ph = np.unwrap(np.angle(z))
        fi = np.diff(ph) / (2 * np.pi) * fs
        fi = detrend_linear(fi)
        fd, pd = welch(fi, fs, int(min(fi.size, 32768)))
        m = (fd > 0.4) & (fd < 300)
        pk = peaks(fd[m], pd[m], 0.4, 300, 3, -12)
        std = np.std(fi)
        cents = 1200 * np.log2(1 + std / fc) if fc > 0 else 0
        print("    %-10.1f %-9.1f %-9.2f %-26s %.2f cent" %
              (fc, np.mean(fi) + fc, std,
               "  ".join("%.2fHz(%.0fdB)" % t for t in pk), cents))

    #  ---- 差频：所有强峰两两之差 ----
    print("\n[2] 强峰两两之差（找“恒定 Δ”的一对 = 真拍频）")
    rows = []
    for i in range(len(cand)):
        for j in range(i + 1, len(cand)):
            rows.append((abs(cand[i][0] - cand[j][0]), cand[i][0], cand[j][0],
                         min(cand[i][1], cand[j][1])))
    rows.sort()
    for d, f1, f2, lv in rows[:12]:
        print("    Δ=%8.3f Hz   (%.2f, %.2f)   较弱者 %.0f dB" % (d, f1, f2, lv))

    #  ---- 直接估“拍频”：把两根最靠近的强峰解调，看包络 ----
    print("\n[3] 直接测两音拍频：cos(Δ) 的周期")
    for i in range(min(4, len(cand))):
        for j in range(i + 1, min(4, len(cand))):
            f1, f2 = cand[i][0], cand[j][0]
            d = abs(f1 - f2)
            if d > 300 or d < 1:
                continue
            print("    对 (%.2f, %.2f): Δ=%.3f Hz  → 若为拍频，周期 %.1f ms"
                  % (f1, f2, d, 1000 / d))


if __name__ == "__main__":
    main()
