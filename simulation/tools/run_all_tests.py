#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
run_all_tests.py —— 项目统一测试入口（sakiko / 模块三）

职责：
  1. 发现并运行全项目所有 Verilog testbench（模块三 / 单声部 / 任何后续新增）
  2. 逐条解析 PASS / FAIL，汇总成一张表
  3. 发现"编译通过但没输出 PASS/FAIL"的 TB（静默通过 = 没验证，必须报出来）
  4. 输出 JUnit XML，便于接 CI
  5. 与 `sim/run.sh` 的分工：run.sh 是模块三的**快速回归**（shell，秒级）；
     本脚本是**全项目统一入口**（python，含结果解析与报告）

为什么用 Python 而不是纯 shell：
  · 需要**解析**每个 TB 的结果、统计项数、检测"静默通过"
  · 需要生成机器可读报告（JUnit XML）
  · 后续要给 majiao / poki 的模块生成**激励与金标准文件**，语言统一在 Python 侧

用法：
    python3 sim/run_all_tests.py              # 跑全部
    python3 sim/run_all_tests.py tb_fx_reverb # 只跑指定的（可多个）
    python3 sim/run_all_tests.py --list       # 只列出发现的 TB
    python3 sim/run_all_tests.py --xml out.xml
"""

import argparse
import glob
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from xml.dom import minidom

# ----------------------------------------------------------------------------
# 路径
# ----------------------------------------------------------------------------
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


ROOT = _find_root(HERE)          # 工程根（含 rtl/ 的那一层）
PARENT = os.path.dirname(ROOT)   # 工程根的上一层（外部资料可能在那边）



def _find_aux(name):
    """定位辅助文件（仿真桩 / 共享 include / 系数表）。

    ⚠ 位置**随仓库布局变**：
       · 我本地工作区：与工具同在 `test/sim/`
       · 合并仓库：    `simulation/models/`（桩与 vh）、`rtl/scheduler/`（hex）
    早先写死 `HERE/name`，换布局后报 `No such file or directory`，
    而 iverilog 的报错是"找不到根模块"（误导性很强）。**踩过。**
    """
    cands = [os.path.join(HERE, name),
             os.path.join(ROOT, "simulation", "models", name),
             os.path.join(ROOT, "models", name),
             os.path.join(ROOT, "rtl", "scheduler", name),
             os.path.join(ROOT, "wave_table", "out", name)]
    for c in cands:
        if os.path.isfile(c):
            return c
    return cands[0]

def _pick(*cands):
    """返回第一个存在的候选路径

    为什么需要：`demo/` 与 `new/` 是**外部资料/演示**，可能被放在工程根下、
    也可能被放在 `myMain/` 里。脚本要**两个位置都认**，否则工程一搬就找不到 TB。
    """
    for c in cands:
        if os.path.exists(c):
            return c
    return cands[0]


DEMO_DIR = _pick(os.path.join(ROOT, "demo"), os.path.join(PARENT, "demo"))
BOARD_DIR = _pick(os.path.join(ROOT, "board"), os.path.join(PARENT, "board"))
IV   = "/work/.tools/iverilog/bin"
IVERILOG = os.path.join(IV, "iverilog")
VVP      = os.path.join(IV, "vvp")
#  ⚠ TB 往 **CWD 下的 `out/`** 写 CSV，所以「TB 的 CWD」与「OUT」必须指向**同一处**。
#    统一放到 `verify/out`（HERE 的上一级），这样 `myMain/` 根目录保持干净、
#    所有验证生成物都归在 `verify/` 下（踩过：两处不一致会报"打不开 out/..."）
VERIFY_DIR = os.path.dirname(HERE)
OUT      = os.path.join(VERIFY_DIR, "out")

STUB = _find_aux("gowin_prim_stub.v")     # Gowin 原语仿真桩

# 每个 TB 需要的源文件集合。默认是"我的模块三 RTL + 桩"；
# 将来别的模块（单声部等）加进来时，在这里登记它自己的源文件列表即可。
# 共享头文件（内含 `sine_src` 模块定义）—— 必须作为源文件传入，
# 否则 `include 展开后 `sine_src` 的模块体虽然可见，但 iverilog 需要它出现在文件列表里
SHARED_VH = [_find_aux("sine_src.vh")]

RTL_SETS = {
    "default":  [STUB] + SHARED_VH + sorted(sorted(set(glob.glob(os.path.join(ROOT, "rtl", "**", "*.v"), recursive=True)))),
    "board":    [os.path.join(BOARD_DIR, "board_audio_test.v")],        # 上板自检设计
    "demo":     [STUB] + sorted(sorted(set(glob.glob(os.path.join(ROOT, "rtl", "**", "*.v"), recursive=True)))),
}

# TB 名 -> (源文件集合 key, 额外 iverilog 参数列表)
# 需要编译期参数（-P）的 TB 在这里登记
TB_EXTRA = {
    # 旁路：全开（None）+ 4 种旁路组合
    "tb_fx_bypass": [None, ("REV_EN=0",), ("CHO_EN=0",), ("DEL_EN=0",),
                     ("REV_EN=0", "CHO_EN=0", "DEL_EN=0")],
    # 顶层两种时钟配置都要验（板上两种都会用到）
    "tb_mix_top":   [None, ("USE_PLL=1",)],
    "tb_full_top":  [None, ("USE_PLL=1",)],
}

# 上板自检的 TB 在 board/ 下
# 调试/测量类工具，不是"测试"（没有 PASS/FAIL 判据），统一入口跳过
#   tb_dc_debug : 逐拍打印的调试用
#   tb_fx_lat   : 延迟测量工具（一次性）
#   tb_rev_dbg  : 混响写地址诊断
TOOL_TBS = {"tb_dc_debug", "tb_fx_lat", "tb_rev_dbg"}

# 需要在特定工作目录下运行的 TB（它们会写相对路径的输出文件）
#   tb_full_chain 要写 `out/demo.txt`，所以必须在 demo/ 下跑
TB_CWD = {"tb_full_chain": DEMO_DIR}

# 长测试（默认跳过，用 --long 才跑）
#   tb_full_chain 跑 8000 样本出 WAV，约 146 s；
#   完整链路的功能覆盖已由 tb_full_top（15 s）承担，故不必每次回归都跑它。
LONG_TBS = {"tb_full_chain"}

TB_SEARCH_DIRS = [
    (os.path.join(HERE, "tb_*.v"),           "default"),   # 含 tb_integration
    (os.path.join(BOARD_DIR, "tb_*.v"), "board"),
    (os.path.join(DEMO_DIR,  "tb_*.v"), "demo"),
]

# ----------------------------------------------------------------------------
# 结果解析
# ----------------------------------------------------------------------------
RE_PASS  = re.compile(r"^\s*PASS\b(.*)$", re.M)
RE_FAIL  = re.compile(r"^\s*FAIL\b(.*)$", re.M)
RE_FINISH = re.compile(r"\$finish")

def parse_result(log: str):
    """返回 (状态, 说明)。状态 ∈ PASS / FAIL / SILENT / TIMEOUT"""
    if "TIMEOUT" in log.upper() and RE_FAIL.search(log):
        pass
    passes = RE_PASS.findall(log)
    fails  = RE_FAIL.findall(log)
    if fails:
        msg = fails[0].strip(" :\t")
        return "FAIL", (msg or "FAIL")[:110]
    if passes:
        msg = passes[-1].strip(" :\t")
        return "PASS", (msg or "PASS")[:110]
    if not RE_FINISH.search(log):
        return "TIMEOUT", "没有 $finish（仿真未跑完）"
    return "SILENT", "跑完但没打印 PASS/FAIL —— 这条 TB 等于没验证！"

# ----------------------------------------------------------------------------
# 单个 TB
# ----------------------------------------------------------------------------
def run_one(tb_name, tb_path, src_key, extra_params=None, timeout=600, verbose=False):
    """编译并运行一个 TB，返回 (状态, 说明, 耗时秒)"""
    srcs = RTL_SETS[src_key]
    vvp_out = os.path.join(OUT, f"{tb_name}.vvp")
    # ⚠ 必须带 `-I HERE`：自制 TB 用了共享 include（如 `sine_src.vh`），
    #   不加 include 路径会报 "Include file ... not found"
    cmd = [IVERILOG, "-g2012", "-DSIMULATION", "-I", HERE,
           "-s", tb_name, "-o", vvp_out, *srcs, tb_path]
    if extra_params:
        for p in extra_params:
            cmd.insert(-2, f"-P{tb_name}.{p}")

    t0 = time.time()
    try:
        cp = subprocess.run(cmd, capture_output=True, text=True, timeout=120,
                            errors="replace")
    except subprocess.TimeoutExpired:
        return "TIMEOUT", "编译超时", time.time() - t0
    if cp.returncode != 0 or not os.path.exists(vvp_out):
        err = (cp.stderr or cp.stdout).strip().split("\n")
        return "FAIL", ("编译失败: " + (err[0] if err else "?"))[:110], time.time() - t0

    #  ⚠ 默认工作目录必须是 **ROOT**，不能留 None：
    #    cwd=None 时子进程继承**父进程的 CWD**，于是 TB 往"调用者所在目录/out"写文件，
    #    而 `out/` 是建在 ROOT 下的 → TB 报"打不开 out/..."。
    #    （表现：从仓库根跑就失败、从 ROOT 里跑就正常 —— 典型的 CWD 依赖 bug，踩过）
    cwd = TB_CWD.get(tb_name, VERIFY_DIR)
    try:
        rp = subprocess.run([VVP, vvp_out], capture_output=True, text=True, timeout=timeout,
                             errors="replace", cwd=cwd)
        log = (rp.stdout or "") + (rp.stderr or "")
    except subprocess.TimeoutExpired:
        return "TIMEOUT", f"仿真超时（>{timeout}s）", time.time() - t0

    if verbose:
        sys.stdout.write(log)
    st, msg = parse_result(log)
    return st, msg, time.time() - t0

# ----------------------------------------------------------------------------
def discover():
    """返回 [(tb名, 路径, 源集合key)]"""
    found = []
    for pattern, key in TB_SEARCH_DIRS:
        for p in sorted(glob.glob(pattern)):
            name = os.path.basename(p)[:-2]
            if name in TOOL_TBS:
                continue
            found.append((name, p, key))
    return found

def main():
    ap = argparse.ArgumentParser(description="项目统一测试入口")
    ap.add_argument("tests", nargs="*", help="只跑这些 TB（默认全部）")
    ap.add_argument("--list", action="store_true", help="只列出发现的 TB")
    ap.add_argument("--xml", help="写 JUnit XML 到指定路径")
    ap.add_argument("--verbose", "-v", action="store_true", help="打印 TB 完整输出")
    ap.add_argument("--timeout", type=int, default=600, help="单个 TB 的超时秒数")
    ap.add_argument("--long", action="store_true", help="连长测试一起跑（默认跳过）")
    args = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    #  ⚠ 音频质量类 TB 会往 **CWD 下的 `out/`** 写 CSV（`out/audio_quality.csv` 等）。
    #    若该目录不存在，TB 会直接报"打不开 out/... 要先 mkdir out"而失败。
    #    这里统一保证它存在，避免"删了生成物目录 → 测试莫名挂掉"（踩过）
    os.makedirs(OUT, exist_ok=True)
    #  ⓪ 关键字冲突检查（撞 Verilog/SV 关键字在 iverilog 下常不报错，但综合器会拒）
    if not args.list:
        kws = os.path.join(HERE, "kw_check.py")
        if os.path.isfile(kws):
            _rc = subprocess.run([sys.executable, kws], capture_output=True, text=True).returncode
            print("  " + ("✓" if _rc == 0 else "✗") + " 关键字冲突检查"
                  + ("" if _rc == 0 else "（有冲突，见 kw_check.py 输出）"))
    all_tb = discover()
    if args.list:
        print(f"发现 {len(all_tb)} 个 TB：")
        for n, p, k in all_tb:
            print(f"  {n:22s} [{k:8s}] {os.path.relpath(p, ROOT)}")
        return 0

    targets = all_tb
    if not args.long and not args.tests:
        skipped = [t[0] for t in targets if t[0] in LONG_TBS]
        targets = [t for t in targets if t[0] not in LONG_TBS]
        if skipped:
            print(f"（跳过长测试：{', '.join(skipped)}；要跑加 --long）")
    if args.tests:
        want = set(args.tests)
        targets = [t for t in all_tb if t[0] in want]
        missing = want - {t[0] for t in targets}
        for m in sorted(missing):
            print(f"⚠ 没找到 TB: {m}")

    # ---- 第 0 步：RTL 可综合性静态检查（综合前先拦掉 latch / 多驱动 / 组合环）----
    lint_py = os.path.join(HERE, "rtl_lint.py")
    if os.path.exists(lint_py):
        print("=" * 78)
        print("  第 0 步：RTL 可综合性静态检查")
        print("=" * 78)
        lr = subprocess.run([sys.executable, lint_py, "--quiet-ok"],
                            capture_output=True, text=True, errors="replace", timeout=120)
        out = (lr.stdout or "").strip().split("\n")
        for l in out[-3:]:
            print(f"  {l.strip()}")
        if lr.returncode != 0:
            print("  ⚠ lint 报出阻断性问题（见上），但继续跑测试以便一并看到结果")
        print()

    print("=" * 78)
    print(f"  统一测试入口 · 共 {len(targets)} 个 TB")
    print("=" * 78)

    results = []
    n_pass = n_fail = 0
    total_t = 0.0
    for name, path, key in targets:
        variants = TB_EXTRA.get(name, [None])
        for v in variants:
            if v is None:
                label = name
            elif "USE_PLL" in v[0]:
                label = f"{name}(USE_PLL=1)"
            else:
                label = f"{name}({'+'.join(v)})"
            st, msg, dt = run_one(name, path, key, v, args.timeout, args.verbose)
            total_t += dt
            mark = {"PASS": "PASS", "FAIL": "FAIL", "TIMEOUT": "TIMEOUT", "SILENT": "SILENT"}[st]
            print(f"  {mark:8s} {label:34s} {dt:6.1f}s  {msg}")
            results.append((label, st, msg, dt, name, v))
            if st == "PASS":
                n_pass += 1
            else:
                n_fail += 1

    print("-" * 78)
    print(f"  合计：{len(results)} 项，PASS {n_pass}，FAIL {n_fail}，耗时 {total_t:.1f}s")

    # 重点提醒：静默通过 / 超时
    bad = [r for r in results if r[1] in ("SILENT", "TIMEOUT")]
    if bad:
        print()
        print("  ⚠ 以下 TB 没有给出明确判定，等于没验证：")
        for label, st, msg, _, _, _ in bad:
            print(f"      {st:8s} {label:34s} {msg}")

    if args.xml:
        suite = ET.Element("testsuite", name="fpga-synth", tests=str(len(results)),
                           failures=str(n_fail), time=f"{total_t:.3f}")
        for label, st, msg, dt, name, v in results:
            tc = ET.SubElement(suite, "testcase", name=label, classname=name,
                               time=f"{dt:.3f}")
            if st != "PASS":
                f = ET.SubElement(tc, "failure", message=msg, type=st)
                f.text = msg
        xml = minidom.parseString(ET.tostring(suite, encoding="unicode")).toprettyxml(indent="  ")
        with open(args.xml, "w", encoding="utf-8") as fh:
            fh.write(xml)
        print(f"  JUnit XML 已写入 {args.xml}")

    return 1 if n_fail else 0

if __name__ == "__main__":
    sys.exit(main())
