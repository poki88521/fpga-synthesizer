#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dsp_est.py —— 乘法器（DSP）估算（sakiko / 模块三）

为什么需要：
  文档里 "D_fx（效果器 DSP 占用）" 一直是空值，要等 IDE 综合报告。
  但**乘法器的数量可以从 RTL 精确数出来**（排除常量表达式与循环变量），
  这比"等报告"快得多，也能在综合前就发现 DSP 预算超了。

它能给什么：
  · 每个模块的乘法器个数
  · 只统计某个顶层**实际用到的模块**（避免把没用上的模块算进来）
  · 按"是否在逐采样路径上"分类 —— 控制率/事件率的乘法可以被复用或共用

它不能给什么：
  · 综合器的**共享/复用**结果（例如同一个乘法器分时复用）
  · 最终 DSP 数（那是 `M0(27×18)` / `M1(12×12)` 的映射结果）
  → 所以最终仍以 IDE 报告为准，本脚本给的是**上界估计**

用法：
    python3 sim/dsp_est.py                  # 统计 rtl/ 全部模块
    python3 sim/dsp_est.py --top full_top   # 只统计 full_top 用到的模块
"""

import argparse
import glob
import os
import re
import sys

# ---- 路径定位（适配 verify/sim/ 的新布局）----------------------------
#  ⚠ 工程可能被整体移动、或在 `verify/sim/` 与 `sim/` 两种布局之间改，
#    所以 ROOT 不能写死层数 —— 用"找标志文件"的方式定位工程根。
HERE = os.path.dirname(os.path.abspath(__file__))


def _find_root(start):
    """向上找含 `rtl/` 目录的那一层，即工程根"""
    d = start
    for _ in range(5):
        if os.path.isdir(os.path.join(d, "rtl")):
            return d
        d = os.path.dirname(d)
    return os.path.dirname(start)


ROOT = _find_root(HERE)
VERIFY = HERE if os.path.basename(ROOT) == os.path.basename(os.path.dirname(HERE)) else HERE

CYCLE_VARS = {"i", "k", "j", "gi", "ci", "n", "m"}

def collect_consts(src):
    """本文件声明的 parameter / localparam / genvar / integer 名（这些不是乘法操作数）"""
    cs = set(re.findall(r"\b(?:local)?parameter\s+(?:integer\s+|signed\s+)?(?:\[[^\]]*\]\s*)?(\w+)", src))
    cs |= set(re.findall(r"\bgenvar\s+(\w+)", src))
    for m in re.finditer(r"\binteger\s+([\w\s,]+);", src):
        cs |= {x.strip() for x in m.group(1).split(",") if x.strip()}
    return cs | CYCLE_VARS

def find_mults(path):
    """返回 [(行号, 'a * b')]，已排除常量/循环变量与参数声明行"""
    src = open(path, encoding="utf-8", errors="replace").read()
    code = re.sub(r"//[^\n]*", "", src)
    cs = collect_consts(src)
    out = []
    for ln, line in enumerate(code.split("\n"), 1):
        if re.match(r"\s*(local)?parameter\b", line):
            continue
        # ⚠ 操作数可以是 `$signed(x)` / `x[..]` / `(expr)` 结尾，
        #   所以 `*` 左边的边界不能只认 `\w`（否则会漏数 `$signed(m0) * oned`）
        for m in re.finditer(r"([A-Za-z_$][\w$]*(?:\([^()]*\)|\[[^\]]*\])?)\s*\*\s*"
                             r"([A-Za-z_$][\w$]*(?:\([^()]*\)|\[[^\]]*\])?)", line):
            a, b = m.group(1), m.group(2)
            # 取最内层标识符名，用于常量排除
            na = re.search(r"[A-Za-z_]\w*", a)
            nb = re.search(r"[A-Za-z_]\w*", b)
            na, nb = (na.group(0) if na else a), (nb.group(0) if nb else b)
            if na in cs or nb in cs:
                continue
            out.append((ln, f"{a.strip()} * {b.strip()}"))
    return out

def build_module_map(rtl_dir):
    mods = {}
    for f in glob.glob(os.path.join(rtl_dir, "*.v")):
        src = open(f, encoding="utf-8", errors="replace").read()
        for m in re.finditer(r"^\s*module\s+(\w+)", src, re.M):
            mods[m.group(1)] = f
    return mods

def deps_of(top, mods):
    seen = set()
    def rec(t):
        if t in seen or t not in mods:
            return
        seen.add(t)
        src = re.sub(r"//[^\n]*", "", open(mods[t], encoding="utf-8", errors="replace").read())
        for m in mods:
            if m != t and re.search(r"\b" + m + r"\s*(#\s*\(|[A-Za-z_]\w*\s*\()", src):
                rec(m)
    rec(top)
    return seen

def main():
    ap = argparse.ArgumentParser(description="乘法器（DSP）估算")
    ap.add_argument("--top", help="只统计该顶层用到的模块")
    ap.add_argument("--rtl", default=os.path.join(ROOT, "rtl"))
    args = ap.parse_args()

    mods = build_module_map(args.rtl)
    if not mods:
        print(f"没找到 RTL：{args.rtl}")
        return 1

    if args.top:
        if args.top not in mods:
            print(f"找不到顶层 {args.top}")
            return 1
        use = deps_of(args.top, mods)
        files = sorted({mods[m] for m in use})
        print(f"顶层 `{args.top}` 用到 {len(use)} 个模块 / {len(files)} 个文件")
    else:
        files = sorted(mods.values())

    print()
    print(f"  {'模块':22s} {'乘法器':>6s}   表达式")
    print("  " + "-" * 66)
    tot = 0
    for f in files:
        hits = find_mults(f)
        if not hits:
            continue
        tot += len(hits)
        print(f"  {os.path.basename(f):22s} {len(hits):>6d}   {hits[0][1]}"
              + (f"  …(共 {len(hits)} 处)" if len(hits) > 1 else ""))
        for ln, e in hits[1:]:
            print(f"  {'':22s} {'':>6s}   {e}")
    print("  " + "-" * 66)
    print(f"  {'合计':22s} {tot:>6d} 个乘法器")
    print()
    print("  ⚠ 说明：")
    print("    · 这是**上界估计** —— 综合器会对控制率/事件率的乘法做共享复用，实际更少")
    print("    · 逐采样路径上的乘法器基本无法复用（那才是真正占 DSP 的）")
    print("    · 器件 DSP = 298 个（M0 27×18 与 M1 12×12）；最终以 IDE 报告为准")
    return 0

if __name__ == "__main__":
    sys.exit(main())
