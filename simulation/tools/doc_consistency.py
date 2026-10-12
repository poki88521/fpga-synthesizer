#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
doc_consistency.py —— 文档数字一致性扫描（sakiko）

目的：documents/ 三份文档 + 组内同步文档里，**同一个量在多处出现时必须相等**。
      人工核对容易漏（本项目已出现过"波表 16 块 vs 8 块""ROM 深度 2 vs 8"这类矛盾），
      所以把「关键量 → 期望值」固化成表，全文扫描并报告**每一处的实际值**。

用法：
    python3 doc_consistency.py                # 扫 documents/ 下全部 md
    python3 doc_consistency.py --dir <目录>
"""

import argparse
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _find(pred, start=HERE):
    """向上找满足 pred 的目录（工程布局会变，不能写死层数）"""
    d = start
    for _ in range(6):
        if pred(d):
            return d
        d = os.path.dirname(d)
    return start


ROOT = _find(lambda d: os.path.isdir(os.path.join(d, "documents")))   # 含 documents/ 的那层
DOCS = os.path.join(ROOT, "documents")

# 关键量 -> (正则, 期望值, 说明)
#   正则里用 (数值) 捕获要检查的数字；其余部分用于定位
CHECKS = [
    # ---- 波表 / 音色槽 ----
    #  ⚠ 排除扩展指南的"16 槽 × 2048 点"（路线 B 的设想），只查描述现状的句子
    (r"(?<!\| )当前[^\n]{0,10}(\d+)\s*槽\s*×\s*2048\s*点", "8", "音色槽数（现状）"),
    (r"取 (\d+) 槽 × 2048 点可满足", "8", "音色槽数（定稿理由）"),
    (r"波表\*\*总深度：(\d+)\s*点", "16384", "波表总深度"),
    #  ⚠ 必须限定"波表/16384"上下文，否则会误抓 SSF 表的 `2 Kbit`（不是同一量）
    (r"16 bit = (\d+) Kbit\(\*\*16 块", "256", "波表容量（技术文档 §一）"),
    (r"`16384 × 16 bit = (\d+) Kbit`", "256", "波表容量（硬件实现 §五.1）"),
    (r"16 bit = (\d+) Kbit\*\* \| \*\*16 块", "256", "波表容量（技术文档 附录A）"),
    (r"波表容量：`16384 × 16 bit = 256 Kbit` → \*\*(\d+) 块", "16", "波表 BSRAM 块数（§五.1）"),
    (r"保留 1 份波表 ROM（(\d+) 块 BSRAM", "16", "波表 BSRAM 块数（§五.4）"),
    (r"地址深度 = 音色槽数 = \*\*(\d+)\*\*", "8", "音色参数 ROM 地址深度"),
    (r"#Address_depth=(\d+)", "16384|8", "波表/参数的 .mi 深度（16384 或 8）"),
    # ---- 状态表位宽（§三 与 §九/§四 必须一致）----
    (r"每项位宽 \| \*\*(\d+) bit\*\*", "182", "通道状态表每项位宽"),
    (r"每声部位宽 \| \*\*(\d+) bit\*\*", "225", "声部状态表每声部位宽"),
    (r"写回缓冲 \*\*(\d+) bit / 声部\*\*", "139", "写回缓冲每声部"),
    (r"合计 \*\*(\d+) bit\*\*）：`phase_inc`", "169", "预取寄存器每泳道"),
    # ---- BSRAM / DSP 资源 ----
    (r"混响 (\d+) \+ 合唱 (\d+) \+ 延迟 (\d+) = \*\*(\d+) 块", None, "效果器 BSRAM 分项"),
    (r"146 / 340 块（\*\*(\d+\.\d+)%\*\*）", "42.9", "效果器占 BSRAM 比例"),
    (r"合计\*\* \| \|\s*2378976 \| \*\*(\d+) / 340", "146", "效果器 BSRAM 合计"),
    (r"DSP：\*\*模块三全链\*\*（实测清点） \| \*\*(\d+) 个乘法器\*\*", "33", "模块三 DSP 数"),
    (r"\| \*\*合计\*\* \| \*\*(\d+)\*\* \| 上界", "33", "DSP 清点合计"),
    # ---- 时钟 / 采样 / 拍数 ----
    (r"N_cyc\`?\s*\|\s*\*\*(\d+)\*\*", "1024", "每采样拍数"),
    
    #  MHz 无法硬编码期望值（合法的有很多：晶振 25、OSC 210、VCO 786.432、
    #  PLL 范围 6.25~81.25、时钟链 49.152/24.576/1.536、不可用参考 12.288…）
    #  → 只**列出**全部取值供人工确认，不做断言
    (r"([\d.]+) MHz", None, "各处 MHz 值（列出供核对，不做断言）"),
    (r"全程占用 \| — \| \*\*(\d+) 拍 / 1024\*\*", "256", "实测全程拍数"),
    (r"clk12288[^\n]{0,40}周期(\d+\.\d+)", "40.690", "clk12288 周期"),
    (r"`T_clk` \| (\d+\.\d+) ns", "20.345", "单拍周期 T_clk"),
    # ---- 测试 ----
    (r"回归 (\d+) 条全绿", "31", "回归条数"),
    (r"合计：(\d+) 项，PASS", None, "测试项数（运行时值）"),
    # ---- 延迟上限 ----
    (r"延迟上限 \*\*(\d+) ms\*\*", "512", "延迟上限"),
    (r"DLY_MAX = (\d+)", "24576", "延迟有效上限点数"),
]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=DOCS)
    args = ap.parse_args()
    files = sorted(glob.glob(os.path.join(args.dir, "*.md")))
    print("=" * 78)
    print(f"  文档数字一致性扫描 · {len(files)} 个文件")
    print("=" * 78)

    problems = []
    for pat, expect, label in CHECKS:
        hits = []
        for f in files:
            for ln, line in enumerate(open(f, encoding="utf-8").read().split("\n"), 1):
                for m in re.finditer(pat, line):
                    got = m.groups()
                    hits.append((os.path.basename(f), ln, got))
        if not hits:
            continue
        vals = {h[2] for h in hits}
        ok = True
        if expect is not None:
            allowed = set(expect.split("|"))
            ok = all(any(g in allowed for g in h[2]) for h in hits) if isinstance(hits[0][2], tuple) else \
                 all(h[2][0] in allowed for h in hits)
        tag = "✓" if ok else "✗"
        print(f"\n  {tag} {label}  期望 {expect or '（仅列出）'}")
        for fn, ln, got in hits:
            print(f"      {fn}:{ln}  → {got}")
        if not ok:
            problems.append((label, expect, vals))

    print()
    print("-" * 78)
    if problems:
        print(f"  ❌ {len(problems)} 个量存在不一致：")
        for label, expect, vals in problems:
            print(f"      {label}：期望 {expect}，实际出现 {sorted(str(v) for v in vals)}")
    else:
        print("  ✅ 所有被检查的量在各处一致")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
