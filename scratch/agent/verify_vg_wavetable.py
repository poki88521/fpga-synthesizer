# -*- coding: utf-8 -*-
"""
verify_vg_wavetable.py —— 核对综合网表（.vg）里波表 ROM 的 INIT_RAM 是否等于当前 hex

为什么用"多重集"比对：
    新版综合把 wave_table_rom 的 mem 推成 16 个 16 位宽 BSRAM 块
    （defparam mem_mem_0_N_s.INIT_RAM_XX），块内/块间的地址映射由工具决定，
    而且**全零块会被省略**（缺失 = 0）。按"所有 16 位字的多重集"比对与映射无关，
    只要表整体一致就必然相等；同时可以和**改前备份**再比一次，判断综合用的是新表还是旧表。

用法：
    python verify_vg_wavetable.py [--vg <vg>] [--hex <hex>] [--old <旧hex备份>]
"""
import argparse
import re
import sys
from collections import Counter


def load_hex(path):
    v = []
    for ln in open(path):
        s = ln.strip()
        if not s:
            continue
        x = int(s, 16)
        v.append(x - 65536 if x >= 32768 else x)
    return v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vg", default=r"D:/code/fpga-synthesizer/develop/board/full_system/impl/gwsynthesis/full_system.vg")
    ap.add_argument("--hex", default=r"D:/code/fpga-synthesizer/develop/board/full_system/data/wave_table.hex")
    ap.add_argument("--old", default=r"D:/code/fpga-synthesizer/develop/board/full_system/data/wave_table.hex.bak_20261102_2210")
    a = ap.parse_args()

    raw = open(a.vg, "r", errors="ignore").read()
    m = re.search(r"^module wave_table_rom\b(.*?)^endmodule", raw, re.S | re.M)
    if not m:
        print("!! 找不到 module wave_table_rom")
        sys.exit(1)
    body = m.group(1)

    #  收集 mem_mem_0_N_s 的 INIT_RAM_XX（每个 256 bit = 16 个 16 位字）
    blocks = {}
    for mm in re.finditer(
            r"defparam\s+mem_mem_0_(\d+)_s\.INIT_RAM_([0-9A-Fa-f]{2})\s*=\s*256'h([0-9A-Fa-f]{64});",
            body):
        blk = int(mm.group(1))
        ram = int(mm.group(2), 16)
        val = int(mm.group(3), 16)
        blocks.setdefault(blk, {})[ram] = val

    nb = len(blocks)
    total_rams = sum(len(v) for v in blocks.values())
    print("网表: 块数 = %d（块号 %s）, INIT_RAM 参数总数 = %d"
          % (nb, sorted(blocks.keys()), total_rams))
    for blk in sorted(blocks.keys()):
        rs = sorted(blocks[blk].keys())
        print("  块 %2d: %d 个 INIT_RAM，索引 %d..%d" % (blk, len(rs), rs[0], rs[-1]))

    net = Counter()
    for blk in sorted(blocks.keys()):
        rams = blocks[blk]
        for ram in range(64):
            val = rams.get(ram, 0)          # 缺失 = 全零块
            for i in range(16):
                net[(val >> (16 * i)) & 0xFFFF] += 1
    print("网表 16 位字总数 = %d（= 块数 x 64 x 16）" % sum(net.values()))

    new = load_hex(a.hex)
    cnt_new = Counter((x & 0xFFFF) for x in new)
    print("\n[1] 与**当前** hex 比对: 总字数 %d vs %d，多重集%s"
          % (sum(net.values()), sum(cnt_new.values()),
             "**完全一致**" if net == cnt_new else "不一致"))

    try:
        old = load_hex(a.old)
        cnt_old = Counter((x & 0xFFFF) for x in old)
        same_old = (net == cnt_old)
        print("[2] 与**改前备份**比对: 多重集%s" % ("**完全一致**（说明综合用的是旧表！）" if same_old
                                             else "不一致（好现象：网表不是旧表）"))
        if not (net == cnt_new) and not same_old:
            #  逐槽比对，定位差异
            for s in range(8):
                seg = new[s * 2048:(s + 1) * 2048]
                print("     槽 %d: hex 非零字数 %d, 网表该槽…（无法按槽定位，因映射未知）"
                      % (s, sum(1 for x in seg if x)))
    except FileNotFoundError:
        print("[2] 跳过（没有备份可比）")

    #  额外：新表与旧表在全表范围内的差异字数（应 = 2047）
    try:
        diff = sum(1 for x, y in zip(new, old) if x != y)
        print("\n[3] 当前 hex vs 备份: 差异字数 = %d（预期 2047）" % diff)
    except NameError:
        pass

    ok = (net == cnt_new)
    print("\n结论: %s" % ("PASS —— 综合网表里的波表 = 当前新表" if ok else
                        "FAIL —— 网表里的波表不是当前新表，需重新综合"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
