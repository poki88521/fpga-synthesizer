# -*- coding: utf-8 -*-
"""快速查看波表 8 个槽的谐波构成（决定“和弦是否可能真的拍频”）"""
import numpy as np
import sys

path = sys.argv[1] if len(sys.argv) > 1 else \
    r"D:/code/fpga-synthesizer/develop/board/full_system/data/wave_table.hex"

v = []
for ln in open(path, "r"):
    ln = ln.strip()
    if not ln:
        continue
    x = int(ln, 16)
    if x >= 0x8000:
        x -= 0x10000
    v.append(x)
v = np.array(v, dtype=float)
print("total points =", v.size)

for slot in range(8):
    s = v[slot * 2048:(slot + 1) * 2048]
    if np.allclose(s, 0):
        print("slot %d : 全 0" % slot)
        continue
    F = np.fft.rfft(s) / (2048 / 2.0)
    mag = np.abs(F)
    order = np.argsort(mag)[::-1][:6]
    parts = []
    for k in sorted(order):
        if k == 0:
            continue
        parts.append("%dF:%.1fdB" % (k, 20 * np.log10(mag[k] / mag[1] + 1e-12)))
    print("slot %d : peak=%6.0f rms=%7.1f  " % (slot, np.abs(s).max(),
                                                np.sqrt((s ** 2).mean())),
          " ".join(parts))
    # 打印非谐波（非整数倍）最大分量，判断表里有没有杂散
    f = np.arange(mag.size)
    mask = np.ones(mag.size, dtype=bool)
    for k in range(1, mag.size // 2 + 1):
        if 2 * k < mag.size:
            mask[max(0, 2 * k - 3):2 * k + 4] = False
    mask[0] = False
    nh = mag[mask]
    if nh.size:
        print("        非谐波最大 = %.1f dB re 基频" %
              (20 * np.log10(nh.max() / mag[1] + 1e-12)))
