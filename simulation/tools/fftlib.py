#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fftlib.py —— 共享 FFT 与频谱工具（sakiko）

为什么独立成库：`audio_quality.py` / `stage_noise.py` / 各种临时分析都用同一套
FFT + 相干采样工具。本项目的教训是**工具重复实现容易造成"同一个量两处报不同值"**
（例如把 31 个乘法器误报成 13），所以抽成一份共享库。

本环境没有 numpy、也没有 pip 源，所以自带一个基 2 迭代 FFT。

关键约定（踩过坑，务必遵守）：
  · **测 SNR/THD 必须用相干采样**（整数个周期落在 FFT 窗内）+ 矩形窗。
    非相干采样时窗泄漏会在整个频域"垫高"噪声底 —— 实测同一个理想正弦，
    非相干 + Hann 窗报 SNR 43.8 dB，相干 + 矩形窗报 86.06 dB（理论 86.05）。
  · 基线必须**去掉瞬态**：主音量有 ±64/采样的斜坡，512 个样本才走完；
    测量窗口若含过渡段，SNR 会假性崩到 25 dB。
"""

import math


def fft_inplace(a):
    """迭代式基 2 FFT（Cooley-Tukey），原地修改 a（长度须为 2 的幂）"""
    n = len(a)
    if n & (n - 1):
        raise ValueError("FFT 长度必须是 2 的幂")
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


def hann(n):
    """Hann 窗（仅用于非相干场景的幅度谱观察；不要用它测 SNR）"""
    return [0.5 - 0.5 * math.cos(2 * math.pi * i / n) for i in range(n)]


def mag_spectrum(xs, window=None):
    """单边幅度谱（相对满量程 1.0）。window=None → 矩形窗（相干测量用这个）"""
    n = len(xs)
    cg = 1.0 if window is None else (sum(window) / n)
    a = [complex(xs[i] * (window[i] if window else 1.0), 0.0) for i in range(n)]
    fft_inplace(a)
    return [abs(a[i]) / (n * cg) * 2 for i in range(n // 2)]


def coherent_freq(cycles, fs, n):
    """相干采样频率：整数个周期落在长度为 n 的窗内"""
    return cycles * fs / n


def load_csv_ints(path, n=None):
    """读 TB 写的单列整数 CSV"""
    xs = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    xs.append(int(line))
                except ValueError:
                    pass
    return xs[:n] if n else xs


def snr_thd(mag, k_fund, n_harm=12, full=32768.0):
    """从幅度谱算 SNR / THD / SINAD / ENOB。**要求相干采样**"""
    half = len(mag)
    p_fund = mag[k_fund] ** 2
    p_all = 0.0
    for i in range(1, half):
        if i == k_fund:
            continue
        p_all += mag[i] ** 2
    harm = 0.0
    for h in range(2, n_harm + 1):
        kb = h * k_fund
        if kb < half:
            harm += mag[kb] ** 2
    p_noise = max(p_all - harm, 1e-30)
    snr = 10 * math.log10(p_fund / p_noise) if p_noise > 0 else 999.0
    thd = math.sqrt(harm / p_fund) if p_fund > 0 else 0.0
    sinad = 10 * math.log10(p_fund / (harm + p_noise)) if (harm + p_noise) > 0 else 999.0
    return {
        "snr": snr,
        "thd_db": 20 * math.log10(thd) if thd > 0 else -999.0,
        "sinad": sinad,
        "enob": (sinad - 1.76) / 6.02,
        "fund_dbfs": 20 * math.log10(mag[k_fund] / full) if mag[k_fund] > 0 else -999.0,
    }
