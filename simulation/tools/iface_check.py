#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
iface_check.py —— 单声部层 `voice_mono` 接口合规检查（sakiko）

**为什么需要**：`voice_mono` 的接口是**冻结契约**（`硬件实现.md` §8.5.1/§8.5.3）。
别人写的实现到货后，如果端口名/位宽与契约定不一致，集成时会出
「按名字连不上」或「位宽静默截断」——后者更危险（不报错、只是声音不对）。

所以把契约固化成表，自动比对：
  ① 端口**名字**是否齐（缺 / 多）
  ② 端口**方向**是否对
  ③ 端口**位宽**是否一致（不一致就报，尤其是"比契约窄"＝静默截断）
  ④ 顺带跑关键字冲突检查（撞 `program` 这类关键字）

用法：
    python3 iface_check.py --rtl ../rtl                       # 目录里找 voice_mono.v
    python3 iface_check.py --file /path/to/voice_mono.v
    python3 iface_check.py --file x.v --top voice_mono
"""

import argparse
import glob
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# ============================================================================
#  冻结契约（`硬件实现.md` §8.5.1（2)(3)(4) + §8.5.3）
#  每项：(名字, 方向, 位宽表达式, 说明)
#    位宽写字符串，检查时按"归一化"比较（容忍 `[23:0]` / `[0:23]` 写法差异）
# ============================================================================
SPEC = {
    "voice_mono": {
        "desc": "单声部处理层（每个声部一份，顶层例化 P 份）",
        "ports": [
            # ---- 时钟 / 复位 / 节拍 ----
            ("clk",             "input",  "1",  "系统时钟"),
            ("rst_async_n",     "input",  "1",  "异步复位（低有效）"),
            ("sample_en",       "input",  "1",  "**时隙节拍**（= voice_slot_seq 的 slot_vld，不是帧节拍）"),
            # ---- DDS ----
            ("phase_inc",       "input",  "32", "频率控制字（已含 bend_ratio 调制）"),
            ("wave_sel",        "input",  "2",  "波表索引（当前只用 [0]）"),
            ("timbre_slot",     "input",  "3",  "音色槽 0~7"),
            # ---- SVF ----
            ("f_coeff",         "input",  "16", "SVF 频率系数（Q1.15，存 sin 不存 2sin）"),
            ("q_coeff",         "input",  "16", "SVF 阻尼系数（Q1.15）"),
            ("filter_type",     "input",  "2",  "0=LP 1=BP 2=HP"),
            # ---- ADSR / VCA ----
            ("gate",            "input",  "1",  "按键"),
            ("sustain_pedal",   "input",  "1",  "延音踏板（CC64）"),
            ("attack_step",     "input",  "16", "ADSR 步进（Q 口径见技术文档 §五.1.6）"),
            ("decay_step",      "input",  "16", ""),
            ("sustain_level",   "input",  "16", "Q1.15，满量程 32767"),
            ("release_step",    "input",  "16", ""),
            ("velocity_gain",   "input",  "16", "力度增益（Q1.15）"),
            ("vca_gain",        "input",  "16", "音色总增益（Q1.15）"),
            # ---- 输出 ----
            ("voice_out",       "output", "24", "24 位有符号（Q1.23）＝ 通道层的 `aud_in`"),
            # ---- 状态写回（用于回写声部状态表，139 bit/声部）----
            ("phase_acc",       "output", "32", "DDS 相位累加器（运行时不清零）"),
            ("env_value",       "output", "16", "Q1.15，满量程 32767"),
            ("env_state",       "output", "3",  "IDLE/ATTACK/DECAY/SUSTAIN/PENDING_RELEASE/RELEASE"),
            ("filter_ic1",      "output", "32", "SVF 积分器 1"),
            ("filter_ic2",      "output", "32", "SVF 积分器 2"),
            ("lfo_phase",       "output", "24", "**预留**（LFO 暂缓，位宽保留）"),
        ],
        #  契约里明确写了「不经过 voice_mono」，若出现这些端口要提醒
        "forbidden": [
            ("ch_in", "§8.5.3 明确：`ch_in` 由声部取数器**直接旁路**给通道层，不经本模块"),
            ("vld",   "§8.5.3 明确：`vld` 由声部取数器**直接旁路**给通道层，不经本模块"),
        ],
    },
}


def parse_ports(path):
    """解析模块端口。返回 (module_name, {name: (dir, width_str)}, [(name, raw_line)])"""
    src = open(path, encoding="utf-8", errors="replace").read()
    # 去注释
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    src = re.sub(r"//[^\n]*", " ", src)
    m = re.search(r"\bmodule\s+([A-Za-z_]\w*)", src)
    if not m:
        return None, {}, []
    name = m.group(1)
    # 取 module ... ); 之间的端口列表（用括号配对，容忍 ANSCI 与非 ANSI）
    i = src.index("module")
    depth = 0
    started = False
    buf = []
    for ch in src[i:]:
        if ch == "(":
            depth += 1
            started = True
            continue
        if ch == ")":
            depth -= 1
            if started and depth == 0:
                break
            continue
        if started:
            buf.append(ch)
    body = "".join(buf)

    ports = {}
    order = []
    # 逐段切：以 input/output/inout 开头
    chunks = re.split(r"\b(?=input\b|output\b|inout\b)", body)
    for c in chunks:
        dm = re.match(r"\s*(input|output|inout)\b", c)
        if not dm:
            continue
        d = {"input": "input", "output": "output", "inout": "inout"}[dm.group(1)]
        # 位宽
        wm = re.search(r"\[([^\]]+)\]", c)
        width = wm.group(1).strip() if wm else "1"
        # 该段里所有标识符（去掉关键字/位宽/参数列表）
        rest = c[dm.end():]
        rest = re.sub(r"\[[^\]]*\]", " ", rest)
        rest = re.sub(r"\b(wire|reg|signed|unsigned|logic|bit|integer)\b", " ", rest)
        rest = re.sub(r"=[^,;]*", " ", rest)          # 去掉默认值（ANSI）
        for nm in re.findall(r"[A-Za-z_]\w*", rest):
            if nm in ("input", "output", "inout", "wire", "reg", "signed", "unsigned"):
                continue
            if nm not in ports:
                ports[nm] = (d, width)
                order.append((nm, c.strip()[:60]))
    return name, ports, order


def norm_width(w):
    """位宽归一化：`[23:0]` 与 `24` 等价，便于比较"""
    w = w.strip()
    if w in ("", "1"):
        return 1
    #  ⚠ 顺序很重要：**先试区间**（`[15:0]`），再试纯数字。
    #    早先 `w.isdigit()` 写在前面对 `[15:0]` 不成立、又因为顺序问题导致
    #    归一化失败 → 合规的桩被误报一片"无法静态核对"（踩过）。
    #  ⚠ 方括号可能被调用方剥掉（本文件的 parse_ports 就剥了），
    #    所以 `[15:0]` 与 `15:0` **两种都要认**（踩过：只认带括号的 → 合规也被误报）
    m = re.fullmatch(r"\[?\s*(\d+)\s*:\s*(\d+)\s*\]?", w)
    if m:
        a, b = int(m.group(1)), int(m.group(2))
        return abs(a - b) + 1
    if re.fullmatch(r"\d+", w):
        return int(w)
    return None   # 参数化位宽（如 `P*24-1:0`）→ 无法静态判定


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default=None)
    ap.add_argument("--rtl", default=None, help="RTL 目录（自动找 <top>.v）")
    ap.add_argument("--top", default="voice_mono")
    args = ap.parse_args()

    path = args.file
    if not path and args.rtl:
        cand = glob.glob(os.path.join(args.rtl, "**", f"{args.top}.v"), recursive=True)
        if not cand:
            print(f"❌ 在 {args.rtl} 里找不到 {args.top}.v")
            return 1
        path = cand[0]
    if not path:
        print("❌ 请给 --file 或 --rtl")
        return 1

    print("=" * 76)
    print(f"  单声部层接口合规检查 · {path}")
    print("=" * 76)

    if args.top not in SPEC:
        print(f"  ⚠ 没有 `{args.top}` 的契约表，无法检查")
        return 1
    spec = SPEC[args.top]
    print(f"  契约来源：`硬件实现.md` §8.5.1 / §8.5.3 —— {spec['desc']}")

    name, ports, order = parse_ports(path)
    if not name:
        print("  ❌ 解析不到 module 声明")
        return 1
    print(f"  实际模块名：`{name}`")
    if name != args.top:
        print(f"  ⚠ 模块名与契约名（`{args.top}`）不同 —— 例化时按实际名字写")

    want = {p[0]: p for p in spec["ports"]}
    got = ports
    errs, warns = [], []

    # ① 缺失
    missing = [n for n in want if n not in got]
    for n in missing:
        errs.append(f"缺端口 `{n}`（契约要求 {want[n][1]} {want[n][2]} 位：{want[n][3]}）")

    # ② 多余
    extra = [n for n in got if n not in want]
    for n in extra:
        warns.append(f"多端口 `{n}`（{got[n][0]} {got[n][1]}）—— 契约里没有，确认是否必要")

    # ③ 方向 + 位宽
    for n in want:
        if n not in got:
            continue
        wd, ww, wdesc = want[n][1], want[n][2], want[n][3]
        gd, gw = got[n]
        if wd != gd:
            errs.append(f"`{n}` 方向错：契约 {wd}，实际 {gd}")
        wn, gn = norm_width(ww), norm_width(gw)
        if wn is not None and gn is not None and wn != gn:
            sev = "窄（**会静默截断**）" if gn < wn else "宽"
            errs.append(f"`{n}` 位宽不符：契约 {wn} 位，实际 {gn} 位 → {sev}")
        elif gn is None:
            warns.append(f"`{n}` 位宽是参数化表达式（`{gw}`），**无法静态核对**，请人工确认 = {ww}")

    # ④ 契约里明确不应有的端口
    for fn, why in spec.get("forbidden", []):
        if fn in got:
            errs.append(f"不该有端口 `{fn}` —— {why}")

    # ⑤ 关键字检查
    kws = os.path.join(HERE, "kw_check.py")
    if os.path.isfile(kws):
        r = subprocess.run([sys.executable, kws, "--files", path],
                           capture_output=True, text=True)
        if r.returncode != 0:
            errs.append("存在 Verilog 关键字冲突（见下）")
            print()
            print(r.stdout.rstrip())

    # ---- 报告 ----
    print()
    print(f"  契约端口 {len(want)} 个，实际端口 {len(got)} 个")
    print()
    if errs:
        print("  ❌ 不合规：")
        for e in errs:
            print(f"      · {e}")
    if warns:
        print("  ⚠ 需人工确认：")
        for w in warns:
            print(f"      · {w}")
    print()
    print("-" * 76)
    if not errs:
        print("  ✅ 接口合规 —— 可直接与 `full_top`（VOICE_SRC=1）对接")
    else:
        print(f"  ❌ {len(errs)} 项不合规，**先改再集成**")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
