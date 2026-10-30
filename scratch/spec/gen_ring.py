# -*- coding: utf-8 -*-
"""
gen_ring.py —— 把 spec_band.v 里的 32 级移位"数组"改写成 32 个显式标量寄存器
==============================================================================
为什么：写成 `reg [33:0] ry1 [0:31]` 时，Gowin 综合器把 32×68 bit 的移位环
        推断成 2 块 BSRAM（SDPX9B），`u_spec` 只剩 804 个触发器；
        而门级仿真表明该映射读不出状态（输出柱高恒 0，RTL 用同一激励是 79 px）。
        改成 32 个独立标量后，没有"可寻址数组"可供推断，状态必然留在触发器里。

本脚本只做机械替换，不改任何逻辑：
  1) 数组声明 → 64 个标量声明
  2) 复位用的 for 循环 → 64 条显式清零
  3) 移位用的 for 循环 → 62 条显式相邻传递 + 2 条尾部压入
  4) 引用 ry1[0]/ry2[0]/ry1[1]/ry2[1] → ry1_00/ry2_00/ry1_01/ry2_01

幂等：检测到已是标量形式就退出。
运行：  python gen_ring.py
"""

import io
import os
import sys

NB = 32
PATH = os.path.abspath(os.path.join(os.path.dirname(__file__),
                                    "..", "..", "rtl", "vis", "spec_band.v"))

old_decl = (
    "    //========================================================================\n"
    "    //  4. 移位环 + 状态\n"
    "    //========================================================================\n"
    "    reg signed [SW-1:0] ry1 [0:NB-1];\n"
    "    reg signed [SW-1:0] ry2 [0:NB-1];\n")

old_logic = (
    "    integer k;\n"
    "    always @(posedge clk or negedge rst_n) begin\n"
    "        if (!rst_n) begin\n"
    "            for (k = 0; k < NB; k = k + 1) begin\n"
    "                ry1[k] <= {SW{1'b0}};\n"
    "                ry2[k] <= {SW{1'b0}};\n"
    "            end\n"
    "        end else if (ring_shift) begin\n"
    "            ry1[NB-1] <= push_y1;\n"
    "            ry2[NB-1] <= push_y2;\n"
    "            for (k = 0; k < NB-1; k = k + 1) begin\n"
    "                ry1[k] <= ry1[k+1];\n"
    "                ry2[k] <= ry2[k+1];\n"
    "            end\n"
    "        end\n"
    "    end\n")


def gen_decl():
    out = ["    //  ⚠ 刻意写成 32 个标量而不是数组：数组会被综合器推断成 BSRAM",
           "    //     （详见文件头）。不要「优化」回 `reg [33:0] ry1 [0:31]`。"]
    for base in ("ry1", "ry2"):
        names = ["%s_%02d" % (base, i) for i in range(NB)]
        out.append("")
        for r in range(0, NB, 4):
            out.append("    reg signed [SW-1:0] %s;"
                       % ", ".join(names[r:r + 4]))
    return "\n".join(out) + "\n"


def gen_logic():
    out = ["    integer k;                       // hgt 复位循环还在用",
           "    always @(posedge clk or negedge rst_n) begin",
           "        if (!rst_n) begin"]
    for base in ("ry1", "ry2"):
        for r in range(0, NB, 4):
            #  4 条并排写，便于阅读
            parts = " ".join("%s_%02d <= {SW{1'b0}};" % (base, i)
                             for i in range(r, min(r + 4, NB)))
            out.append("            " + parts)
    out.append("        end else if (ring_shift) begin")
    for base in ("ry1", "ry2"):
        for i in range(NB - 1):
            out.append("            %s_%02d <= %s_%02d;" % (base, i, base, i + 1))
        out.append("            %s_%02d <= push_%s;"
                   % (base, NB - 1, "y1" if base == "ry1" else "y2"))
    out.append("        end")
    out.append("    end")
    return "\n".join(out) + "\n"


def main():
    with io.open(PATH, "r", encoding="utf-8") as f:
        src = f.read()

    if "ry1_00" in src:
        print("已经是标量形式，无需改写")
        return 0

    if old_decl not in src:
        print("!! 没找到数组声明块，放弃")
        return 1
    if old_logic not in src:
        print("!! 没找到移位环 always 块，放弃")
        return 1

    src = src.replace(old_decl, old_decl.split("    reg signed")[0] + gen_decl())
    src = src.replace(old_logic, gen_logic())

    src = src.replace("ry1[0]", "ry1_00").replace("ry2[0]", "ry2_00")
    src = src.replace("ry1[1]", "ry1_01").replace("ry2[1]", "ry2_01")

    with io.open(PATH, "w", encoding="utf-8", newline="\n") as f:
        f.write(src)
    print("改写完成：%s" % PATH)
    return 0


if __name__ == "__main__":
    sys.exit(main())
