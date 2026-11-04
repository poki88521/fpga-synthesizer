#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
analyze_probe4.py —— “和弦震荡感”四点探针数据分析（v3）

输入（tb_probe4 导出）：
    <tag>_voice.txt : frame slot e0..e7 a0..a7   （每帧 4 行；e=env Q1.15, a=voice_out Q1.23）
    <tag>_chan.txt  : frame ch L R               （每帧 16 行）
    <tag>_mix.txt   : frame L R                  （每帧 1 行）
    <tag>_out.txt   : frame L R                  （每帧 1 行，16 bit）

⚠ v3 修的关键 bug：voice 每帧 4 行、chan 每帧 16 行，必须按 slot / ch 字段
   **精确落位**，不能按行号顺序覆盖（v1/v2 那样会把 4 个时隙/16 个通道互相冲掉）。

分析：
  A 四点幅度统计
  B 功率谱：强峰 + 最强非谐波分量
  C 包络谱：调制频率与深度（“震荡感”的直接量化）
  D 边带：Δf 是否随载波成比例（成比例=声学拍频；恒定=伪影）
  E 逐 (slot,lane)：env 轨迹（查重触发/台阶）+ 包络反演后的调制
  F 瞬时频率：查“音高晃动(wow)”——固定速率的音高抖动也会被听成“震荡”
"""
import argparse
import os

import numpy as np
from scipy import signal as sps
from scipy.io import wavfile

FULL24 = 8388608.0
FS_DEF = 48000.0


def read_rows(path, ncol):
    rows = []
    for ln in open(path, "r"):
        s = ln.split()
        if len(s) == ncol and "x" not in ln:
            rows.append(s)
    if not rows:
        raise SystemExit("空/格式不符: " + path)
    return np.array(rows, dtype=np.int64)


def frame_span(path, ncol):
    a = read_rows(path, ncol)
    return int(a[:, 0].min()), int(a[:, 0].max())


def load_voice(path):
    a = read_rows(path, 18)
    f0, f1 = int(a[:, 0].min()), int(a[:, 0].max())
    n = f1 - f0 + 1
    aud = np.full((n, 32), np.nan)
    env = np.full((n, 32), np.nan)
    slot_rows = np.zeros(n)
    for r in range(a.shape[0]):
        fi = int(a[r, 0]) - f0
        s = int(a[r, 1])
        slot_rows[fi] = s
        for lane in range(8):
            env[fi, s * 8 + lane] = a[r, 2 + lane]
            aud[fi, s * 8 + lane] = a[r, 10 + lane]
    return f0, n, aud, env, slot_rows


def load_chan(path):
    a = read_rows(path, 4)
    f0, f1 = int(a[:, 0].min()), int(a[:, 0].max())
    n = f1 - f0 + 1
    L = np.full((n, 16), np.nan)
    R = np.full((n, 16), np.nan)
    for r in range(a.shape[0]):
        L[int(a[r, 0]) - f0, int(a[r, 1])] = a[r, 2]
        R[int(a[r, 0]) - f0, int(a[r, 1])] = a[r, 3]
    return f0, n, L, R


def load_single(path):
    a = read_rows(path, 3)
    f0, f1 = int(a[:, 0].min()), int(a[:, 0].max())
    n = f1 - f0 + 1
    X = np.full((n, 2), np.nan)
    X[a[:, 0] - f0, 0] = a[:, 1]
    X[a[:, 0] - f0, 1] = a[:, 2]
    return f0, n, X


def welch(x, fs, nper=8192, detrend="constant"):
    x = np.asarray(x, float)
    nper = int(min(nper, x.size))
    if nper < 32:
        return np.array([0.0]), np.array([0.0])
    return sps.welch(x, fs=fs, window="hann", nperseg=nper,
                     noverlap=nper // 2, detrend=detrend, scaling="density")


def peaks(f, p, fmin, fmax, n=10, rel_db=-50.0):
    m = (f >= fmin) & (f <= fmax)
    fm, pm = f[m], p[m]
    if pm.size < 5:
        return []
    ref = pm.max()
    idx, _ = sps.find_peaks(pm, height=ref * 10 ** (rel_db / 10.0), distance=2)
    res = []
    for i in idx:
        fi = fm[i]
        if 0 < i < pm.size - 1:
            y0, y1, y2 = (np.log(pm[i - 1] + 1e-30), np.log(pm[i] + 1e-30),
                          np.log(pm[i + 1] + 1e-30))
            den = y0 - 2 * y1 + y2
            if abs(den) > 1e-12:
                d = float(np.clip(0.5 * (y0 - y2) / den, -0.5, 0.5))
                fi = fm[i] + d * (fm[1] - fm[0])
        res.append((float(fi), float(10 * np.log10(pm[i] / ref + 1e-30))))
    res.sort(key=lambda t: -t[1])
    return res[:n]


def detrend_linear(x):
    """
    ⚠ 不能用 scipy 的 detrend('linear')：它内部走 np.linalg.lstsq，而本机 numpy 的
       LAPACK DLL 坏了 —— 一调用就 0xC06D007F 崩进程。这里用公式手算最小二乘直线。
    """
    x = np.asarray(x, float)
    n = x.size
    t = np.arange(n, dtype=float)
    tm, xm = t.mean(), x.mean()
    den = np.sum((t - tm) ** 2)
    b = np.sum((t - tm) * (x - xm)) / den if den > 0 else 0.0
    return x - (xm + b * (t - tm))


def env_spec(x, fs, fmax=200.0, nper=8192):
    """
    包络谱。⚠ 抓取窗口落在 ADSR 的 *decay* 段，env 每采样 −1 ⇒ 包络上是**线性**斜坡。
    先手算去掉这条直线，否则 10 Hz 一档会被趋势泄漏淹没。
    """
    x = np.asarray(x, float)
    e = np.abs(sps.hilbert(x - x.mean()))
    f, p = welch(detrend_linear(e), fs, nper, detrend="constant")
    m = f <= fmax
    return f[m], p[m], e


def depth(e):
    lo, hi = np.percentile(e, 2), np.percentile(e, 98)
    return 0.0 if (hi + lo) <= 0 else (hi - lo) / (hi + lo)


def sidebands(f, p, pk, span=40.0, rel_db=-35.0):
    out = []
    for fc, lc in pk:
        m = (f > fc - span) & (f < fc + span)
        fm, pm = f[m], p[m]
        if pm.size < 9:
            continue
        ic = int(np.argmin(np.abs(fm - fc)))
        w = max(3, int(0.02 * fm.size))
        best = None
        for seg, off in ((pm[:max(1, ic - w)], 0), (pm[ic + w + 1:], ic + w + 1)):
            if seg.size == 0:
                continue
            j = int(np.argmax(seg))
            lvl = 10 * np.log10(seg[j] / pm[ic] + 1e-30)
            if best is None or lvl > best[0]:
                best = (lvl, fm[off + j])
        if best and best[0] >= rel_db:
            out.append((fc, best[1], best[1] - fc, best[0]))
    return out


def inst_freq(x, fs):
    """解析信号相位的导数 → 瞬时频率（Hz）"""
    x = np.asarray(x, float)
    z = sps.hilbert(x - x.mean())
    ph = np.unwrap(np.angle(z))
    fi = np.diff(ph) / (2 * np.pi) * fs
    return fi


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prefix", required=True)
    ap.add_argument("--fs", type=float, default=FS_DEF)
    ap.add_argument("--outdir", default=None)
    ap.add_argument("--nper", type=int, default=4096)
    a = ap.parse_args()
    fs, pre = a.fs, a.prefix
    outdir = a.outdir or os.path.dirname(pre) or "."
    os.makedirs(outdir, exist_ok=True)
    L = []

    def P(s=""):
        print(s)
        L.append(s)

    _, nv, v_aud, v_env, slot_rows = load_voice(pre + "_voice.txt")
    _, nc, chL, chR = load_chan(pre + "_chan.txt")
    _, nm, mix = load_single(pre + "_mix.txt")
    _, no, out = load_single(pre + "_out.txt")
    n = min(nv, nc, nm, no)

    P("=" * 96)
    P("前缀 %s   %d 帧 = %.2f ms @%.0f Hz   (fs=%.1f)" %
      (os.path.basename(pre), n, 1000 * n / fs, fs, fs))
    P("=" * 96)

    v_mono = np.nansum(v_aud[:n], axis=1)
    csum = np.nansum(chL[:n], axis=1)
    taps = [("1 voice_mono(32声部之和)", v_mono, FULL24),
            ("2 chan_layer(16通道之和)", csum, FULL24),
            ("3 main_mix.L",             mix[:n, 0], FULL24),
            ("4 master_chain.L",         out[:n, 0], 32768.0)]

    P("\n## A. 四点幅度（1 ms 级校准数据里噪声占比大，看趋势即可）")
    P("%-26s %9s %9s %7s %9s %6s %7s" % ("点", "峰值FS", "RMS FS", "峰均比", "直流FS", "削顶", ">25%跳"))
    for name, x, full in taps:
        xs = np.nan_to_num(np.asarray(x, float))
        pk = np.max(np.abs(xs)) / full
        rms = np.sqrt(np.mean(xs ** 2)) / full
        P("%-26s %9.5f %9.5f %7.2f %+9.5f %6d %7d" %
          (name, pk, rms, pk / (rms + 1e-12), np.mean(xs) / full,
           int(np.sum(np.abs(xs) >= 0.999 * full)),
           int(np.sum(np.abs(np.diff(xs)) > 0.25 * full))))

    P("\n## B. 功率谱（Welch hann, 段长 %d = %.1f Hz 分辨率）" % (a.nper, fs / a.nper))
    specs = {}
    for name, x, full in taps:
        xs = np.nan_to_num(np.asarray(x, float))
        if np.ptp(xs) < 1e-9:
            P("  %s : 全 0" % name)
            continue
        f, p = welch(xs, fs, a.nper)
        specs[name] = (f, p)
        pk = peaks(f, p, 40, min(8000, fs / 2 - 100), 8)
        P("  %-26s %s" % (name, "  ".join("%.1fHz(%.0fdB)" % t for t in pk)))
        if pk:
            f0 = pk[0][0]
            m = (f > 40) & (f < min(8000, fs / 2 - 100))
            fm, pm = f[m], p[m]
            k = np.round(fm / f0)
            msk = (np.abs(fm - k * f0) > 0.015 * f0) | (k < 1)
            if msk.any():
                j = int(np.argmax(pm[msk]))
                P("       非谐波最强 %.1f Hz  %.0f dB re 最强峰" %
                  (fm[msk][j], 10 * np.log10(pm[msk][j] / pm.max() + 1e-30)))

    P("\n## C. 包络谱（调制频率 / 深度）")
    envs_sp = {}
    for name, x, full in taps:
        xs = np.nan_to_num(np.asarray(x, float))
        if np.ptp(xs) < 1e-9:
            continue
        f, p, e = env_spec(xs, fs, 200.0, a.nper)
        envs_sp[name] = (f, p)
        P("  --- %-26s 包络深度 %6.2f%% ---" % (name, 100 * depth(e)))
        P("        " + "  ".join("%.2fHz(%.0fdB)" % t for t in peaks(f, p, 0.5, 200, 6, -35)))
    keys = list(envs_sp.keys())
    if len(keys) >= 2:
        f0 = envs_sp[keys[0]][0]
        P("\n  跨点对比（每点自己最强的调制 = 0 dB）")
        P("  %-9s" % "f(Hz)" + "".join("%17s" % k[:16] for k in keys))
        for i in range(0, f0.size, max(1, f0.size // 20)):
            row = "  %-9.2f" % f0[i]
            for k in keys:
                fk, pkk = envs_sp[k]
                j = int(np.argmin(np.abs(fk - f0[i])))
                v = 10 * np.log10(pkk[j] / pkk.max() + 1e-30)
                row += "%17.1f" % v
            P(row)

    P("\n## D. 边带（Δf 随载波成比例 = 声学拍频；恒定 = 伪影）")
    for name in keys:
        f, p = specs[name]
        pk = peaks(f, p, 40, min(4000, fs / 2 - 100), 5, -35)
        sb = sidebands(f, p, pk, 40.0, -28)
        P("  --- %s ---" % name)
        if not sb:
            P("      40 Hz 内无 ≥-28 dB 侧峰")
        for fc, fi, df, lv in sorted(sb, key=lambda t: -t[3])[:8]:
            P("      载波 %8.1f → 侧峰 %8.1f  Δ=%+7.2f Hz  %5.0f dB" % (fc, fi, df, lv))

    P("\n## E. 逐 (slot,lane)：env 轨迹（查重触发）+ 包络反演后的调制")
    for i in range(32):
        xa, xe = v_aud[:n, i], v_env[:n, i]
        if np.all(np.isnan(xa)) or np.ptp(np.nan_to_num(xa)) < 2000:
            continue
        xa = np.nan_to_num(xa)
        xe = np.nan_to_num(xe)
        #  包络反演：voice_out = svf × env × g_vt  ⇒ 除以 env 得到与包络无关的波形
        g = np.where(xe > 500, xe / 32768.0, np.nan)
        xn = np.nan_to_num(xa / g)
        fi = inst_freq(xa[np.isfinite(g)], fs) if np.isfinite(g).sum() > 64 else np.array([])
        #  重触发判据：env 达到最大值**之后**还有没有“向上跳”（正常 decay/sustain 只会往下/不动）
        imax = int(np.argmax(xe))
        jt = int(np.sum(np.diff(xe[imax:]) > 50))
        #  台阶判据：decay 段每步应该正好 −1（sustain 段 0），统计 |Δ| 的分布
        dd = np.diff(xe[imax:])
        step_bad = int(np.sum(np.abs(dd) > 2))
        #  瞬时频率的抖动（wow）
        if fi.size > 32:
            fmed = np.median(fi)
            fj = fi - fmed
            fe, fep = welch(fj, fs, min(a.nper, fj.size))
            wow = peaks(fe, fep, 0.5, 200, 3, -25)
            wow_txt = "  ".join("%.2fHz(%.0fdB)" % t for t in wow)
        else:
            fmed, wow_txt = 0.0, "-"
        f2, p2 = welch(xn, fs, min(a.nper, 512))
        pk2 = peaks(f2, p2, 40, min(4000, fs / 2 - 100), 3)
        ef, ep, e = env_spec(xn, fs, 200.0, min(a.nper, 512))
        P("      vid %2d (slot %d lane %d): env %5d→%5d | 峰值后上跳>50 = %d  |Δ|>2 的台阶 = %d"
          % (i, i // 8, i % 8, xe[0], xe[-1], jt, step_bad))
        P("            反演后基频 %.1f Hz  反演包络深度 %5.2f%%  调制峰 %s"
          % (pk2[0][0] if pk2 else 0.0, 100 * depth(e),
             "  ".join("%.2fHz(%.0fdB)" % t for t in peaks(ef, ep, 0.5, 200, 3, -25))))
        P("            瞬时频率 %.1f Hz  std=%.1f%%  抖动谱 %s" %
          (fmed, 100 * np.std(fi) / (abs(fmed) + 1e-9) if fi.size else 0.0, wow_txt))

    try:
        for name, x, full in taps:
            xs = np.nan_to_num(np.asarray(x, float))
            if np.ptp(xs) < 1e-9:
                continue
            fn = os.path.join(outdir, os.path.basename(pre) + "_" + name.split(" ")[0] + ".wav")
            wavfile.write(fn, int(fs), (np.clip(xs / full, -1, 1) * 32000).astype(np.int16))
        P("\n  wav → %s" % outdir)
    except Exception as e:
        P("  wav 导出失败: %s" % e)

    rp = os.path.join(outdir, "report_%s.txt" % os.path.basename(pre))
    open(rp, "w", encoding="utf-8").write("\n".join(L) + "\n")
    print("\n报告: %s" % rp)


if __name__ == "__main__":
    main()
