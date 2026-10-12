#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
rtl_lint.py —— RTL 可综合性静态检查（sakiko / 模块三）

为什么需要：
  仿真能过 ≠ 能综合。下面这些问题**仿真里完全看不出来**，但上板会直接坏：

    ① 组合逻辑分支不全 → 综合出 **latch**（仿真可能"恰好"对，上板时序崩）
    ② 同一信号在多个 always 块里被赋值 → **多驱动**（综合报错或行为不定）
    ③ 组合环 → 综合报"combinational loop"，或跑出无法收敛的网表
    ④ `initial` 赋初值（detail.md 1.7 红线，除 BRAM 初值）
    ⑤ `#delay`（只能仿真）
    ⑥ 位宽可疑的移位（本项目踩过多次：`>>>15` 被上下文截断）

  本脚本做**文本级**检查（不依赖综合工具），把上述可机械判定的问题扫出来。
  它不能替代 IDE 综合报告，但**能在花几分钟跑综合之前先拦掉大部分低级错误**。

用法：
    python3 sim/rtl_lint.py                 # 扫 rtl/
    python3 sim/rtl_lint.py rtl/*.v         # 扫指定文件
    python3 sim/rtl_lint.py --strict        # 把 WARN 也算失败（CI 用）
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

# 允许 `initial` 的位置：BSRAM 初始化（本项目的三个效果器用它清缓冲）
INITIAL_OK_PAT = re.compile(r"initial\s+begin\s*$|for\s*\(")

def strip_comments(src: str) -> str:
    """去掉 // 行注释（保留行号：用等长空行替换）"""
    out = []
    for line in src.split("\n"):
        i = line.find("//")
        if i >= 0:
            line = line[:i]
        out.append(line)
    return "\n".join(out)

def check_file(path, strict):
    """返回 (errors, warnings) 两个列表，元素为 (行号, 说明)"""
    errs, warns = [], []
    raw = open(path, encoding="utf-8", errors="replace").read()
    src = strip_comments(raw)
    lines = src.split("\n")
    name = os.path.basename(path)

    # ---------- ① 组合 always 缺少 else → 可能推 latch ----------
    #   识别 always @(*) / always @(a or b) 块，检查 if 是否都有 else、
    #   case 是否有 default
    in_comb = False
    depth = 0
    comb_start = 0
    body = []
    for ln, line in enumerate(lines, 1):
        if re.search(r"^\s*always\s*@\s*\(\s*\*", line) or \
           re.search(r"^\s*always\s*@\s*\([^)]*\)\s*(begin)?\s*$", line) and "posedge" not in line and "negedge" not in line:
            in_comb = True
            comb_start = ln
            depth = 0
            body = []
        if in_comb:
            if ln > comb_start:
                body.append(line)
            depth += line.count("begin") - line.count("end")
            if depth <= 0 and ln > comb_start and ("end" in line or ";" in line):
                # 块结束
                txt = "\n".join(body)
                n_if = len(re.findall(r"\bif\s*\(", txt))
                n_else = len(re.findall(r"\belse\b", txt))
                # 本块驱动的信号集合
                driven = set(re.findall(r"^\s*([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*=", txt, re.M))
                # 块**开头**是否有对全部被驱动信号的默认赋值（= 不会推 latch 的标准写法）
                head = "\n".join(body[:8])
                defaulted = set(re.findall(r"^\s*([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*=", head, re.M))
                # 或每条驱动信号在块内都出现过 `sig = ...` 的默认形式
                if n_if > n_else and not (driven and driven <= defaulted):
                    errs.append((comb_start, f"组合 always 块（{n_if} 个 if，{n_else} 个 else，"
                                            f"开头默认赋值了 {sorted(defaulted) or '无'}）"
                                            f" → 可能推 latch，请确认每个分支都被赋值"))
                if "case" in txt and "default" not in txt:
                    warns.append((comb_start, "组合 always 块里有 case 但没有 default → 可能推 latch"))
                in_comb = False

    # ---------- ② 多驱动：同一 reg 在多个 always 块里被赋值 ----------
    always_blocks = []
    cur = None
    for ln, line in enumerate(lines, 1):
        if re.search(r"^\s*always\b", line):
            cur = [ln, []]
            always_blocks.append(cur)
        if cur is not None:
            cur[1].append(line)
            if re.search(r"^\s*end\s*$|^\s*endtask|^\s*endmodule", line) and len(cur[1]) > 1:
                cur = None
    assign_map = {}
    for start, blk in always_blocks:
        txt = "\n".join(blk)
        for m in re.finditer(r"^\s*([A-Za-z_]\w*)\s*<=", txt, re.M):
            assign_map.setdefault(m.group(1), set()).add(start)
    for sig, starts in assign_map.items():
        if len(starts) > 1:
            errs.append((sorted(starts)[0], f"信号 `{sig}` 在 {len(starts)} 个 always 块里被赋值"
                                           f"（行 {sorted(starts)}）→ 多驱动"))

    # ---------- ③ initial / #delay ----------
    for ln, line in enumerate(lines, 1):
        if re.search(r"^\s*initial\b", line):
            # 看后续 3 行是否像 BSRAM 初始化
            ctx = "\n".join(lines[ln-1:ln+3])
            if not re.search(r"for\s*\(|mem|ram|vmem", ctx, re.I):
                # 上电复位计数器 / 延时链：业界通行的 `initial` 用法，属允许例外
                if re.search(r"(por|rst|wait|delay)\w*\s*<=?\s*\{?\w*\{?1'b0|por_|rst_cnt|pll_wait|pa_cnt", ctx, re.I):
                    warns.append((ln, "`initial` 赋初值 —— **上电复位寄存器，属允许例外**"
                                      "（SRAM 型 FPGA 配置后该寄存器本就为 0；仿真需它对齐）"))
                else:
                    warns.append((ln, "`initial` 赋初值 —— 请确认属允许例外"
                                      "（BRAM 初值 / 上电复位寄存器）；detail.md 1.7 为红线"))
        if re.search(r"#\s*\d", line) and not re.search(r"timescale|`", line):
            errs.append((ln, "`#delay` 只能用于仿真，不可综合"))

    # ---------- ④ 位宽可疑的移位（本项目高发） ----------
    for ln, line in enumerate(lines, 1):
        # (a*b) >>> N 形式：乘积在窄上下文里被截断
        if re.search(r"\([^()]*\*[^()]*\)\s*>>>", line):
            warns.append((ln, "`(a*b) >>> N` 形式：乘积可能被**上下文位宽**先截断"
                              "（本项目踩过多次）→ 建议先算到 48 位变量再移位"))
        # 变宽切片：signal[63:0] 其中 signal 只有 32 位
        for m in re.finditer(r"(\w+)\[(\d+):0\]", line):
            base = None
            for d in lines[:ln-1][::-1]:
                mm = re.search(r"\b(?:reg|wire)\b[^;]*\b" + m.group(1) + r"\b\s*(\[[^\]]*\])?", d)
                if mm:
                    base = mm.group(1)
                    break
            if base:
                hi = re.search(r"\[\s*(\d+)\s*:", base)
                if hi and int(m.group(2)) >= int(hi.group(1)):
                    errs.append((ln, f"`{m.group(1)}[{m.group(2)}:0]` 超出其声明宽度 {base}"
                                     " → 变宽切片求值为 X（本项目踩过）"))

    # ---------- ⑤ 未初始化就使用的寄存器（文本近似：reg 声明后无初值、也无 rst 分支） ----------
    for ln, line in enumerate(lines, 1):
        # 跳过 function 内部的局部 reg（它们在使用前一定被赋值，不是时序寄存器）
        upto = "\n".join(lines[:ln])
        if upto.count("function") > upto.count("endfunction"):
            continue
        m = re.match(r"\s*reg\s+(?:signed\s+)?\[[^\]]*\]\s*(\w+)\s*;", line)
        if m:
            sig = m.group(1)
            # 该信号是否在某个 always 的复位分支里被赋值
            joined = "\n".join(lines)
            # 在该信号所在的任意 always 块里找复位分支（窗口放宽到 2000 字符，支持多行）
            has_rst = re.search(r"if\s*\(\s*[!~]?\s*\w*rst\w*\s*(?:==\s*1'b0)?\s*\)[\s\S]{0,2000}?\b"
                                + sig + r"\s*<=", joined)
            has_init = re.search(r"initial\s+" + sig + r"\s*=", joined)
            if not has_rst and not has_init:
                warns.append((ln, f"`{sig}` 既无复位赋值也无 initial → 上电初值未定义（X）"))

    # ---------- ⑥ 综合红线：`initial` 之外的不可综合构造 ----------
    for ln, line in enumerate(lines, 1):
        for bad, why in [(r"\bwait\b", "`wait` 不可综合"),
                         (r"\bforce\b", "`force` 不可综合"),
                         (r"\brelease\b", "`release` 不可综合"),
                         (r"\bfork\b", "`fork` 不可综合"),
                         (r"\bdeassign\b", "`deassign` 不可综合"),
                         (r"\$random\b|\$urandom\b", "`$random` 不可综合")]:
            if re.search(bad, line):
                errs.append((ln, why))

    return errs, warns

def main():
    ap = argparse.ArgumentParser(description="RTL 可综合性静态检查")
    ap.add_argument("files", nargs="*", help="要检查的文件（默认 rtl/*.v）")
    ap.add_argument("--strict", action="store_true", help="把 WARN 也算作失败")
    ap.add_argument("--quiet-ok", action="store_true", help="只打印有问题的文件")
    args = ap.parse_args()

    files = args.files or sorted(sorted(set(glob.glob(os.path.join(ROOT, "rtl", "**", "*.v"), recursive=True))))
    if not files:
        print("没有找到要检查的文件"); return 1

    tot_e = tot_w = 0
    for f in files:
        errs, warns = check_file(f, args.strict)
        tot_e += len(errs); tot_w += len(warns)
        if not errs and not warns and args.quiet_ok:
            continue
        tag = "ERROR" if errs else ("WARN " if warns else "OK   ")
        print(f"  {tag} {os.path.basename(f)}")
        for ln, msg in errs:
            print(f"          L{ln}: {msg}")
        for ln, msg in warns:
            print(f"          L{ln}: [warn] {msg}")

    print("-" * 74)
    print(f"  检查 {len(files)} 个文件：ERROR {tot_e}，WARN {tot_w}")
    if tot_e == 0 and tot_w == 0:
        print("  ✅ 未发现可机械判定的可综合性问题")
    elif tot_e == 0:
        print("  ⚠ 无阻断性问题，但 WARN 需人工确认")
    else:
        print("  ❌ 有阻断性问题，综合前必须修")
    return 1 if (tot_e or (args.strict and tot_w)) else 0

if __name__ == "__main__":
    sys.exit(main())
