#!/usr/bin/env python3
"""
fx_reverb 的算法级参考模型（Freeverb 结构），用来和 RTL 的脉冲响应对拍。

结构与参数严格照 RTL 头注释 / Freeverb 原始 C++：
    8 条并联梳状（低通反馈）  + 4 条串联全通
    梳状长度 1215 1293 1390 1476 1548 1623 1695 1760（右声道 +23）
    全通长度  605  480  371  245
    梳状： out = buf[p]; fs = out*(1-damp) + fs*damp; buf[p] = in + fs*decay
    全通： bufout = buf[p]; out = -in + bufout; buf[p] = in + bufout*0.5
    (依据 Freeverb allpass.hpp：output = -input + bufout; buffer = input + bufout*feedback)

用法： python3 sim/refmodel_reverb.py [NS] [p_size] [p_decay] [p_damp] [p_ret]
默认与 sim/tb_fx_reverb.v 一致：NS=8000 p_size=26000 p_decay=30000 p_damp=9000 p_ret=32767
输出：每行 "  索引 值"（只打非零），方便与 RTL 的 trace 对比
"""
import sys

COMB_L = [1215, 1293, 1390, 1476, 1548, 1623, 1695, 1760]
AP_L   = [605, 480, 371, 245]

def sat24(v):
    if v > 8388607:  return 8388607
    if v < -8388608: return -8388608
    return v

def s15(x):            # Q1.15 乘法后 >>15（与 RTL 的 >>>15 等价，Python 的 >> 向下取整）
    return x >> 15

def run(NS=8000, p_size=26000, p_decay=30000, p_damp=9000, p_ret=32767,
        pulse=1000, ch_offset=0, verbose_pos=None):
    # 连续共享缓冲（Freeverb 原版就是一条 buffer + 各 tap 固定偏移）
    comb = [[0]*L for L in COMB_L]
    ap   = [[0]*L for L in AP_L]
    fs   = [0]*len(COMB_L)
    ptrc = [0]*len(COMB_L)
    ptra = [0]*len(AP_L)
    # 每条线的共享缓冲与偏移（在模型里用独立数组等价表达）
    out  = []
    for k in range(NS):
        x = pulse if k == 0 else 0
        xin = sat24(s15(x * p_size))                     # 输入增益
        # ---- 8 条梳状并联 ----
        s = 0
        for i, L in enumerate(COMB_L):
            bufout = comb[i][ptrc[i]]
            fs[i]  = sat24(s15(bufout * (32767 - p_damp) + fs[i] * p_damp))
            comb[i][ptrc[i]] = sat24(s15(fs[i] * p_decay) + xin)
            ptrc[i] = (ptrc[i] + 1) % L
            s += bufout
        # ---- 4 条全通串联 ----
        v = sat24(s)
        for i, L in enumerate(AP_L):
            bufout = ap[i][ptra[i]]
            ap[i][ptra[i]] = sat24(s15(bufout * 16384) + v)
            v = bufout - v
            ptra[i] = (ptra[i] + 1) % L
        out.append(sat24(s15(v * p_ret)))
    return out

if __name__ == '__main__':
    a = sys.argv[1:]
    NS = int(a[0]) if len(a) > 0 else 8000
    ps = int(a[1]) if len(a) > 1 else 26000
    pd = int(a[2]) if len(a) > 2 else 30000
    pm = int(a[3]) if len(a) > 3 else 9000
    pr = int(a[4]) if len(a) > 4 else 32767
    y = run(NS, ps, pd, pm, pr)
    print(f"# 参考模型：NS={NS} p_size={ps} p_decay={pd} p_damp={pm} p_ret={pr}")
    print(f"# 首个非零 = {next((i for i,v in enumerate(y) if v), -1)}")
    print(f"# 峰值 = {max(abs(v) for v in y)}")
    # 分窗口能量
    for w in range(0, NS//1000):
        seg = y[w*1000:(w+1)*1000]
        print(f"# 窗口{w}: |y|和 = {sum(abs(v) for v in seg)}")
    for i, v in enumerate(y):
        if v:
            print(f"{i} {v}")
