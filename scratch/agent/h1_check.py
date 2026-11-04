# -*- coding: utf-8 -*-
"""
h1_check.py —— 定量核对「相位增量量化失谐」（候选假设 ①）
以及 bend/pan 表的中心值、ch_lfo 的默认输出。
"""
import numpy as np

FS = 48000.0
CLK = 49.152e6

tbl_path = r"D:/code/fpga-synthesizer/develop/board/full_system/data/note_inc.hex"
bend_path = r"D:/code/fpga-synthesizer/develop/board/full_system/data/bend_exp.hex"

inc = [int(ln.strip(), 16) for ln in open(tbl_path) if ln.strip()]
print("note_inc 表项数 =", len(inc))

# MIDI -> Hz（十二平均律，A4=440）
def hz(n):
    return 440.0 * 2 ** ((n - 69) / 12.0)


print("\n== 假设① 相位增量量化 ==")
for n in (60, 64, 72):
    f_ideal = hz(n)
    q_ideal = f_ideal / FS * 2 ** 32
    q_tab = inc[n]
    f_tab = q_tab / 2 ** 32 * FS
    err_hz = f_tab - f_ideal
    print("note %3d  理想 inc=%.4f  表值=%d  频率 %.6f vs %.6f Hz  误差 %+.3e Hz (%.2f ppm)"
          % (n, q_ideal, q_tab, f_tab, f_ideal, err_hz, 1e6 * err_hz / f_ideal))

# 两个音各自的失谐能不能凑出“拍频”
f60 = inc[60] / 2 ** 32 * FS
f64 = inc[64] / 2 ** 32 * FS
print("\nC4=%.4f Hz  E4=%.4f Hz" % (f60, f64))
print("两个基频的“近重合”要产生 1 Hz 拍频需要相对失谐 %.1f ppm；实际 %.3f ppm"
      % (1e6 / f60, 1e6 * abs(f60 - hz(60)) / hz(60)))

print("\n== 谐波近重合（决定“真·声学拍频”）==")
for (na, nb, name) in ((60, 64, "大三度 C4+E4（比例 1.2599）"),
                       (60, 72, "八度 C4+C5（比例 2.0）"),
                       (60, 67, "纯五度 C4+G4（比例 1.4983）")):
    fa, fb = hz(na), hz(nb)
    print("\n  %s : %.2f / %.2f Hz" % (name, fa, fb))
    rows = []
    for ka in range(1, 9):
        for kb in range(1, 9):
            d = abs(ka * fa - kb * fb)
            if d < 60.0:
                rows.append((d, ka, kb, ka * fa, kb * fb))
    rows.sort()
    for d, ka, kb, x, y in rows:
        print("     %dF(%.1f) vs %dF(%.1f) → Δ=%6.2f Hz" % (ka, x, kb, y, d))
    if not rows:
        print("     60 Hz 内没有任何近重合分音")

print("\n== bend_exp 表中心值（bend=8192 应为 16384 = 1.0）==")
b = [int(ln.strip(), 16) for ln in open(bend_path) if ln.strip()]
print("bend 表项数 =", len(b), " 取前 4 个:", b[:4])
# 表项通常是 14 位 index 的高 7 位
for idx in (0, 32, 63, 64, 65, 127):
    if idx < len(b):
        print("  idx %3d -> 0x%08X = %d" % (idx, b[idx], b[idx]))

print("\n== ch_lfo 默认输出 ==")
print("  mod_wheel 复位 0 → depth = 0<<2 = 0 → vib_d = tri*0>>>5 = 0 → ch_vib_ratio = 16384 (1.0)")
print("  ⇒ 只有收到 CC1 才会有 5.5 Hz 颤音（那是“固定频率、不随音高”的调制，需确认现场是否动过 CC1）")
print("  三角波速率 5.5 Hz：PH_INC=492132 → %.3f Hz" % (492132 / 2 ** 32 * FS))
