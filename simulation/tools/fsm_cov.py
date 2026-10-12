#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fsm_cov.py —— 状态机可达性覆盖（sakiko / 测试统筹）

为什么单做这个：
  翻转覆盖的原始输出里 **257 个"未翻转信号"绝大多数是噪声** ——
  TB 用的是小幅值样本，24 位数据总线的高位本来就不会翻转，这是正常的。
  真正有验证价值、且能机械判定的是**状态机的状态可达性**：

    从 RTL 里提取「状态寄存器 → localparam 状态编码」，
    再对照覆盖率数据，直接回答：**哪个状态从未进入过？**

做法：
  ① 扫每个 `.v`，找形如
         localparam [1:0] ST_IDLE = 2'd0, ST_ACC = 2'd1, ...;
     的编码组（一个 localparam 声明里定义多个 `名字 = 值`）
  ② 找哪个 reg 是状态寄存器：形如 `reg [1:0] st;`，且 `case (st)` 出现在文件里
  ③ 跑覆盖率收集（或读已有的 cov_work/*.cov.txt），看该 reg 见过哪些值
  ④ 报告：每个状态机的「已到达 / 未到达」状态名

用法：
    python3 sim/fsm_cov.py            # 静态提取 + 用已有覆盖数据比对
    python3 sim/fsm_cov.py --no-data  # 只做静态提取（不比对运行时数据）
"""

import argparse
import glob
import os
import re
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
RTL = os.path.join(ROOT, "rtl")
SIM     = os.path.join(ROOT, "sim")
COVWORK = os.path.join(SIM, "cov_work")

# 状态寄存器可能的命名（本项目统一用 st）
STATE_REG_NAMES = {"st", "state", "fsm", "cs", "cur_state"}
diag = []
mods_present = set()
inst_all = set()
DATA_RAN = False        # 是否真的采集过覆盖率数据（区分"没采集"与"采集了但没状态寄存器"）


def parse_val(tok):
    """把 2'd0 / 3'b101 / 0 / 1'h1 解析成整数"""
    m = re.match(r"\s*(?:\d+)?\s*'\s*([hbd])\s*([0-9a-fA-F_]+)", tok)
    if m:
        base, v = m.group(1), m.group(2).replace("_", "")
        return int(v, {"h": 16, "b": 2, "d": 10}[base])
    m = re.match(r"\s*(\d+)", tok)
    return int(m.group(1)) if m else None


def build_inst_map(files=None):
    """扫给定文件，建 `实例名 -> 模块名` 映射

    为什么必需：VPI 报告里的信号路径形如
        tb_chan_layer.dut.st          ← dut 实例是 chan_layer
        tb_chan_layer.dut.u_buf.st    ← u_buf 实例是 chan_buf
    光看路径**无法知道** `dut` 是哪個模块，必须从源码的实例化语句里查。
    （负向测试时因为没做这一步，导致 6 个 FSM 全被误判成"已到达"。）
    """
    imap = {}
    if files is None:
        files = glob.glob(os.path.join(RTL, "*.v")) + \
                glob.glob(os.path.join(ROOT, "sim", "tb_*.v")) + \
                glob.glob(os.path.join(ROOT, "board", "*.v")) + \
                glob.glob(os.path.join(ROOT, "demo", "*.v"))
    for f in files:
        code = re.sub(r"//[^\n]*", "", open(f, encoding="utf-8", errors="replace").read())
        for m in re.finditer(r"^\s*(\w+)\s*(?:#\s*\([^;]*?\)\s*)?(\w+)\s*\(",
                             code, re.M | re.S):
            mod, inst = m.group(1), m.group(2)
            if mod in ("module", "if", "for", "case", "always", "assign", "begin",
                       "input", "output", "wire", "reg", "initial"):
                continue
            imap.setdefault(inst, mod)
    return imap


def instantiated_modules(tops, all_src):
    """沿实例树做传递闭包，返回这些顶层**实际实例化到的全部模块名**

    为什么需要：报告里只出现"有信号被监视到"的模块。像 `fx_reverb` 被
    `fx_top` 实例化、但它的 `st` 没有出现在报告中（层次更深），
    光看报告会误判成"没实例化"。必须从源码的实例化关系推导。
    """
    # 建 模块名 -> 它实例化出的子模块名集合
    edges = {}
    for f in all_src:
        code = re.sub(r"//[^\n]*", "", open(f, encoding="utf-8", errors="replace").read())
        for mn, a, b in module_ranges(code):
            body = code[a:b]
            subs = set()
            for m in re.finditer(r"^\s*(\w+)\s*(?:#\s*\([^;]*?\)\s*)?(\w+)\s*\(",
                                 body, re.M | re.S):
                mod = m.group(1)
                if mod in ("module", "if", "for", "case", "always", "assign", "begin",
                           "input", "output", "wire", "reg", "initial", "function", "task"):
                    continue
                subs.add(mod)
            edges.setdefault(mn, set()).update(subs)

    seen, stack = set(), list(tops)
    while stack:
        cur = stack.pop()
        if cur in seen:
            continue
        seen.add(cur)
        for nxt in edges.get(cur, ()):
            if nxt not in seen:
                stack.append(nxt)
    return seen


def module_ranges(code):
    """返回 [(模块名, 起始偏移, 结束偏移)]，用于判断某个 reg 属于哪个模块"""
    out = []
    for m in re.finditer(r"^\s*module\s+(\w+)", code, re.M):
        end = len(code)
        em = re.search(r"^\s*endmodule", code[m.end():], re.M)
        if em:
            end = m.end() + em.start()
        out.append((m.group(1), m.start(), end))
    return out


def extract_fsms(path):
    """返回 [(状态寄存器名, {状态名: 值}, 位宽, 所在模块名)]"""
    src = open(path, encoding="utf-8", errors="replace").read()
    code = re.sub(r"//[^\n]*", "", src)
    out = []
    mranges = module_ranges(code)

    def owner(pos):
        for mn, a, b in mranges:
            if a <= pos < b:
                return mn
        return "?"

    # ① 找 localparam 组：一个声明里多个 `NAME = value`
    groups = []
    for m in re.finditer(r"localparam\s*(?:\[[^\]]*\]\s*)?((?:\w+\s*=\s*[^,;]+[,;]\s*)+)", code):
        body = m.group(1)
        pairs = re.findall(r"(\w+)\s*=\s*([^,;]+)", body)
        enc = {}
        for name, val in pairs:
            v = parse_val(val)
            if v is not None:
                enc[name] = v
        if len(enc) >= 2:
            groups.append(enc)

    if not groups:
        return out

    # ② 找状态寄存器：`reg [w-1:0] <name>;` 且 <name> 出现在 case(...) 里
    for m in re.finditer(r"\breg\s*(\[[^\]]*\])?\s*([\w,\s]+);", code):
        for name in [x.strip() for x in m.group(2).split(",") if x.strip()]:
            if not re.search(r"case\s*\(\s*" + re.escape(name) + r"\s*\)", code):
                continue
            # 这个寄存器的 case 分支里用了哪些状态名 → 归到哪个编码组
            body = code[code.index("case (" + name):]
            body = body[:body.find("endcase")] if "endcase" in body else body
            names = set(re.findall(r"\b([A-Z][A-Z0-9_]{2,})\s*:", body))
            best, score = None, 0
            for g in groups:
                s = len(names & set(g))
                if s > score:
                    best, score = g, s
            if best and score >= 2:
                bits = m.group(1)
                w = 0
                if bits:
                    mm = re.search(r"\[\s*(\d+)\s*:", bits)
                    if mm:
                        w = int(mm.group(1)) + 1
                out.append((name, dict(best), w, owner(m.start())))
    return out


def load_observed():
    """按**模块名**聚合运行时观测：{模块名: set(见过的值)}（限状态寄存器名同名者）

    做法（每个 TB 独立处理，避免同名实例串味）：
      ① 报告文件名 = TB 名（`--keep` 产物 <tb>.cov.txt）
      ② 用该 TB 的源文件 + rtl/*.v 建 `实例名 -> 模块名` 映射
      ③ 对报告里每条信号路径，**从父级往上**找第一个能解析出的实例名，
         该实例的模块名即"这条信号属于哪个模块的哪一层"
      ④ 只有当路径最后一段是状态寄存器名（st/state/…）时才计入
    """
    global diag, mods_present, DATA_RAN, inst_all
    diag = []
    obs = defaultdict(set)
    mods_present = set()
    DATA_RAN = False
    inst_all = set()
    n_reports = 0

    reps = glob.glob(os.path.join(COVWORK, "*.cov.txt"))
    if not reps:
        reps = glob.glob(os.path.join(COVWORK, "covmon_report.txt"))

    for r in reps:
        n_reports += 1
        txt = open(r, encoding="utf-8", errors="replace").read()
        # ⚠ **从报告头读 TOP**（`# TOP: xxx`），不要靠文件名 ——
        #   单文件 covmon_report.txt 本身不带 TB 名，靠文件名会解析失败
        #   （这就是之前 `TB=?` 诊断的来源）。
        tm = re.search(r"^# TOP:\s*(.+)$", txt, re.M)
        tops = tm.group(1).split() if tm else []
        files = glob.glob(os.path.join(RTL, "*.v"))
        for t in tops:
            tbf = os.path.join(SIM, t + ".v")
            if os.path.exists(tbf):
                files = [tbf] + files
            bf = os.path.join(ROOT, "board", t + ".v")
            if os.path.exists(bf):
                files = [bf] + files
        imap = build_inst_map(files)
        # 该 TB 实例化到的**全部**模块（含无可观测信号的深层模块）
        inst_all |= instantiated_modules(tops, files)
        for line in txt.split("\n"):
            m = re.match(r"\s+(\S+)\s+宽\s*(\d+)\s+见过\s*\d+\s*种.*?:\s*(.*)$", line)
            if not m:
                continue
            path, vals = m.group(1), m.group(3)
            comps = path.split(".")
            reg = comps[-1]
            # ⚠ 记录"这个路径属于哪个模块"（不管它是不是状态寄存器），
            #   用于区分「模块未被实例化」与「实例化了但状态不可观测」
            for up in range(2, len(comps) + 1):
                if comps[-up] in imap:
                    mods_present.add(imap[comps[-up]])
                    break
            if reg not in STATE_REG_NAMES:
                continue
            # 从父级往上找第一个可解析的实例名
            owner = None
            for up in range(2, len(comps) + 1):
                if comps[-up] in imap:
                    owner = imap[comps[-up]]
                    break
            if owner is None:
                diag.append(f"  [diag] 无法解析 {path}（TOP={'/'.join(tops) or '?'}）")
                continue
            mods_present.add(owner)
            for tok in vals.split():
                if tok.startswith("..."):
                    break
                if tok.isdigit():
                    obs[owner].add(int(tok))
    # ⚠ 空 dict 有歧义（"没采集" vs "采集了但没状态寄存器"），必须用显式标志区分
    DATA_RAN = n_reports > 0
    return obs


def main():
    ap = argparse.ArgumentParser(description="状态机可达性覆盖")
    ap.add_argument("--no-data", action="store_true", help="只做静态提取")
    args = ap.parse_args()

    obs = {} if args.no_data else load_observed()
    inst_seen = set(inst_all) if not args.no_data else set()

    print("=" * 78)
    print("  状态机可达性覆盖")
    print("=" * 78)
    if not obs and not args.no_data:
        print("  ⚠ 没找到覆盖率数据。先跑 `python3 sim/cov_run.py --keep`")
        print()

    total_fsm = total_state = total_miss = 0
    # 区分三种"没数据"的情形，它们的含义完全不同：
    #   ① no_data      ：--no-data 跑法，只做静态提取
    #   ② not_instant  ：本次运行**根本没实例化**该模块（该 TB 不测它）
    #   ③ no_visible   ：实例化了，但**状态寄存器在更深的层次里、报告里看不到**
    #                    （例：tb_fx_top 的 DUT 是 fx_top，三个效果器 fsm 在它内部）
    not_inst, no_visible = [], []

    for f in sorted(glob.glob(os.path.join(RTL, "*.v"))):
        fsms = extract_fsms(f)
        if not fsms:
            continue
        name = os.path.basename(f)
        for reg, enc, w, mod in fsms:
            items = sorted(set(enc.items()), key=lambda kv: kv[1])
            if not items:
                continue

            if not DATA_RAN:
                seen, mode = None, "no_data"
            elif mod in obs:
                seen, mode = obs[mod], "ok"
            elif mod in inst_all or mod in inst_seen:
                seen, mode = set(), "no_visible"
                no_visible.append(mod)
            else:
                not_inst.append(mod)
                continue

            total_fsm += 1
            print(f"\n  {name}  模块 `{mod}` 的状态寄存器 `{reg}`（宽 {w}）")
            for sname, sval in items:
                if mode == "no_data":
                    print(f"      {sname:22s} = {sval:2d}   （无运行时数据）")
                    continue
                if mode == "no_visible":
                    print(f"      {sname:22s} = {sval:2d}   （本 TB 中状态不可观测）")
                    continue
                total_state += 1
                if sval in seen:
                    print(f"      {sname:22s} = {sval:2d}   ✓ 已到达")
                else:
                    total_miss += 1
                    print(f"      {sname:22s} = {sval:2d}   ✗ **从未到达**")

    if diag:
        print()
        print("  诊断（路径无法解析，可能是 TB 未纳入扫描）:")
        for d in diag[:8]:
            print("  " + d)

    print()
    print("-" * 78)
    if not_inst:
        print(f"  未实例化（本次运行不测它）：{sorted(set(not_inst))}")
    if no_visible:
        print(f"  状态不可观测（在更深层次，报告里看不到 `st`）：{sorted(set(no_visible))}")
    print(f"  共 {total_fsm} 个状态机、{total_state} 个状态；**从未到达 {total_miss} 个**")
    if total_miss == 0 and obs:
        print("  ✅ 所有状态机的所有状态都被测试覆盖到了")
    elif total_miss:
        print("  ⚠ 未到达的状态要么是死代码，要么是测试没构造出进入它的激励 —— 需人工判断")
    return 0


if __name__ == "__main__":
    sys.exit(main())
