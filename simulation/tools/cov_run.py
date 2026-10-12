#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cov_run.py —— 全 TB 覆盖率收集与聚合（sakiko / 测试统筹）

思路：
  本环境的 iverilog 不支持 `-pfileline` 行覆盖，所以改用 `sim/covmon.c`
  （一个自写的 **VPI 模块**）做两件更有用的事：

    ① **翻转覆盖**：设计里每个"控制/状态类"信号的每一位是否至少翻转过一次
    ② **取值覆盖**：窄信号（≤16 位）出现过的**不同取值**集合
       → 对状态机最有用：能直接看出「哪个状态从未进入」

  本脚本把**所有 TB** 各跑一遍，然后把结果**按信号名聚合**：
  某个信号只要在**任一** TB 里被覆盖到，就算覆盖（因为测的是"设计有没有测到"，
  不要求每个 TB 都测全）。

用法：
    python3 sim/cov_run.py                 # 跑全部 TB 并聚合
    python3 sim/cov_run.py tb_fx_reverb    # 只跑指定的
    python3 sim/cov_run.py --keep          # 保留每个 TB 的原始报告

前置：先编译 VPI 模块（脚本会自动做）
"""

import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
from collections import defaultdict

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
SIM = os.path.join(ROOT, "sim")
IV = "/work/.tools/iverilog/bin"
IVERILOG = os.path.join(IV, "iverilog")
VVP = os.path.join(IV, "vvp")
WORK = os.path.join(SIM, "cov_work")
VPI = os.path.join(SIM, "covmon.vpi")

# 与 run_all_tests.py 保持一致：排除调试/测量类与长测试
TOOL_TBS = {"tb_dc_debug", "tb_fx_lat", "tb_rev_dbg"}
LONG_TBS = {"tb_full_chain"}
TB_CWD = {"tb_full_chain": os.path.join(ROOT, "demo")}
STUB = os.path.join(SIM, "gowin_prim_stub.v")


def build_vpi():
    if os.path.exists(VPI) and os.path.getmtime(VPI) > os.path.getmtime(os.path.join(SIM, "covmon.c")):
        return True
    inc = "/work/.tools/iverilog/include/iverilog"
    rc = subprocess.run(["gcc", "-shared", "-fPIC", "-I" + inc,
                         "-o", VPI, os.path.join(SIM, "covmon.c")],
                        capture_output=True, text=True)
    if rc.returncode != 0:
        print("❌ 编译 covmon.vpi 失败：\n" + (rc.stderr or "")[:800])
        return False
    return True


def discover():
    out = []
    for pat in [os.path.join(SIM, "tb_*.v"), os.path.join(ROOT, "board", "tb_*.v")]:
        for p in sorted(glob.glob(pat)):
            n = os.path.basename(p)[:-2]
            if n in TOOL_TBS or n in LONG_TBS:
                continue
            out.append((n, p))
    return out


def parse_report(path):
    """解析一个 covmon 报告 → (untoggled: {sig: (width, bitlist)}, values: {sig: (width, set)})"""
    untog, vals = {}, {}
    if not os.path.exists(path):
        return untog, vals
    txt = open(path, encoding="utf-8", errors="replace").read()

    in_untog = "=== ①" in txt
    for line in txt.split("\n"):
        if line.startswith("=== ②"):
            in_untog = False
            continue
        if in_untog:
            m = re.match(r"\s+(\S+)\s+宽\s*(\d+)\s+未翻转\s+(\d+) 位:\s*(.*)$", line)
            if m:
                sig, w = m.group(1), int(m.group(2))
                bits = set()
                for part in m.group(4).split(","):
                    part = part.strip()
                    if part.isdigit():
                        bits.add(int(part))
                untog[sig] = (w, bits)
        else:
            m = re.match(r"\s+(\S+)\s+宽\s*(\d+)\s+见过\s*(\d+) 种.*?:\s*(.*)$", line)
            if m:
                sig, w = m.group(1), int(m.group(2))
                vset = set()
                for tok in m.group(4).split():
                    if tok.startswith("..."):
                        break
                    if tok.isdigit():
                        vset.add(int(tok))
                vals[sig] = (w, vset)
    return untog, vals


def main():
    ap = argparse.ArgumentParser(description="全 TB 覆盖率收集与聚合")
    ap.add_argument("tests", nargs="*", help="只跑这些 TB")
    ap.add_argument("--keep", action="store_true", help="保留每个 TB 的原始报告")
    args = ap.parse_args()

    if not build_vpi():
        return 1
    os.makedirs(WORK, exist_ok=True)

    tbs = discover()
    if args.tests:
        want = set(args.tests)
        tbs = [t for t in tbs if t[0] in want]
    print("=" * 74)
    print(f"  覆盖率收集 · {len(tbs)} 个 TB（VPI 监视器）")
    print("=" * 74)

    # 聚合器
    all_untog = defaultdict(lambda: (0, set()))   # sig -> (width, 累计未翻转位)
    all_vals = defaultdict(lambda: (0, set()))    # sig -> (width, 累计取值)
    seen_sigs = set()
    ok_cnt = fail_cnt = 0

    for name, path in tbs:
        vvp = os.path.join(WORK, name + ".vvp")
        rc = subprocess.run([IVERILOG, "-g2012", "-DSIMULATION", "-s", name, "-o", vvp,
                             STUB] + sorted(sorted(set(glob.glob(os.path.join(ROOT, "rtl", "**", "*.v"), recursive=True)))) + [path],
                            capture_output=True, text=True, errors="replace")
        if rc.returncode != 0:
            print(f"  SKIP  {name:34s} 编译失败")
            fail_cnt += 1
            continue
        rep = os.path.join(WORK, "covmon_report.txt")
        if os.path.exists(rep):
            os.remove(rep)
        try:
            rp = subprocess.run([VVP, "-M" + SIM, "-m", "covmon", vvp],
                                capture_output=True, text=True, errors="replace",
                                timeout=600, cwd=WORK)
            passed = "PASS" in (rp.stdout or "")
        except subprocess.TimeoutExpired:
            print(f"  SKIP  {name:34s} 仿真超时")
            fail_cnt += 1
            continue

        untog, vals = parse_report(rep)
        seen_sigs |= set(untog) | set(vals)
        for s, (w, b) in untog.items():
            pw, pb = all_untog[s]
            all_untog[s] = (max(w, pw), pb | b)
        for s, (w, v) in vals.items():
            pw, pv = all_vals[s]
            all_vals[s] = (max(w, pw), pv | v)
        # ⚠ **总是**保留按 TB 报告 —— 聚合工具（fsm_cov.py）需要它来
        #   解析信号路径属于哪个模块；单文件 covmon_report.txt 会被每次运行覆盖，
        #   是不可靠的数据源。
        if os.path.exists(rep):
            shutil.copy(rep, os.path.join(WORK, name + ".cov.txt"))

        print(f"  {'PASS' if passed else 'NOTE':5s} {name:34s} 信号 {len(untog)+len(vals):3d}")
        if passed:
            ok_cnt += 1

    # ---------------- 汇总 ----------------
    print()
    print("=" * 74)
    print("  覆盖汇总（按信号名聚合；任一 TB 覆盖到即算覆盖）")
    print("=" * 74)
    print(f"  统计到 {len(seen_sigs)} 个 DUT 信号；{ok_cnt} 个 TB PASS，{fail_cnt} 个跳过")

    # ① 从未被任何 TB 翻转的位（真·死逻辑或漏测）
    print()
    print("  ① 从未翻转的位（宽 ≤ 32 的控制/状态信号）")
    never = [(s, w, b) for s, (w, b) in all_untog.items()
             if b and w <= 32 and len(b) < w]
    if never:
        never.sort(key=lambda x: (-len(x[2]), x[0]))
        for s, w, b in never[:25]:
            print(f"      {s:56s} 宽{w:2d} 未翻转 {len(b):2d} 位 {sorted(b)[:12]}")
        if len(never) > 25:
            print(f"      …共 {len(never)} 个信号")
    else:
        print("      （无）")

    # ② 取值覆盖：状态类信号是否穷尽
    print()
    print("  ② 取值覆盖（窄信号；「未穷尽」的需人工判断是否正常）")
    state_like = []
    for s, (w, v) in sorted(all_vals.items()):
        if w > 6 or not v:
            continue
        full = 1 << w
        state_like.append((s, w, v, len(v) < full))
    if state_like:
        for s, w, v, notfull in state_like[:30]:
            tag = "未穷尽" if notfull else "已穷尽"
            print(f"      [{tag}] {s:50s} 宽{w} 见过 {sorted(v)}")
        if len(state_like) > 30:
            print(f"      …共 {len(state_like)} 个信号")
    print()
    print("  ⚠ 说明：「未穷尽」**不一定是问题** —— 很多信号的值域小于其位宽")
    print("      （例如 2 位状态机只编了 3 个状态）。需要人工核对编码表。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
