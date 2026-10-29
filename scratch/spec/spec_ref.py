# -*- coding: utf-8 -*-
"""
spec_ref.py —— 32 频带频谱：浮点黄金参考 + 定点可行性调查
------------------------------------------------------------------
目的（交接文档第 1 步）：在碰 RTL 之前，用浮点确认
  · 频带划分 f_i = 60*(16000/60)^(i/31)
  · Goertzel 幅度必须用 sqrt(y1^2 + y2^2 - 2cos*w*y1*y2)，不是 |y1|
  · dB -> 柱高(0..100 px) 的映射
  · 各测试信号的"期望柱高"

同时（第 2 步的前置调查）：
  · 定点 Q14 系数表是否正确（和现有 RTL 表对比）
  · 状态位宽需要多少（会不会溢出）

采样率 48000 Hz（全系统 49.152 MHz 音频域，sample_stb 每 1024 拍）
"""

import numpy as np

FS = 48000
NB = 32
F_LO, F_HI = 60.0, 16000.0
FREQS = F_LO * (F_HI / F_LO) ** (np.arange(NB) / (NB - 1))

# 现有 rtl/vis/spec_band.v 里的 Q14 表（2cos(w) * 2^14）
RTL_TABLE = np.array([
    32767, 32767, 32766, 32765, 32764, 32762, 32759, 32755,
    32750, 32742, 32731, 32715, 32692, 32659, 32611, 32543,
    32446, 32306, 32107, 31821, 31413, 30831, 30003, 28828,
    27168, 24841, 21609, 17187, 11267,  3602, -5810, -16384], dtype=np.int64)


def omega(f):
    return 2.0 * np.pi * np.asarray(f, dtype=float) / FS


def coeff_q14(freq=None):
    """Q14 的 2cos(w)"""
    f = FREQS if freq is None else np.asarray(freq, dtype=float)
    return np.round(2.0 * np.cos(omega(f)) * 16384.0).astype(np.int64)


# =====================================================================
#  1. 系数表核对
# =====================================================================
def check_table():
    mine = coeff_q14()
    diff = mine - RTL_TABLE
    bad = np.nonzero(diff != 0)[0]
    print("=" * 70)
    print("1. Q14 系数表核对（本脚本公式 vs 现有 RTL 表）")
    print("-" * 70)
    if len(bad) == 0:
        print("  ✔ 32 项完全一致 —— 现有 RTL 的系数表和 f_i 公式、fs=48k 完全吻合")
    else:
        print("  ✘ 不一致的项：")
        for i in bad:
            print("     band %2d  f=%9.2f Hz  公式=%6d  RTL=%6d  差=%d"
                  % (i, FREQS[i], mine[i], RTL_TABLE[i], diff[i]))
    # 另外验证：表里存的是 2cos 还是 cos，移位量是 14 还是 15
    print("-" * 70)
    for name, cand in [("2cos*2^14", np.round(2.0*np.cos(omega(FREQS))*16384)),
                       ("2cos*2^15", np.round(2.0*np.cos(omega(FREQS))*32768)),
                       ("cos*2^15",  np.round(1.0*np.cos(omega(FREQS))*32768))]:
        err = np.abs(cand - RTL_TABLE).max()
        print("  假设表的语义 = %-10s  最大偏差 = %9.1f" % (name, err))
    print("  ⇒ 偏差为 0 的那个假设才是真语义；移位量必须与之配套")
    print()


# =====================================================================
#  2. 浮点 Goertzel 块处理（与 RTL 的"每窗复位"一致）
# =====================================================================
def goertzel_block_float(seg, freq=FREQS):
    """返回每个频带的 |X(f)| 幅度（未归一化）"""
    c = 2.0 * np.cos(omega(freq))
    y1 = np.zeros(len(freq))
    y2 = np.zeros(len(freq))
    for xn in seg:
        y = xn + c * y1 - y2
        y2 = y1
        y1 = y
    mag2 = y1 * y1 + y2 * y2 - c * y1 * y2
    return np.sqrt(np.maximum(mag2, 0.0)), y1, y2


def bars_from_mag(mag, N, db_lo=-72.0, db_hi=-6.0):
    """幅度 -> dB -> 0..100 px
       归一化：满刻度正弦（幅度 32768）在其频带中心给出 mag = A*N/2
       ⇒ 令 ref = 32768*N/2，则 level = 20log10(mag/ref) 即相对满刻度正弦的 dB
    """
    ref = 32768.0 * N / 2.0
    with np.errstate(divide='ignore'):
        db = 20.0 * np.log10(np.maximum(mag, 1e-9) / ref)
    px = (db - db_lo) / (db_hi - db_lo) * 100.0
    return np.clip(px, 0.0, 100.0), db


# =====================================================================
#  3. 测试信号
# =====================================================================
def sig_sine(f0, amp, n, phase0=0.0):
    t = np.arange(n)
    return amp * np.sin(2*np.pi*f0*t/FS + phase0)


def sig_noise(amp, n, seed=1):
    rng = np.random.default_rng(seed)
    return np.clip(rng.standard_normal(n) * amp, -32768, 32767)


def sig_sweep(f0, f1, amp, n):
    """对数扫频"""
    t = np.arange(n) / FS
    T = n / FS
    k = np.log(f1 / f0) / T
    ph = 2*np.pi*f0*(np.exp(k*t) - 1.0)/k
    return amp * np.sin(ph)


# =====================================================================
#  4. v3 的错法复现：柱高 = msb(|y1|)
# =====================================================================
def v3_bars(y1):
    """复现 v3：raw_h = (msb(|y1|)-6)*5，截 100，指数式压扩"""
    a = np.abs(y1).astype(np.int64)
    lvl = np.zeros_like(a)
    for i, v in enumerate(a):
        n = int(v)
        lvl[i] = (n.bit_length() - 1) if n > 0 else 0
    raw = np.where(lvl > 6, (lvl - 6) * 5, 0)
    return np.clip(raw, 0, 100)


# =====================================================================
#  5. 定点：状态位宽调查（最重要的一步，决定 RTL 里 y1/y2 多少位）
# =====================================================================
def survey_bitwidth(N=1024):
    """
    对"最坏情况"输入测 max|y1|, max|y2|：
      · 满刻度正弦正好落在每个频带中心（共振点，增益最大 = 1/sin(w)）
    这是 Goertzel 幅度最大的情形。据此决定状态位宽。
    """
    print("=" * 70)
    print("5. 状态位宽调查（N=%d，满刻度 32767 正弦逐个打在频带中心）" % N)
    print("-" * 70)
    print("  band       f(Hz)    max|y1|      log2     max|y2|      log2")
    worst = 0.0
    for i, f in enumerate(FREQS):
        # 输入正弦频率取频带中心，相位/长度都扫一遍取最大
        seg_best = 0.0
        for ph0 in (0.0, 0.7, 1.6, 2.9):
            x = sig_sine(f, 32767.0, N, ph0)
            _, y1, y2 = goertzel_block_float(x, [f])
            seg_best = max(seg_best, abs(y1[0]), abs(y2[0]))
        worst = max(worst, seg_best)
        if i < 4 or i > 27 or i % 8 == 0:
            print("  %3d  %9.2f  %11.4g  %6.2f  %11.4g" % (i, f, seg_best,
                  np.log2(max(seg_best, 1e-9)), seg_best))
    print("-" * 70)
    print("  全局 max|y| = %.4g   log2 = %.2f" % (worst, np.log2(worst)))
    print("  int32 上限 2^31 = %.4g  ->  %s"
          % (2**31, "够" if worst < 2**31 else "**溢出**"))
    print("  结论：位宽建议 %d 位（含 1 位符号）"
          % (int(np.ceil(np.log2(max(worst, 1.0)))) + 2))
    print()
    return worst


# =====================================================================
#  主流程
# =====================================================================
def main():
    check_table()

    N = 1024
    print("=" * 70)
    print("2-4. 浮点黄金参考（N=%d，窗长 %.2f ms，刷新 %.1f Hz）"
          % (N, N/FS*1000, FS/N))
    print("-" * 70)

    cases = [
        ("1 kHz 正弦 0.61FS (amp=20000)", sig_sine(1000.0, 20000.0, N)),
        ("261.6 Hz C4 正弦 (amp=20000)", sig_sine(261.63, 20000.0, N)),
        ("白噪 ±20000", sig_noise(6000.0, N)),
        ("200 Hz -> 8 kHz 对数扫频 (amp=20000)", sig_sweep(200.0, 8000.0, 20000.0, N)),
    ]

    for name, x in cases:
        mag, y1, y2 = goertzel_block_float(x)
        px, db = bars_from_mag(mag, N)
        b = np.argmax(px)
        print("\n  【%s】" % name)
        print("     峰值柱 band %d (%.0f Hz) 高 %.0f px (%.1f dBFS-ish)"
              % (b, FREQS[b], px[b], db[b]))
        print("     dB : " + " ".join("%5.1f" % d for d in db))
        print("     px : " + " ".join("%5.0f" % p for p in px))
        # v3 的错法
        v3 = v3_bars(y1)
        print("     v3错法(msb|y1|) px: " + " ".join("%5.0f" % p for p in v3)
              + "   <-- 峰值 band %d" % int(np.argmax(v3)))

    survey_bitwidth(N)


if __name__ == "__main__":
    main()
