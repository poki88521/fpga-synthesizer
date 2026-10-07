#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
kw_check.py —— Verilog 关键字冲突检查（sakiko）

**为什么需要**：标识符撞上 Verilog/SystemVerilog 关键字，iverilog 往往**不报错**
（它只在特定上下文才当关键字），但 Gowin 综合器 / 别的仿真器可能直接拒。
本项目已确定踩到的一个：`program`（`midi_filter` 的 program change 相关命名）。

检查三类：
  ① 模块名 / 端口名 / 信号名 / 参数名 == 关键字
  ② 实例名 == 关键字
  ③ 常见「高危近义名」（`program` / `time` / `event` / `signal` / `buffer` /
     `state` / `edge` / `packed` … 的变体，如 `program_change`、`prog`）单独提示

用法：
    python3 kw_check.py                 # 扫本仓库 rtl/
    python3 kw_check.py --dir ../rtl    # 指定目录
    python3 kw_check.py --files a.v b.v
"""

import argparse
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
KW_FILE = os.path.join(HERE, "verilog_keywords.txt")

# 高危近义名：不一定是关键字，但在某些工具/版本里是，或极易被误用
RISKY_PATTERNS = [
    (r"\bprogram\b", "`program` 是 SV 关键字；用 `prog` / `program_num` / `pc_val` 代替"),
    (r"\bendprogram\b", "同上"),
    (r"\btime\b", "`time` 是关键字；用 `tstamp` / `cnt` 代替"),
    (r"\bevent\b", "`event` 是关键字；用 `evt` / `ev_*` 代替"),
    (r"\bsignal\b", "`signal` 在部分工具里保留；用 `sig` / `sgn` 代替"),
    (r"\bbuffer\b", "`buffer` 是关键字；用 `buf_mem` / `line_buf` 代替"),
    (r"\bstate\b(?!_)", "`state` 本身不是关键字，但 `state` 做信号名易与 `reg [1:0] state` 混淆；建议 `st` / `cur_st`"),
    (r"\bedge\b", "`edge` 是关键字片段；用 `eg` / `trig` 代替"),
    (r"\bpacked\b", "`packed` 是 SV 关键字；用 `pack` 代替"),
    (r"\blogic\b", "`logic` 是 SV 关键字；用 `lgc` / 具体位宽 `wire`/`reg` 代替"),
    (r"\bbit\b", "`bit` 是 SV 关键字；用 `b` / `bitv` 代替"),
    (r"\bvoid\b", "`void` 是 SV 关键字；用 `dummy` 代替"),
    (r"\bint\b", "`int` 是 SV 关键字；用 `integer` 或 `i` 代替"),
    (r"\bnew\b", "`new` 是 SV 关键字；用 `nxt` / `d_new` 代替"),
    (r"\bclass\b", "`class` 是 SV 关键字；用 `cls` 代替"),
    (r"\bpackage\b", "`package` 是 SV 关键字；用 `pkg` 代替"),
    (r"\bimport\b", "`import` 是 SV 关键字；用 `imp` 代替"),
    (r"\bwith\b", "`with` 是 SV 关键字；用 `wth` 代替"),
    (r"\bcover\b", "`cover` 是 SV 关键字；用 `cov` 代替"),
]

#  ⚠ 注意：`(?:wire|reg|integer|real|genvar)` 后面必须**至少有一个空白**再捕获名字，
#    否则 `integer i;` 会把关键字 `integer` 自身当成被声明的名字（踩过 → 误报 2 处）。
#    同时把类型修饰词（signed/automatic/static）都吃掉，避免漏检。
#  类型修饰词（必须先吃掉，否则 `input integer i;` 会把 `integer` 自身当名字 —— 踩过）
MODS = r"(?:(?:wire|reg|logic|integer|real|realtime|genvar|tri|signed|unsigned|automatic|static|bit|byte)\s+|\[[^\]]*\]\s+)*"
NAME = r"([A-Za-z_]\w*)"

#  forms:
#    module NAME            module automatic NAME
#    input/output/inout MODS NAME
#    wire/reg/integer/... MODS NAME
#    parameter/localparam [integer|signed] [range] NAME
DECL_FORMS = [
    (re.compile(r"^\s*(?:module|primitive|interface)\s+(?:automatic\s+|static\s+)?" + NAME), 1),
    (re.compile(r"^\s*(?:input|output|inout)\s+" + MODS + NAME), 1),
    (re.compile(r"^\s*(?:wire|reg|integer|real|realtime|genvar|tri)\s+" + MODS + NAME), 1),
    (re.compile(r"^\s*(?:parameter|localparam)\s+(?:(?:integer|signed|real)\s+)?(?:\[[^\]]*\]\s+)?" + NAME), 1),
]

def load_keywords():
    if not os.path.isfile(KW_FILE):
        return set()
    return {l.strip() for l in open(KW_FILE, encoding="utf-8") if l.strip()}


def strip_comments(src):
    """去掉注释，避免注释里的英文单词误报"""
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    src = re.sub(r"//[^\n]*", " ", src)
    return src


def check_file(path, kw):
    issues = []
    raw = open(path, encoding="utf-8", errors="replace").read()
    src = strip_comments(raw)
    for ln, line in enumerate(src.split("\n"), 1):
        name = None
        for rx, grp in DECL_FORMS:
            m = rx.match(line)
            if m:
                name = m.group(grp)
                break
        if name:
            if name.lower() in kw:
                issues.append((ln, "KEYWORD", name, line.strip()[:70]))
        for pat, why in RISKY_PATTERNS:
            for mm in re.finditer(pat, line):
                issues.append((ln, "RISKY", mm.group(0), why))
    return issues


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=None)
    ap.add_argument("--files", nargs="*", default=None)
    args = ap.parse_args()

    if args.files:
        files = args.files
    else:
        d = args.dir or os.path.join(os.path.dirname(os.path.dirname(HERE)), "rtl")
        files = sorted(glob.glob(os.path.join(d, "*.v")) + glob.glob(os.path.join(d, "**", "*.v"), recursive=True))
        files = sorted(set(files))

    kw = load_keywords()
    print("=" * 74)
    print(f"  Verilog 关键字冲突检查 · {len(files)} 个文件 · 关键字表 {len(kw)} 个")
    print("=" * 74)

    n_key = n_risky = 0
    for f in files:
        iss = check_file(f, kw)
        key = [i for i in iss if i[1] == "KEYWORD"]
        rsk = [i for i in iss if i[1] == "RISKY"]
        if not iss:
            continue
        print(f"\n  {os.path.basename(f)}")
        for ln, kind, name, extra in key:
            print(f"    ✗ L{ln}  [关键字] `{name}`")
            n_key += 1
        seen = set()
        for ln, kind, name, why in rsk:
            if name in seen:
                continue
            seen.add(name)
            print(f"    ⚠ L{ln}  [高危名] `{name}` —— {why}")
            n_risky += 1

    print()
    print("-" * 74)
    if n_key:
        print(f"  ❌ {n_key} 处**关键字冲突**（必须改）")
    if n_risky:
        print(f"  ⚠ {n_risky} 处高危名（建议改，不一定报错）")
    if not n_key and not n_risky:
        print("  ✅ 无关键字冲突、无高危名")
    return 1 if n_key else 0


if __name__ == "__main__":
    sys.exit(main())
