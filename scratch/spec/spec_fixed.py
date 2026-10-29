# -*- coding: utf-8 -*-
"""
spec_fixed.py —— 定点规格定稿 + 与浮点黄金参考逐位对比（交接文档 第 1、2 步）
==========================================================================
这是写 RTL 前必须锁死的数学。RTL 只做接线，不再有任何算法不确定性。

【为什么必须加窗】矩形窗下，60 Hz 频带的极点几乎在 z=1，等效于对输入求平均，
    1 kHz 单音也能把它顶到 -41 dBFS（≈55 px），32 根柱子里 23 根误亮。
    换成 64 级汉宁窗后低端压到 -78 dB（0 px），误亮 0 根。

【为什么系数要 Q20】2cos(w) 在低频端对极点位置极其敏感：
    Q14 时 60 Hz 与 71.8 Hz 两个频带被量化成**同一个滤波器**（都是 32767），
    最坏频率误差 14.6 Hz，比频带间距 11.85 Hz 还大 —— 这就是 v3 "低频端饱和"的另一半原因。
    Q16→9.4 px, Q18→6.2 px, Q20→3.4 px（判据 < 5 px）⇒ 定 Q20，22 bit 有符号。

定点规格
--------
  FS=48000, N=1024, NB=32, 每采样 1024 拍 @49.152 MHz
  系数    c  = round(2cos(w) * 2^20)        int22，32 项表
  窗      w64= round(hann * 64)             int7(0..64)，64 项表，w[n]=tab[n[9:4]]
  加权    xw = (x * w64) >>> 6
  状态    y1,y2 : 34 bit 有符号（满刻度 60 Hz 单音实测 2.08e9 = 2^31，留 3 位）
  递推    prod = (c*y1 + 2^19) >>> 20
          y1' = wrap34(xw + prod - y2) ;  y2' = y1
  幅度    块浮点 e = max(0, msb(max|y1|,|y2|) - 14)，ys = y >> e  (≤16 bit)
          t = (c*ys2) >>> 20
          mag2 = ys1² + ys2² - t·ys1
  对数    lg = log2_q8(mag2)（5 bit 尾数表，误差 ≤0.14 dB）
          L_Q5 = (lg*385) >>> 10
  电平    level_Q5 = L_Q5 + 192e + ((42e)>>>6) - 4431
          4431 = round(20log10(32768*N/2*mean(w)) * 32)，mean(w)=0.5
  柱高    tt = level_Q5 + 2304 ;  px = clamp((tt*25) >>> 9, 0, 100)
          覆盖 -72 .. -8 dBFS（64 dB），1 px = 0.64 dB
  平滑    attack 1 帧释放 old-(old>>>3)（刷新 46.9 Hz ⇒ 约 170 ms）
"""

import numpy as np
from spec_ref import FS, NB, FREQS, sig_sine, sig_noise, sig_sweep

# ======================= 定点参数 =======================
N = 1024
NB_T = 32
SW = 34          # y1/y2 位宽
CQ = 20          # 系数定标（2cos * 2^CQ）
CW = 22          # 系数位宽（2*2^20 = 2^21 ⇒ 需要 22 bit 有符号）

COEF = np.round(2.0 * np.cos(2*np.pi*FREQS/FS) * (1 << CQ)).astype(np.int64)
assert np.abs(COEF).max() < (1 << (CW-1)), "系数超出 %d bit" % CW

# 窗：64 项表（n 的高 6 位寻址），值 0..64
WIN_TAB = np.round((0.5 - 0.5*np.cos(2*np.pi*np.arange(64)/64)) * 64).astype(np.int64)
WIN_USED = WIN_TAB[np.arange(N) // (N // 64)]

WIN_MEAN = WIN_TAB.sum() / 64.0 / 64.0
REF_AMP = 32768.0 * N / 2.0 * WIN_MEAN
REF_Q5 = int(round(20*np.log10(REF_AMP) * 32))

# log2 表：5 bit 尾数，Q8
LOG2_TAB5 = np.round(256*np.log2(1.0 + np.arange(32)/32.0)).astype(np.int64)


# ======================= 定点运算 =======================
def wrap(v, bits=SW):
    v &= (1 << bits) - 1
    if v >= (1 << (bits-1)):
        v -= (1 << bits)
    return v


def log2_q8(v):
    if v <= 0:
        return 0
    p = v.bit_length() - 1
    m = (v >> (p-5)) & 0x1F if p >= 5 else (v << (5-p)) & 0x1F
    return p*256 + int(LOG2_TAB5[m])


def fixed_bars(seg):
    px = np.zeros(NB, dtype=np.int64)
    for i in range(NB):
        c = int(COEF[i]); y1 = 0; y2 = 0
        for n, x in enumerate(seg):
            xw = (int(x) * int(WIN_USED[n])) >> 6
            prod = (c*y1 + (1 << (CQ-1))) >> CQ
            y1n = wrap(xw + prod - y2)
            y2 = y1; y1 = y1n
        a = max(abs(y1), abs(y2))
        e = 0 if a == 0 else max(0, a.bit_length()-1-14)
        ys1, ys2 = y1 >> e, y2 >> e
        #  mag² = ys1² + ys2² − (c·ys1·ys2)/2^CQ
        #  ⚠ 必须用三重积后只截断一次；先算 t=(c·ys2)>>CQ 再 t·ys1 时，
        #    t 上 1 LSB 的截断误差被 ys1(≈2^14) 放大到和 mag² 同量级，
        #    低频带（mag²=(y1−y2)² 本身很小）会丢掉约 8 dB。
        mag2 = ys1*ys1 + ys2*ys2 - ((c * ys1 * ys2) >> CQ)
        if mag2 <= 0:
            continue
        lg = log2_q8(mag2)
        lev = ((lg*385) >> 10) + (192*e + ((42*e) >> 6)) - REF_Q5
        tt = lev + 2304
        px[i] = min(max(((tt*25) >> 9) if tt > 0 else 0, 0), 100)
    return px


def float_bars(seg):
    win = WIN_USED / 64.0
    c = 2.0*np.cos(2*np.pi*FREQS/FS)
    y1 = np.zeros(NB); y2 = np.zeros(NB)
    for xn in seg*win:
        y = xn + c*y1 - y2
        y2 = y1; y1 = y
    mag = np.sqrt(np.maximum(y1*y1 + y2*y2 - c*y1*y2, 0.0))
    db = 20*np.log10(np.maximum(mag, 1e-9)/REF_AMP)
    return np.clip((db + 72.0)/64.0*100.0, 0, 100), db


def peak_state(seg):
    """顺便测 y 的最大绝对值（决定 SW）"""
    c = 2.0*np.cos(2*np.pi*FREQS/FS)
    y1 = np.zeros(NB); y2 = np.zeros(NB); pk = 0.0
    for xn in seg*(WIN_USED/64.0):
        y = xn + c*y1 - y2
        y2 = y1; y1 = y
        pk = max(pk, float(np.abs(y1).max()))
    return pk


def smooth(runs):
    out = np.zeros_like(runs); h = np.zeros(NB, dtype=np.int64)
    for k in range(len(runs)):
        h = np.maximum(runs[k], h - (h >> 3))
        out[k] = h
    return out


# ======================= 主对比 =======================
CASES = [
    ("1 kHz 单音 amp20000",      sig_sine(1000.0, 20000.0, N*4)),
    ("C4 261.6 Hz amp20000",     sig_sine(261.63, 20000.0, N*4)),
    ("E2 82.4 Hz amp20000",      sig_sine(82.41, 20000.0, N*4)),
    ("白噪",                      sig_noise(6000.0, N*4)),
    ("弱音 1 kHz amp328",         sig_sine(1000.0, 328.0, N*4)),
    ("扫频 200->8k amp20000",     sig_sweep(200.0, 8000.0, 20000.0, N*4)),
    ("满刻度 60 Hz amp32767",     sig_sine(60.0, 32767.0, N*4)),
    ("满刻度 16 kHz amp32767",    sig_sine(16000.0, 32767.0, N*4)),
    ("满刻度 100 Hz amp32767",    sig_sine(100.0, 32767.0, N*4)),
    ("和弦 C4+E4+G4",             sig_sine(261.63, 12000.0, N*4)
                                  + sig_sine(329.63, 12000.0, N*4)
                                  + sig_sine(392.0, 12000.0, N*4)),
]

print("=" * 108)
print("定点(Q20/34bit) vs 浮点黄金参考 —— 每个信号 4 个窗口 × 32 根柱")
print("=" * 108)
worst = 0.0
worst_name = ""
for name, x in CASES:
    ff, fd = [], []
    for k in range(4):
        seg = x[k*N:(k+1)*N].astype(np.int64)
        ff.append(fixed_bars(seg))
        fb, _ = float_bars(seg.astype(float))
        fd.append(fb)
    ff = np.array(ff); fd = np.array(fd)
    err = np.abs(ff - fd)
    if err.max() > worst:
        worst, worst_name = err.max(), name
    print("\n【%s】" % name)
    print("  浮点 px: " + " ".join("%3.0f" % v for v in fd[-1]))
    print("  定点 px: " + " ".join("%3.0f" % v for v in ff[-1]))
    print("  误差   : " + " ".join("%+3.0f" % v for v in (ff[-1]-fd[-1])))
    print("  max %.1f px  mean %.2f px  峰值带 浮%2d / 定%2d  窗内 max|y| %.3g (2^%.1f)"
          % (err.max(), err.mean(), int(np.argmax(fd[-1])), int(np.argmax(ff[-1])),
             peak_state(x[3*N:4*N].astype(float)),
             np.log2(max(peak_state(x[3*N:4*N].astype(float)), 1.0))))

print("\n" + "=" * 108)
print("判据（交接文档）: 最大柱高误差 < 5 px")
print("  实测最大误差 = %.1f px  出现在【%s】   =>  %s"
      % (worst, worst_name, "PASS" if worst < 5 else "FAIL"))
print("=" * 108)

# ---- 平滑后的动画序列（扫频），确认 attack/release 行为 ----
print("\n扫频信号 8 个窗口的平滑柱高（看柱子如何随频率移动）:")
x = sig_sweep(200.0, 8000.0, 20000.0, N*8)
runs = np.array([fixed_bars(x[k*N:(k+1)*N].astype(np.int64)) for k in range(8)])
for k, row in enumerate(smooth(runs)):
    top = int(np.argmax(row))
    print("  窗%d 峰值band%2d(%5.0fHz) %3d px | %s"
          % (k, top, FREQS[top], row[top],
             "".join("%X" % (min(int(v), 15)) for v in row)))

# ---- 输出 Verilog 表 ----
print("\n" + "=" * 108)
print("Verilog 表")
print("=" * 108)
print("\n// 窗表 64 项 × 7 bit（值 0..64，n[9:4] 寻址）")
print("WIN_TAB = [" + ", ".join(str(int(v)) for v in WIN_TAB) + "]")
print("\n// log2 表 32 项 × 8 bit（5 bit 尾数 → Q8 小数部分）")
print("LOG2_TAB = [" + ", ".join(str(int(v)) for v in LOG2_TAB5) + "]")
print("\n// 2cos(w) Q20，22 bit 有符号")
print("COEF = [" + ", ".join(str(int(v)) for v in COEF) + "]")
print("\n// 常数")
print("REF_Q5 = %d   (%.3f dB)   WIN_MEAN = %.4f" % (REF_Q5, REF_Q5/32.0, WIN_MEAN))
print("频带 Hz = [" + ", ".join("%.2f" % f for f in FREQS) + "]")
