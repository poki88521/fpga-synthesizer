# -*- coding: utf-8 -*-
"""
rec_analyze.py —— 直接分析上板录音（比仿真强得多：这是真实硬件输出）

用法：
    python rec_analyze.py <wav> [<wav> ...] [--win 0.25] [--gap 0.05]

对每个文件：
  1) 基本信息（fs / 声道 / 位深 / 时长）
  2) 找出"有声"的稳定段（按 RMS 门限切成段），逐段做：
       - PSD（Welch）→ 强峰 + 最强非谐波
       - 包络谱（Hilbert + 去线性趋势 + Hann Welch）→ 调制频率与深度
       - 边带：每个强峰 ±Δ 内最强侧峰，打印 Δf 与载波频率，便于判断
         "Δ 随载波成比例（声学拍频）" 还是 "Δ 恒定（伪影）"
  3) 汇总所有文件里出现过的"调制峰"，看是否有一个**固定频率**反复出现
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
        x = (x.astype(np.float64) - 2 ** (8 * x.dtype.itemsize - 1)) / float(2 ** (8 * x.dtype.itemsize - 1))
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


def welch(x, fs, nper, detrend="constant"):
    nper = int(min(nper, x.size))
    if nper < 64:
        return np.array([0.0]), np.array([0.0])
    return sps.welch(x, fs=fs, window="hann", nperseg=nper,
                     noverlap=nper // 2, detrend=detrend, scaling="density")


def pk_list(f, p, fmin, fmax, n=8, rel_db=-45.0):
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


def segments(x, fs, thr_db=-30.0, min_ms=120.0):
    """按 10 ms 块的 RMS 找出稳定有声段"""
    blk = max(1, int(0.010 * fs))
    nb = x.size // blk
    if nb < 4:
        return []
    r = np.array([np.sqrt(np.mean(x[i * blk:(i + 1) * blk] ** 2)) for i in range(nb)])
    ref = r.max() + 1e-12
    db = 20 * np.log10(r / ref + 1e-12)
    on = db > thr_db
    segs = []
    i = 0
    while i < nb:
        if on[i]:
            j = i
            while j < nb and on[j]:
                j += 1
            if (j - i) * 10.0 >= min_ms:
                segs.append((i * blk, j * blk))
            i = j
        else:
            i += 1
    return segs


def analyse(path, win_s=0.25):
    fs, x = load_wav(path)
    print("\n" + "=" * 100)
    print("%s   fs=%d  长度 %.2f s  峰值 %.4f FS  RMS %.4f FS"
          % (path.split("\\")[-1].split("/")[-1], fs, x.size / fs,
             np.max(np.abs(x)), np.sqrt(np.mean(x ** 2))))
    segs = segments(x, fs)
    if not segs:
        print("  没有找到有声段")
        return []
    print("  有声段 %d 个（>%.0f ms）：%s"
          % (len(segs), 120, ", ".join("%.2f-%.2fs" % (a / fs, b / fs) for a, b in segs[:6])))
    mods = []
    for si, (a, b) in enumerate(segs[:4]):
        w = int(min(win_s * fs, b - a))
        if w < int(0.1 * fs):
            continue
        s = x[a:a + w]
        nper = int(min(w, 16384))
        f, p = welch(s, fs, nper)
        top = pk_list(f, p, 30, min(8000, fs / 2 - 100), 6, -40)
        print("  --- 段%d  %.2f-%.2fs  (窗 %.0f ms, 分辨率 %.1f Hz) ---"
              % (si, a / fs, (a + w) / fs, 1000 * w / fs, fs / nper))
        print("      谱峰: " + "  ".join("%.1fHz(%.0fdB)" % t for t in top))
        # 包络
        e = np.abs(sps.hilbert(s - s.mean()))
        f2, p2 = welch(detrend_linear(e), fs, nper)
        m = f2 <= 200
        ef, ep = f2[m], p2[m]
        mp = pk_list(ef, ep, 0.5, 200, 6, -30)
        dep = 100 * (np.percentile(e, 98) - np.percentile(e, 2)) / (
            np.percentile(e, 98) + np.percentile(e, 2) + 1e-12)
        print("      包络深度 %.1f%%  调制峰: %s" %
              (dep, "  ".join("%.2fHz(%.0fdB)" % t for t in mp) or "无"))
        for fi, lv in mp:
            if fi > 0.8:
                mods.append((fi, lv, path.split("/")[-1].split("\\")[-1]))
        # 边带
        for fc, lc in top[:4]:
            span = min(200.0, 0.5 * fc)
            mm = (f > fc - span) & (f < fc + span)
            fm, pm = f[mm], p[mm]
            if pm.size < 9:
                continue
            ic = int(np.argmin(np.abs(fm - fc)))
            wd = max(3, int(0.03 * fm.size))
            best = None
            for seg, off in ((pm[:max(1, ic - wd)], 0), (pm[ic + wd + 1:], ic + wd + 1)):
                if seg.size == 0:
                    continue
                j = int(np.argmax(seg))
                lvl = 10 * np.log10(seg[j] / pm[ic] + 1e-30)
                if best is None or lvl > best[0]:
                    best = (lvl, fm[off + j])
            if best and best[0] > -30:
                print("      载波 %8.1f → 侧峰 %8.1f  Δ=%+7.2f Hz  %5.0f dB"
                      % (fc, best[1], best[1] - fc, best[0]))
    return mods


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    win = 0.25
    for a in sys.argv[1:]:
        if a.startswith("--win"):
            win = float(a.split("=")[1])
    allmods = []
    for p in args:
        try:
            allmods += analyse(p, win)
        except SystemExit:
            raise
        except Exception as e:
            print("!! %s 分析失败: %s" % (p, e))
    if allmods:
        print("\n" + "=" * 100)
        print("全部文件里出现的调制峰（freq, dB, 文件）——找“固定频率”")
        allmods.sort(key=lambda t: t[0])
        for fi, lv, fn in allmods:
            print("   %7.2f Hz  %6.0f dB   %s" % (fi, lv, fn))


if __name__ == "__main__":
    main()
