# -*- coding: utf-8 -*-
"""
h4_check.py —— 定量核对「增益步进」（候选假设 ④）
逐位复刻 chan_coef.v 的一阶平滑，看稳态是否有极限环/纹波。
"""
import numpy as np

NCH = 16
VISIT = 16          # 每 16 拍访问一次通道 → 3.072 MHz
FS_CLK = 49.152e6
FS = 48000.0


def sat16(v):
    if v > 32767:
        return 32767
    if v < -32768:
        return -32768
    return int(v)


def s32(v):
    """把 Python 整数模拟成 32 位有符号（RTL 里 sm_d/sm_rnd/sm_stp 都是 32 位有符号）"""
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v >= (1 << 31) else v


def step(sm, tgt):
    sm_d = s32(tgt - sm)
    sm_abs = -sm_d if sm_d < 0 else sm_d
    sm_rnd = s32(sm_d - 2048) if sm_d < 0 else s32(sm_d + 2048)
    # 算术右移 12 位（Verilog >>>）
    sm_stp = (sm_rnd >> 12) if sm_abs > 2048 else sm_d
    return sat16(sm + sat16(sm_stp))


def analyse(vol, exp, pan=23170, label=""):
    tgt = sat16(((vol << 8) * (exp << 8)) >> 15)
    sm = 32768
    hist = []
    for n in range(4000):
        gL = sat16((sm * pan) >> 15)
        hist.append((sm, gL))
        sm = step(sm, tgt)
    sms = np.array([h[0] for h in hist])
    gLs = np.array([h[1] for h in hist])
    conv = np.nonzero(sms == tgt)[0]
    print("%-22s target=%5d  收敛到 target 的第 %s 次访问" %
          (label, tgt, conv[0] if conv.size else "未"))
    tail = sms[-200:]
    print("    末 200 次访问 sm 取值集合 = %s   纹波 = %d LSB" %
          (sorted(set(tail.tolist()))[:6], int(tail.max() - tail.min())))
    print("    稳态 gL = %d（%.4f FS），chan_layer 还有一次 >>>1 后 = %.4f FS" %
          (gLs[-1], gLs[-1] / 32768.0, gLs[-1] / 32768.0 / 2))


print("== 假设④ 增益步进：chan_coef 一阶平滑逐位复刻 ==")
analyse(100, 127, label="vol=100 exp=127（默认）")
analyse(100, 127, 32767, "同上但 pan 硬左")
analyse(110, 127, label="vol=110 exp=127")
analyse(64, 64, label="vol=64 exp=64")
analyse(1, 1, label="vol=1 exp=1（极小声）")

print("\n== 平滑器访问速率 ==")
print("  49.152 MHz / %d 拍/通道 = %.3f MHz 访问率；每次访问按 diff/4096 逼近" % (VISIT, FS_CLK / VISIT / 1e6))
print("  时间常数 ≈ 4096 × %d / 49.152 MHz = %.3f ms（= %.0f 个采样 @48 kHz）" %
      (VISIT, 4096 * VISIT / FS_CLK * 1e3, 4096 * VISIT / FS_CLK * FS))

print("\n== 若真有“步进”，它的频率会是多少 ==")
print("  平滑访问率 3.072 MHz 与 48 kHz 的比值 = %.1f（整数，故不会产生新的低频）" % (FS_CLK / VISIT / FS))
print("  因此稳态（target 不变）时 gL 是常数，不可能产生周期性增益纹波")
