#!/usr/bin/env python3
"""生成 rtl/scheduler/bend_exp.hex —— 弯音比指数表（Q2.14）

口径：
  · 覆盖 ±24 半音
  · dsemi 定标：1 半音 = 256（Q8.8），范围 [-6144, +6144]
  · 索引：bidx = (dsemi + 6144) >>> 8  → 0..48，步长 1 半音
  · 表长 64（0..48 有效，其余填充最后一个值，便于索引钳位后仍可安全读 r0/r1）
  · 值 = round(2^((i-24)/12) × 16384)，钳位到 16 位

⚠ 2026-10-16：原表是 512 项（步长 0.125 半音），在 chan_table 的 apply_field 里
   被**组合读取**，综合后是 512 选 1 的 16 位 mux —— 这就是 1092 个时序违例的根源。
   缩到 64 项后 mux 小 8 倍；配合 8 位线性插值，误差约 0.7 音分，听感无差异。

用法：python simulation/tools/gen_bend_exp.py
"""
import math, os

N = 64
CENTER = 24          # i = 24 对应 0 半音
SCALE = 16384.0

out = os.path.join(os.path.dirname(__file__), "..", "..", "rtl", "scheduler", "bend_exp.hex")
out = os.path.abspath(out)

vals = []
for i in range(N):
    dsemi = i - CENTER
    v = round((2.0 ** (dsemi / 12.0)) * SCALE)
    vals.append(max(0, min(65535, v)))

with open(out, "w", newline="\n") as f:
    for v in vals:
        f.write("%04X\n" % v)

print("已写 %s" % out)
print("  项数 %d，%d 字节" % (N, os.path.getsize(out)))
print("  [0]=%04X (-24半音)  [24]=%04X (0)  [36]=%04X (+12)  [48]=%04X (+24)" %
      (vals[0], vals[24], vals[36], vals[48]))