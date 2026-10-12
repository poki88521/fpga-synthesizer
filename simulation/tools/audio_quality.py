#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
audio_quality.py —— 主输出链的音频质量分析（THD / SNR / ENOB）

配合 `sim/tb_audio_quality.v`：TB 把 16 位输出样本写成 CSV，
本脚本做 FFT 并算出：

    · 基波幅度 / 频率
    · **THD**   = 各次谐波能量和 / 基波能量
    · **SNR**   = 基波能量 /（总能量 − 基波 − 谐波）
    · **THD+N** =（谐波 + 噪声）/ 基波
    · **ENOB**  = (SINAD − 1.76) / 6.02     有效位数
    · SFDR     最大杂散相对基波

为什么不用 numpy：本环境没装（也没有 pip 源），所以自带一个基 2 迭代 FFT。
65536 点的纯 Python FFT 约几秒，够用。

用法：
    python3 sim/audio_quality.py                      # 读 out/audio_quality.csv
    python3 sim/audio_quality.py 文件.csv --fs 48000 --fund 997
"""

import argparse
import cmath
import math
import os
import sys

# ---- 路径定位（适配 verify/sim/ 的新布局）----------------------------
#  ⚠ 工程可能被整体移动、或在 `verify/sim/` 与 `sim/` 两种布局之间改，
#    所以 ROOT 不能写死层数 —— 用"找标志文件"的方式定位工程根。
HERE = os.path.dirname(os.path.abspath(__file__))


def _find_root(start):
    """向上找含 `rtl/` 目录的那一层，即工程根"""
    d = start
    for _ in range(5):
        if os.path.isdir(os.path.join(d, "rtl")):
            return d
        d = os.path.dirname(d)
    return os.path.dirname(start)


ROOT = _find_root(HERE)
VERIFY = HERE if os.path.basename(ROOT) == os.path.basename(os.path.dirname(HERE)) else HERE


def fft_inplace(a):
    """迭代式基 2 FFT（cooley-tukey），a 会被原地修改"""
    n = len(a)
    if n & (n - 1):
        raise ValueError("长度必须是 2 的幂")
    # 位反转置换
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            a[i], a[j] = a[j], a[i]
    # 蝶形
    length = 2
    while length <= n:
        ang = -2 * math.pi / length
        wl = complex(math.cos(ang), math.sin(ang))
        half = length >> 1
        for i in range(0, n, length):
            w = 1 + 0j
            for k in range(i, i + half):
                u = a[k]
                v = a[k + half] * w
                a[k] = u + v
                a[k + half] = u - v
                w *= wl
        length <<= 1


def hann_window(n):
    """Hann 窗（减少频谱泄漏；分析时用等效噪声带宽校正幅度）"""
    return [0.5 - 0.5 * math.cos(2 * math.pi * i / n) for i in range(n)]


def main():
    ap = argparse.ArgumentParser(description="主输出链音频质量分析")
    ap.add_argument("csv", nargs="?", default=os.path.join(ROOT, "out", "audio_quality.csv"))
    ap.add_argument("--fs", type=float, default=48000.0, help="采样率 Hz")
    ap.add_argument("--fund", type=float, default=997.0, help="基波频率 Hz（要与 TB 一致）")
    ap.add_argument("--n-harm", type=int, default=12, help="统计多少次谐波")
    ap.add_argument("--no-window", action="store_true", help="不加窗（要求相干采样）")
    args = ap.parse_args()

    if not os.path.exists(args.csv):
        print(f"找不到 {args.csv} —— 先跑 `vvp` 生成它"); return 1

    xs = []
    for line in open(args.csv):
        line = line.strip()
        if line:
            try:
                xs.append(int(line))
            except ValueError:
                pass
    n = len(xs)
    if n < 1024:
        print(f"样本太少（{n}）"); return 1
    # FFT 长度取不超过 n 的最大 2 的幂
    nfft = 1
    while nfft * 2 <= n:
        nfft *= 2
    xs = xs[:nfft]

    mean = sum(xs) / nfft
    x = [v - mean for v in xs]
    full = 32768.0

    win = [1.0] * nfft if args.no_window else hann_window(nfft)
    cg = sum(win) / nfft                               # 窗的相干增益
    a = [complex(x[i] * win[i], 0.0) for i in range(nfft)]
    fft_inplace(a)

    half = nfft // 2
    bin_hz = args.fs / nfft
    mag = [abs(a[i]) / (nfft * cg) * 2 for i in range(half)]   # 单边幅度（相对满量程）

    # 基波 bin（找基波附近的峰值，避免频率不精确）
    fb = int(round(args.fund / bin_hz))
    lo, hi = max(1, fb - 3), min(half - 1, fb + 3)
    k0 = max(range(lo, hi + 1), key=lambda i: mag[i])
    f0 = k0 * bin_hz
    p_fund = mag[k0] ** 2

    # 谐波：每个谐波取附近 ±2 bin 的最大（含泄漏）
    harm = 0.0
    harm_list = []
    for h in range(2, args.n_harm + 1):
        kb = int(round(h * f0 / bin_hz))
        if kb >= half:
            break
        lo, hi = max(1, kb - 2), min(half - 1, kb + 2)
        kk = max(range(lo, hi + 1), key=lambda i: mag[i])
        harm += mag[kk] ** 2
        harm_list.append((h, h * f0, mag[kk]))

    # 总能量（排除 DC 与基波 ±3 bin 的泄漏）
    tot = 0.0
    for i in range(1, half):
        if abs(i - k0) <= 3:
            continue
        tot += mag[i] ** 2

    p_noise = max(tot - harm, 1e-30)

    def db(v):
        return 10 * math.log10(v) if v > 0 else -999.0

    thd = math.sqrt(harm / p_fund) if p_fund > 0 else 0
    snr = math.sqrt(p_fund / p_noise) if p_noise > 0 else 0
    sinad = math.sqrt(p_fund / (harm + p_noise))
    enob = (20 * math.log10(sinad) - 1.76) / 6.02 if sinad > 0 else 0
    sfdr = max((m for _, _, m in harm_list), default=0.0) / mag[k0] if mag[k0] else 0

    fund_dbfs = 20 * math.log10(mag[k0] / full) if mag[k0] > 0 else -999

    print("=" * 68)
    print("  主输出链音频质量分析")
    print("=" * 68)
    print(f"  样本数        {nfft}（FFT 长度）")
    print(f"  基波          {f0:.2f} Hz   幅度 {fund_dbfs:.2f} dBFS")
    print(f"  加窗          {'无' if args.no_window else 'Hann'}")
    print()
    print(f"  基波功率      {db(p_fund):8.2f} dB")
    print(f"  谐波功率      {db(harm):8.2f} dB      （{args.n_harm} 次以内）")
    print(f"  噪声功率      {db(p_noise):8.2f} dB")
    print()
    print(f"  THD           {20*math.log10(thd) if thd>0 else -999:8.2f} dB   ({thd*100:.4f} %)")
    print(f"  SNR           {20*math.log10(snr) if snr>0 else -999:8.2f} dB")
    print(f"  THD+N         {20*math.log10(math.sqrt((harm+p_noise)/p_fund)):8.2f} dB")
    print(f"  SINAD         {20*math.log10(sinad):8.2f} dB")
    print(f"  ENOB          {enob:8.2f} bit")
    print(f"  SFDR          {20*math.log10(sfdr) if sfdr>0 else -999:8.2f} dBc")
    print()
    print("  前几次谐波：")
    for h, f, m in harm_list[:8]:
        print(f"    {h:2d} 次  {f:8.1f} Hz   {20*math.log10(m/full) if m>0 else -999:8.2f} dBFS")
    print()
    print("  参考：理想 16 bit 的理论极限")
    print(f"    SNR/THD+N ≈ 6.02×16 + 1.76 = {6.02*16+1.76:.2f} dB   ENOB = 16 bit")
    print(f"    实测 ENOB {enob:.2f} bit → {'✓ 达到 16 bit 地板附近' if enob > 14.5 else '⚠ 明显低于理论值，需查'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
