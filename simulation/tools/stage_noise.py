#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
stage_noise.py —— 主输出链**逐级噪声隔离**分析

背景：端到端测得噪声比理论高约 29 dB（−65.5 dBFS vs 理论 −94 dBFS）。
      必须逐级定位是哪一级引入的，不能靠猜。

配合 `sim/tb_stage_noise.v`：同一个相干正弦源分别经过
    ① stage0_raw   直通（理想 24→16 截断，无抖动）
    ② stage1_vol   master_volume
    ③ stage2_lim   + soft_limiter
    ④ stage3_dc    + dc_block
    ⑤ stage4_chain 完整 master_chain
各阶段都换算到"16 位等效"，这样 SNR 可以直接横向比较。

用法：python3 sim/stage_noise.py
"""

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
SIM = os.path.join(ROOT, "sim")
sys.path.insert(0, SIM)

N = 65536
CYCLES = 1361
FS = 48000.0
F0 = CYCLES * FS / N          # 996.8262 Hz（相干）
FULL16 = 32768.0


def fft_inplace(a):
    n = len(a)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            a[i], a[j] = a[j], a[i]
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


def analyze(path, width_shift=0):
    """相干采样 + 矩形窗。width_shift: 读入值要右移几位才是 16 位等效"""
    if not os.path.exists(path):
        return None
    xs = []
    for line in open(path):
        line = line.strip()
        if line:
            try:
                xs.append(int(line))
            except ValueError:
                pass
    if len(xs) < N:
        return None
    xs = xs[:N]
    if width_shift:
        xs = [v >> width_shift for v in xs]

    mean = sum(xs) / N
    x = [v - mean for v in xs]
    a = [complex(v, 0.0) for v in x]
    fft_inplace(a)
    half = N // 2
    mag = [abs(a[i]) / N * 2 for i in range(half)]

    k0 = CYCLES                       # 相干 → 基波正好在第 CYCLES 个 bin
    p_fund = mag[k0] ** 2

    # 相干采样下基波只落在单个 bin，噪声 = 其余所有 bin（排除 DC 与基波）
    p_noise = 0.0
    for i in range(1, half):
        if i == k0:
            continue
        p_noise += mag[i] ** 2
    # 谐波（相干时同样各占一个 bin）
    harm = 0.0
    for h in range(2, 13):
        kb = h * CYCLES
        if kb < half:
            harm += mag[kb] ** 2

    snr = 10 * math.log10(p_fund / p_noise) if p_noise > 0 else 999
    thd = math.sqrt(harm / p_fund) if p_fund > 0 else 0
    sinad = 10 * math.log10(p_fund / (harm + p_noise))
    enob = (sinad - 1.76) / 6.02
    return {
        "fund_dbfs": 20 * math.log10(mag[k0] / FULL16) if mag[k0] > 0 else -999,
        "snr": snr, "thd_db": 20 * math.log10(thd) if thd > 0 else -999,
        "sinad": sinad, "enob": enob,
    }


def main():
    stages = [
        ("① 直通（理想截断，无抖动）", "stage0_raw.csv", 0),
        ("② + master_volume",        "stage1_vol.csv", 0),
        ("③ + soft_limiter",         "stage2_lim.csv", 0),
        ("④ + dc_block",             "stage3_dc.csv", 0),
        ("⑤ 完整 master_chain",       "stage4_chain.csv", 0),
    ]
    print("=" * 76)
    print("  主输出链逐级噪声隔离（相干采样 996.8262 Hz，−12 dBFS）")
    print("=" * 76)
    print(f"  {'阶段':30s} {'基波':>9s} {'SNR':>9s} {'THD':>9s} {'ENOB':>7s}")
    print("  " + "-" * 72)
    prev = None
    for name, f, sh in stages:
        r = analyze(os.path.join(ROOT, "out", f), sh)
        if r is None:
            print(f"  {name:30s}   （缺 {f}）")
            continue
        print(f"  {name:30s} {r['fund_dbfs']:8.2f}dB {r['snr']:8.2f}dB "
              f"{r['thd_db']:8.2f}dB {r['enob']:6.2f}b", end="")
        if prev is not None:
            d = prev - r["snr"]
            print(f"   ← SNR 降 {d:5.1f} dB" if abs(d) > 0.3 else "   ← 无变化")
        else:
            print()
        prev = r["snr"]
    print()
    print("  理论参考（−12 dBFS 信号）")
    print("    理想 16 bit 截断        SNR = 86.05 dB   （6.02×16+1.76−20log10(32768/8192)）")
    print("    + ±256 TPDF 抖动（24 位域）SNR = 82.1 dB  （抖动 RMS 147.8 + 量化 RMS 73.9）")
    print()
    print("  ⚠ 判读：某级 SNR 突然大幅下降 → 就是该级引入的噪声/失真")
    return 0


if __name__ == "__main__":
    sys.exit(main())
