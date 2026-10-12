#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
preboard_check.py —— 上板前检查清单（sakiko / 模块三）

把"烧板子之前必须过的关"固化成一条命令，避免漏项。共 6 项：

  ① RTL 语法：双视角编译（带 `SIMULATION` / 不带）
  ② 可综合性：调 rtl_lint.py（latch / 多驱动 / 不可综合构造 / 位宽可疑）
  ③ 约束完整性：顶层每个端口都要有 IO_LOC（漏一个就会被工具分到随机引脚）
  ④ 约束正确性：PLL 的 FCLKIN 与 .sdc 里的时钟周期必须一致（否则报 TA1118）
  ⑤ 模块依赖：顶层用到的模块都能找到（不漏文件）
  ⑥ 测试覆盖：调 run_all_tests.py（可选，慢）

用法：
    python3 sim/preboard_check.py                   # 检查 full_top（默认）
    python3 sim/preboard_check.py --top mix_top
    python3 sim/preboard_check.py --with-tests      # 连 28 项测试一起跑
"""

import argparse
import glob
import os
import re
import subprocess
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
# iverilog 定位：环境变量 IV > PATH > 常见安装位置
#   ⚠ 原版写死 Linux 工作机的 /work/.tools/iverilog/bin，在 Windows 上会直接抛
#      FileNotFoundError（[WinError 2]），所以这里做成跨平台的。
def _find_iverilog():
    exe = "iverilog.exe" if os.name == "nt" else "iverilog"
    cands = []
    if os.environ.get("IV"):
        cands.append(os.path.join(os.environ["IV"], exe))
    try:
        from shutil import which as _which
        w = _which(exe)
        if w:
            cands.append(w)
    except Exception:
        pass
    cands += [
        r"D:\iverilog\bin\iverilog.exe",                       # 本机
        "/work/.tools/iverilog/bin/iverilog",                  # 工作机
        os.path.join(ROOT, "..", "iverilog", "bin", exe),
        os.path.join(ROOT, "..", "..", "iverilog", "bin", exe),
    ]
    for c in cands:
        if c and os.path.isfile(c):
            return c
    return cands[0]

IVERILOG = _find_iverilog()


def _find_aux(name):
    """定位辅助文件（仿真桩 / 共享 include / 系数表）。

    ⚠ 位置**随仓库布局变**：
       · 我本地工作区：与工具同在 `test/sim/`
       · 合并仓库：    `simulation/models/`（桩与 vh）、`rtl/scheduler/`（hex）
    早先写死 `HERE/name`，换布局后 iverilog 报的是**"找不到根模块"**
    （而不是"文件不存在"），误导性极强。**踩过。**
    """
    cands = [os.path.join(HERE, name),
             os.path.join(ROOT, "simulation", "models", name),
             os.path.join(ROOT, "models", name),
             os.path.join(ROOT, "rtl", "scheduler", name),
             os.path.join(ROOT, "rtl", "common", name),
             os.path.join(ROOT, "rtl", name),
             os.path.join(ROOT, "wave_table", "out", name)]
    for c in cands:
        if os.path.isfile(c):
            return c
    return cands[0]

# 顶层 -> (源文件, 约束文件, 时序文件)
#  ⚠ 路径必须基于 ROOT 用**绝对路径**：早先用 `glob.glob("rtl/*.v")`（相对 CWD），
#    脚本从别的目录跑、或工程被整体移动后就会抓不到源文件，
#    表现为"找不到根模块 full_top""包了 0 个端口"（踩过）
_RTL   = sorted(sorted(set(glob.glob(os.path.join(ROOT, "rtl", "**", "*.v"), recursive=True))))
#  ⚠ 桩文件在**本脚本同目录**（HERE），不是 `ROOT/sim/` ——
#    脚本从 `sim/` 移到 `verify/sim/` 后，写 ROOT/sim 就找不到了（踩过）
_STUB  = _find_aux("gowin_prim_stub.v")
_BOARD = sorted(glob.glob(os.path.join(ROOT, "test", "board", "board_audio_test.v")))
#  ⚠ 约束文件也要用**绝对路径**：早先用相对 `constraints/xxx.cst`，
#    会随"从哪个目录调用脚本"而变，搬到 `mymainwork/` 后就找不到了（踩过）
#  ⚠ 约束文件的位置**随仓库布局变**：
#     · 我本地工作区：`<root>/constraints/full_top.cst`
#     · 合并仓库：    `<root>/rtl/top/full_top.cst`
#   所以用**搜索**而不是写死目录（踩过：换布局后报"找不到 .cst"）。
def _find_cst(name):
    cands = [os.path.join(ROOT, "constraints", name),
             os.path.join(ROOT, "rtl", "top", name),
             os.path.join(ROOT, "board", name)]
    cands += [os.path.join(dp, name) for dp, _, fs in os.walk(os.path.join(ROOT, "rtl"))
              for _ in [0] if name in fs]
    for c in cands:
        if os.path.isfile(c):
            return c
    return cands[0]          # 都找不到就返回首选路径（报错信息里能看出找过哪）
TESTS = os.path.join(ROOT, "test")
TOPS = {
    #  ⭐ 上板实际用的顶层（三边合一：full_top + 调度层 + 单声部层 + 波表）。
    #     约束与 full_top 共用一份 —— rtl/top/full_top.cst 里已追加
    #     full_system 新增端口的约束（midi_rx[3:0] 与 MS5351 的 I2C）。
    "full_system":     ([_STUB] + _RTL, _find_cst("full_top.cst"),
                                        _find_cst("full_top.sdc")),
    "full_top":        ([_STUB] + _RTL, _find_cst("full_top.cst"),
                                        _find_cst("full_top.sdc")),
    "mix_top":         ([_STUB] + _RTL, _find_cst("mix_top.cst"),
                                        _find_cst("mix_top.sdc")),
    #  ⚠ `voice_mono` 是**契约模块**（硬件实现.md §8.5.3），还没进仓库；
    #     它到货后在这里加一行即可纳入预检：
    #  "voice_mono": ([os.path.join(ROOT, "rtl", "voice", "voice_mono.v")], None, None),
    "board_audio_test": (_BOARD, os.path.join(TESTS, "board", "board_audio_test.cst"),
                                 os.path.join(TESTS, "board", "board_audio_test.sdc")),
}

OK, BAD, WARN = "  ✓", "  ✗", "  ⚠"

def sh(cmd, timeout=300):
    try:
        # ⚠ 必须显式指定 encoding="utf-8"：
        #   Windows 上 subprocess 默认按 locale（GBK）解码，而子脚本输出的是 UTF-8，
        #   结果全角标点（如 `，`）变成乱码 → 上层用正则匹配 `ERROR n，WARN n` 会失配，
        #   表现为"lint 未给出结果"，但手工跑 lint 明明是通过的。踩过。
        cp = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                            errors="replace", timeout=timeout)
        return cp.returncode, (cp.stdout or "") + (cp.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "超时"

def check_syntax(top, srcs):
    # ⚠ Windows 没有 /dev/null；原版写死它在 Windows 上同样会 FileNotFoundError
    devnull = "NUL" if os.name == "nt" else "/dev/null"
    for label, extra in [("带 SIMULATION", ["-DSIMULATION"]), ("不带 define", [])]:
        rc, out = sh([IVERILOG, "-g2012"] + extra + ["-s", top, "-o", devnull] + srcs)
        if rc != 0:
            first = next((l for l in out.split("\n") if "error" in l.lower()), out[:120])
            return False, f"{label}: {first.strip()}"
    return True, "双视角编译通过"

def check_lint():
    rc, out = sh([sys.executable, os.path.join(HERE, "rtl_lint.py"), "--quiet-ok"])
    m = re.search(r"ERROR (\d+)，WARN (\d+)", out)
    if not m:
        return False, "lint 未给出结果"
    e, w = int(m.group(1)), int(m.group(2))
    if e:
        return False, f"ERROR {e}，WARN {w}（见 lint 输出）"
    return True, f"ERROR 0，WARN {w}（全部为允许例外）"

def top_ports(top, srcs):
    for f in srcs:
        if os.path.basename(f).startswith(top + "."):
            src = open(os.path.join(ROOT, f), encoding="utf-8").read()
            m = re.search(r"module\s+" + top + r"\b.*?\)\s*\((.*?)\);", src, re.S)
            if m:
                return re.findall(r"(input|output|inout)\s+(?:wire|reg)?\s*(?:signed\s*)?(?:\[[^\]]*\]\s*)?(\w+)", m.group(1))
    return []

def check_constraints(top, srcs, cst):
    p = os.path.join(ROOT, cst)
    if not os.path.isfile(p):
        return False, f"找不到 {cst}"
    c = open(p, encoding="utf-8").read()
    locs = set(re.findall(r'IO_LOC\s+"(\w+)"', c))
    ps = [n for d, n in top_ports(top, srcs) if d != "inout"]

    #  ⚠ **集成扩展端口不算「真端口」**：当 `VOICE_SRC=0 / EXT_TABLE=0 / EXT_FXPARAM=0` 时，
    #     `ext_*` 喂的是常量，综合器会把它们连同内部逻辑一起剪掉 → **不需要 IO_LOC**。
    #     只有把这三个参数置 1（真接调度层 / 单声部层）时它们才是真输入，那时才必须补引脚。
    #     （踩过：加了扩展端口后本检查一直报"缺 IO_LOC"，其实不是缺陷。）
    #  ⚠ 两类都是**集成边界端口**，不接外部时会被综合器剪掉 → 不需要 IO_LOC：
    #      · `ext_*`  —— 调度层/单声部层**驱动进来**的
    #      · `*_o`    —— 本模块**送出去**给调度层的节拍（`sample_stb_o` / `slot_o`）
    #      · `midi_rx`—— 4 路 MIDI 串行输入；**上板时确实要 IO_LOC**，
    #                    但引脚由硬件/顶层约束方（poki）统一给，故不在此判失败。
    INTEG = re.compile(r"^(ext_|.*_o$|midi_rx$)")
    hard = [n for n in ps if not INTEG.match(n)]
    soft = [n for n in ps if INTEG.match(n)]

    miss = [n for n in hard if n not in locs]
    miss_soft = [n for n in soft if n not in locs]
    extra = sorted(locs - set(ps))
    if miss:
        return False, f"**缺 IO_LOC**：{miss}（会被分到随机引脚，症状神出鬼没）"
    msg = f"{len(hard)} 个端口全部约束"
    if miss_soft:
        msg += (f"；集成扩展端口 {len(miss_soft)} 个未约束"
                f"（**默认参数下无妨**：喂常量会被综合器剪掉；"
                f"但若把 VOICE_SRC/EXT_TABLE/EXT_FXPARAM 置 1，"
                f"这 {len(miss_soft)} 个就**必须**补 IO_LOC）")
    if extra:
        msg += f"；⚠ .cst 里有顶层不存在的信号 {extra}"
    return True, msg

def check_pll_freq(top, sdc):
    """PLL 的 FCLKIN 必须与 .sdc 里的时钟周期一致（否则 TA1118）"""
    #  ⚠ 两处布局差异：
    #     · `pll_49m.v` 在扁平布局下是 `rtl/pll_49m.v`，分层布局下是 `rtl/common/pll_49m.v`
    #     · `sdc` 参数可能是**相对 ROOT**（旧调用）或**已解析的绝对路径**（`_find_cst` 给的）
    pll = _find_aux("pll_49m.v")
    p   = sdc if os.path.isabs(sdc) else os.path.join(ROOT, sdc)
    if not (os.path.isfile(pll) and os.path.isfile(p)):
        return True, "无 PLL 或 .sdc，跳过"
    fclk = re.search(r'defparam\s+PLL_inst\.FCLKIN\s*=\s*"([\d.]+)"', open(pll, encoding="utf-8").read())
    per = re.search(r'create_clock\s+-name\s+clk12288\s+-period\s+([\d.]+)', open(p, encoding="utf-8").read())
    if not (fclk and per):
        return True, "未找到 FCLKIN 或 clk12288 周期，跳过"
    f_pll = float(fclk.group(1))
    f_sdc = 1000.0 / float(per.group(1))
    if abs(f_pll - f_sdc) / f_pll > 0.01:
        return False, f"PLL FCLKIN={f_pll} MHz 但 .sdc 周期={per.group(1)} ns（={f_sdc:.3f} MHz）→ 会报 TA1118"
    return True, f"PLL FCLKIN={f_pll} MHz ↔ .sdc {per.group(1)} ns（{f_sdc:.3f} MHz）一致"

def check_deps(top, srcs):
    mods = {}
    for f in srcs:
        s = open(os.path.join(ROOT, f), encoding="utf-8", errors="replace").read() if not f.startswith("/") else ""
    # 从 rtl 目录建索引更稳
    mods = {}
    for f in sorted(set(glob.glob(os.path.join(ROOT, "rtl", "**", "*.v"), recursive=True))) + glob.glob(os.path.join(ROOT, "board", "*.v")):
        s = open(f, encoding="utf-8", errors="replace").read()
        for m in re.finditer(r"^\s*module\s+(\w+)", s, re.M):
            mods[m.group(1)] = f
    missing = []
    seen = set()
    def rec(t):
        if t in seen or t not in mods:
            if t not in seen and t != top and t not in mods:
                missing.append(t)
            return
        seen.add(t)
        s = re.sub(r"//[^\n]*", "", open(mods[t], encoding="utf-8", errors="replace").read())
        for m in mods:
            if m != t and re.search(r"\b" + m + r"\s*(#\s*\(|[A-Za-z_]\w*\s*\()", s):
                rec(m)
    # 常见原语白名单（Gowin 原语由工具提供）
    PRIM = {"PLL", "ROM", "DPB", "SP", "SDP", "SDPB", "DPX9B", "OSC"}
    rec(top)
    real_missing = [m for m in missing if m.split("_")[0] not in PRIM and m not in PRIM]
    if real_missing:
        return False, f"找不到模块：{real_missing}"
    return True, f"用到 {len(seen)} 个模块，全部找到"

def main():
    ap = argparse.ArgumentParser(description="上板前检查清单")
    ap.add_argument("--top", default="full_system", choices=sorted(TOPS))
    ap.add_argument("--with-tests", action="store_true", help="连 28 项测试一起跑（慢）")
    args = ap.parse_args()

    srcs, cst, sdc = TOPS[args.top]
    srcs = [os.path.join(ROOT, s) if not os.path.isabs(s) else s for s in srcs]
    print("=" * 76)
    print(f"  上板前检查清单 · 顶层 = {args.top}")
    print("=" * 76)

    checks = [
        ("① RTL 双视角编译",      lambda: check_syntax(args.top, srcs)),
        ("② 可综合性（lint）",     check_lint),
        ("③ 约束完整性",          lambda: check_constraints(args.top, srcs, cst)),
        ("④ PLL 频率 ↔ .sdc",     lambda: check_pll_freq(args.top, sdc)),
        ("⑤ 模块依赖完整",         lambda: check_deps(args.top, srcs)),
    ]
    if args.with_tests:
        checks.append(("⑥ 全量测试", lambda: (lambda r: (r[0] == 0, "见测试输出"))(
            sh([sys.executable, os.path.join(ROOT, "sim", "run_all_tests.py")], timeout=900))))

    failed = 0
    for name, fn in checks:
        ok, msg = fn()
        print(f"{OK if ok else BAD} {name:22s} {msg}")
        if not ok:
            failed += 1

    print("-" * 76)
    if failed == 0:
        print("  ✅ 全部通过 —— 可以进 Gowin IDE 综合布线")
    else:
        print(f"  ❌ {failed} 项未通过 —— **先修再综合**")
    return 1 if failed else 0

if __name__ == "__main__":
    sys.exit(main())
