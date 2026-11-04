# -*- coding: utf-8 -*-
"""
index_scan.py —— 扫 backups/ 下每个存档，抽出总索引需要的数字
输出：目录名 / .fs 大小 / Setup,Hold 违例 / 音频域实际 Fmax / 最差 setup slack / 资源
（只读，不改任何文件）
"""
import os
import re

ROOT = r"D:/code/fpga-synthesizer/develop/scratch/backups"

rows = []
for name in sorted(os.listdir(ROOT)):
    d = os.path.join(ROOT, name)
    if not os.path.isdir(d):
        continue
    fs = os.path.join(d, "full_system.fs")
    tr = os.path.join(d, "full_system.tr")
    rp = os.path.join(d, "full_system.rpt.txt")
    size = os.path.getsize(fs) if os.path.exists(fs) else 0

    su = ho = "?"
    fmax = slack = "?"
    if os.path.exists(tr):
        t = open(tr, "r", errors="ignore").read()
        m = re.search(r"Numbers of Setup Violated Endpoints>:(\d+)", t)
        if m:
            su = m.group(1)
        m = re.search(r"Numbers of Hold Violated Endpoints>:(\d+)", t)
        if m:
            ho = m.group(1)
        # Max Frequency Summary 里音频域那一行
        m = re.search(r"u_full_top/g_pll\.u_pll/PLL_inst/CLKOUT0\.default_gen_clk\s+([\d.]+)\(MHz\)\s+([\d.]+)\(MHz\)", t)
        if m:
            fmax = m.group(2)
        # Setup Paths Table 第 1 行的 slack（⚠ 目录里也有 "3.1.1 Setup Paths Table"，
        # 所以不能用 find() 定位；直接全局找第一条编号行，它就是 setup 表的第一行）
        m = re.search(r"^\s+1\s+(-?\d+\.\d+)\s+u_", t, re.M)
        if m:
            slack = m.group(1)

    reg = lut = bs = dsp = "?"
    if os.path.exists(rp):
        r = open(rp, "r", errors="ignore").read()
        m = re.search(r"Register\s+\|\s*(\d+)/", r)
        if m:
            reg = m.group(1)
        m = re.search(r"LUT,ALU,ROM16\s*\|\s*(\d+)\((\d+) LUT, (\d+) ALU", r)
        if m:
            lut = "%s(%s+%s)" % (m.group(1), m.group(2), m.group(3))
        m = re.search(r"BSRAM\s+\|\s*(\d+)/", r)
        if m:
            bs = m.group(1)
        m = re.search(r"DSP\s+\|\s*(\d+)/", r)
        if m:
            dsp = m.group(1)

    rows.append((name, size, su, ho, fmax, slack, reg, lut, bs, dsp))

print("%-62s %11s %4s %4s %8s %8s %7s %-22s %5s %4s"
      % ("目录", ".fs 字节", "SU", "HO", "Fmax", "slack", "Reg", "LUT(ALU)", "BSRAM", "DSP"))
for r in rows:
    print("%-62s %11d %4s %4s %8s %8s %7s %-22s %5s %4s" % r)
