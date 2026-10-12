#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
midi_serial.py —— 串口 MIDI 发送工具（本项目的上板实测用）

为什么需要它
------------
本项目的 FPGA 有 **4 路标准 MIDI UART 输入**（`full_system.midi_rx[3:0]`，
31250 baud、8N1）。上板调试时需要一个能发 MIDI 的 PC 端工具：
音阶自检、单音长按测群延迟、CC 扫频看滤波、SysEx 改效果参数……

本脚本就是这个工具，**不依赖外部安装**（pyserial 已自带在同目录 `lib/`）。

协议（与本项目文档逐位对齐）
--------------------------
`documents/MIDI协议.md` §二：
  · 波特率 **31250**，每字节 **10 位** = 起始 0 + 数据 8 + 停止 1
  · 状态字节：`8n`=Note Off、`9n`=Note On、`Bn`=CC、`Cn`=PC、`En`=Pitch Bend
    （`n` = 0–F，对应 MIDI 通道 1–16）
  · **力度 0 的 Note On 等价于 Note Off**
  · Pitch Bend 是 14 位：`值 = MSB×128 + LSB`，中心 8192
`documents/硬件实现.md` §三.二.5：
  · 效果参数 SysEx：`F0 7D <slot> <param> <val_hi> <val_lo> F7`
  · 主音量 SysEx（GM2）：`F0 7F <dev> 04 01 ll mm F7`

用法
----
    # 先看会发什么（不连硬件也能用）
    python3 midi_serial.py --dry-run note 60 100
    python3 midi_serial.py --dry-run scale 60 72

    # 连板子：Linux 是 /dev/ttyUSB0，Windows 是 COM3
    python3 midi_serial.py --port /dev/ttyUSB0 note 60 100
    python3 midi_serial.py --port COM3 scale 48 72 --step 0.3

    # 直接发十六进制（最通用，任何消息都能发）
    python3 midi_serial.py --port /dev/ttyUSB0 raw "90 3C 64" "80 3C 40"
    python3 midi_serial.py --port /dev/ttyUSB0 raw --file 测试序列.txt

    # 交互模式（演奏/试参数）
    python3 midi_serial.py --port /dev/ttyUSB0 interactive

子命令一览：`note` `cc` `pc` `bend` `sysex` `raw` `scale` `chord` `panic` `interactive`

⚠ 上板注意
----------
· 电平：FPGA 的 MIDI 输入脚是 3.3V，USB-TTL 串口模块**必须 3.3V 电平**，
  不能用 RS-232 电平（±12V）直连，会打坏 IO。
· 若用标准 MIDI DIN 接口，需要 31250 baud 的 MIDI 转接；本脚本默认
  `--byte-gap 0`（全速连续发），对 FPGA 直连 UART 可行。若中间经过光耦/长线，
  加 `--byte-gap 320`（微秒）按标准 MIDI 节拍发。
"""

import argparse
import os
import sys
import time

#  ⚠ Windows 上默认 stdout 是 GBK，打印非 ASCII 会抛 UnicodeEncodeError
#     （本项目在 kw_check.py 上踩过一次）。统一兜底。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "lib"))     # 自带 pyserial

try:
    import serial
    HAS_SERIAL = True
except ImportError:
    HAS_SERIAL = False


# ============================================================================
#  MIDI 消息构造（纯字节，不含任何 I/O —— 便于单独测试）
# ============================================================================

def _ch(ch):
    """MIDI 通道 1–16 → 状态字节低 4 位 0–15"""
    if not 1 <= ch <= 16:
        raise ValueError(f"MIDI 通道必须是 1–16，给了 {ch}")
    return ch - 1


def _d7(v, what="数据字节"):
    """校验 7 位数据（0–127）"""
    if not 0 <= v <= 127:
        raise ValueError(f"{what} 必须是 0–127，给了 {v}")
    return v


def note_on(ch, note, vel=100):
    return [0x90 | _ch(ch), _d7(note, "音符号"), _d7(vel, "力度")]


def note_off(ch, note, vel=64):
    return [0x80 | _ch(ch), _d7(note, "音符号"), _d7(vel, "释放力度")]


def cc(ch, num, val):
    return [0xB0 | _ch(ch), _d7(num, "控制器号"), _d7(val, "控制器值")]


def program_change(ch, prog):
    return [0xC0 | _ch(ch), _d7(prog, "音色号")]


def pitch_bend(ch, value):
    """14 位弯音。

    语义按**本项目惯例**：与文档一致，给 **0–16383，中心 8192**
    （同 `硬件实现.md` 的 `bend_value`；pan 的 0–127/64 也是这个风格）。
    另外接受 **-8192..-1** 当作"向下弯"自动加偏置，方便手写。

    ⚠ 早先写成"只在负数时加偏置"，导致 **`0` 有歧义**：本意是"向下弯到底"，
      却得到"不弯"（0 就是原始最小值）。现在明确：**`0` = 向下弯到底，
      中心必须写 `8192`**（或用负数形式）。

    返回 `[状态, LSB, MSB]`（14 位 = MSB×128 + LSB）。
    """
    if -8192 <= value < 0:
        value += 8192                       # 方便：负数 = 向下弯
    if not 0 <= value <= 16383:
        raise ValueError(f"弯音值必须是 0–16383（中心 8192），或 -8192..-1；给了 {value}")
    return [0xE0 | _ch(ch), value & 0x7F, (value >> 7) & 0x7F]


def sysex(payload):
    """通用 SysEx：自动补 F0/F7。

    payload 里可以有 `0xF0`/`0xF7` 也可以没有，两种写法都接受。
    """
    p = list(payload)
    if p and p[0] == 0xF0:
        p = p[1:]
    if p and p[-1] == 0xF7:
        p = p[:-1]
    for b in p:
        if not 0 <= b <= 127:
            raise ValueError(f"SysEx 载荷必须是 0–127（7 位），给了 {b}")
    return [0xF0] + p + [0xF7]


def sysex_effect(slot, param, value):
    """效果参数（`硬件实现.md` §三.二.5）：`F0 7D <slot> <param> <val_hi> <val_lo> F7`

    `value` 是 14 位（0–16383），先高 7 位后低 7 位。
    """
    if not 0 <= slot <= 127:
        raise ValueError("slot 必须 0–127")
    if not 0 <= param <= 127:
        raise ValueError("param 必须 0–127")
    if not 0 <= value <= 16383:
        raise ValueError("value 必须 0–16383（14 位）")
    return sysex([0x7D, slot, param, (value >> 7) & 0x7F, value & 0x7F])


def sysex_master_volume(value14, dev=0):
    """GM2 主音量：`F0 7F <dev> 04 01 ll mm F7`（→ 主输出组 3、号 0）"""
    if not 0 <= value14 <= 16383:
        raise ValueError("主音量必须 0–16383")
    return sysex([0x7F, dev & 0x7F, 0x04, 0x01, value14 & 0x7F, (value14 >> 7) & 0x7F])


def gm_reset():
    """GM System On（复位到 GM 默认）"""
    return sysex([0x7E, 0x7F, 0x09, 0x01])


def panic_msgs(ch=None):
    """让所有音停：CC123（All Notes Off）+ CC120（All Sound Off）"""
    out = []
    chans = [ch] if ch else list(range(1, 17))
    for c in chans:
        out.append(cc(c, 123, 0))
        out.append(cc(c, 120, 0))
    return out


# ============================================================================
#  输出端口（串口 / 干跑 / 文件）
# ============================================================================
class MidiOut:
    """MIDI 字节输出。

    `dry_run=True` 或串口不可用时只**打印**，不真发 —— 这样没有硬件也能验证
    "会发哪些字节"（本项目的调试习惯：先验逻辑，再上硬件）。
    """

    def __init__(self, port=None, baud=31250, dry_run=False,
                 byte_gap_us=0, verbose=True):
        self.port_name = port
        self.baud = baud
        self.dry_run = dry_run or (port is None)
        self.byte_gap = byte_gap_us / 1e6
        self.verbose = verbose
        self.ser = None
        self.n_bytes = 0

        if not self.dry_run:
            if not HAS_SERIAL:
                raise RuntimeError(
                    "找不到 pyserial。本目录 `lib/` 应自带，请确认没被删；"
                    "或改用 `--dry-run` 先看字节。")
            #  ⚠ 标准 MIDI：8 数据位 / 无校验 / 1 停止位（8N1）
            #     `write_timeout` 必须有，否则某些 USB 转串口会永久阻塞
            try:
                self.ser = serial.Serial(port=port, baudrate=baud,
                                         bytesize=serial.EIGHTBITS,
                                         parity=serial.PARITY_NONE,
                                         stopbits=serial.STOPBITS_ONE,
                                         timeout=0.1, write_timeout=1.0)
            except Exception as e:      # termios.error / ValueError / OSError 都算
                #  ⚠ **优雅降级**：某些"串口"不能设波特率 ——
                #     典型是伪终端（PTY，`/dev/pts/N`）：`os.openpty()` 出来的设备
                #     不支持 `termios` 的波特率设置。
                #     ⚠⚠ `termios.error` **既不继承 `OSError` 也不继承 `ValueError`**
                #        （实测确认），所以这里必须 `except Exception`，
                #        否则降级分支永远进不去（我第一次就是这么写错的）。
                #     真串口不受影响：波特率是真设下去的，不会走这里。
                #     降级只为了让**没有硬件时能用 PTY 做回环自测**。
                if not os.path.exists(port):
                    raise
                self.ser = serial.Serial(port=port, timeout=0.1, write_timeout=1.0)
                if self.verbose:
                    print(f"  ⚠ {port} 不接受波特率设置（可能是伪终端），按默认参数打开")
            if self.verbose and self.ser:
                print(f"  已打开 {port} @ {baud} baud (8N1)")

    # ---- 发一条消息（字节列表）----
    def send(self, data, label=""):
        data = list(data)
        if not data:
            return
        head = " ".join(f"{b:02X}" for b in data)
        if self.verbose:
            print(f"  → {head}" + (f"    {label}" if label else ""))
        if self.dry_run:
            self.n_bytes += len(data)
            return
        for b in data:
            self.ser.write(bytes([b]))
            if self.byte_gap > 0:
                time.sleep(self.byte_gap)
        self.n_bytes += len(data)

    def send_many(self, msgs, gap_s=0.0):
        for m in msgs:
            self.send(m)
            if gap_s > 0:
                time.sleep(gap_s)

    def close(self):
        if self.ser:
            try:
                self.ser.close()
            except Exception:
                pass


# ============================================================================
#  内建测试序列（上板自检常用）
# ============================================================================

def seq_scale(ch, lo, hi, vel, step, hold):
    """半音音阶上行 + 下行（最常用的"能不能发声"自检）"""
    out = []
    notes = list(range(lo, hi + 1))
    for n in notes:
        out.append((note_on(ch, n, vel), step))
        out.append((note_off(ch, n), hold))
    for n in reversed(notes):
        out.append((note_on(ch, n, vel), step))
        out.append((note_off(ch, n), hold))
    return out


def seq_chord(ch, root, kind, vel):
    """和弦：按同时发声（一次发多个 Note On）"""
    INTERVALS = {
        "maj": [0, 4, 7], "min": [0, 3, 7], "dim": [0, 3, 6],
        "aug": [0, 4, 8], "sus4": [0, 5, 7], "maj7": [0, 4, 7, 11],
        "min7": [0, 3, 7, 10], "dom7": [0, 4, 7, 10], "pow": [0, 7],
    }
    if kind not in INTERVALS:
        raise ValueError(f"和弦类型只支持 {list(INTERVALS)}")
    on = [note_on(ch, root + i, vel) for i in INTERVALS[kind]]
    off = [note_off(ch, root + i) for i in INTERVALS[kind]]
    return on + off


# ============================================================================
#  命令行
# ============================================================================
def build_parser():
    p = argparse.ArgumentParser(
        prog="midi_serial.py",
        description="串口 MIDI 发送工具（本项目上板实测用）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""示例：
  python3 midi_serial.py --dry-run note 60 100          看会发什么字节
  python3 midi_serial.py -p /dev/ttyUSB0 scale 60 72    上板：音阶自检
  python3 midi_serial.py -p COM3 raw "90 3C 64"         直接发十六进制
  python3 midi_serial.py -p /dev/ttyUSB0 interactive    交互模式
""")
    p.add_argument("-p", "--port", help="串口设备，如 /dev/ttyUSB0 或 COM3")
    p.add_argument("-b", "--baud", type=int, default=31250,
                   help="波特率（标准 MIDI = 31250，默认）")
    p.add_argument("--dry-run", action="store_true",
                   help="只打印将要发送的字节，不打开串口")
    p.add_argument("--byte-gap", type=int, default=0, metavar="US",
                   help="字节间隔微秒（0 = 全速连续发；标准 MIDI 用 320）")
    p.add_argument("-q", "--quiet", action="store_true", help="不打印每条消息")
    p.add_argument("--ch", type=int, default=1, help="MIDI 通道 1–16（默认 1）")

    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("note", help="发 Note On（可选按指定时长后自动 Note Off）")
    s.add_argument("note", type=int, help="音符号 0–127（60 = 中央 C）")
    s.add_argument("vel", nargs="?", type=int, default=100, help="力度 0–127")
    s.add_argument("--hold", type=float, default=0.0, metavar="秒",
                   help=">0 时：按下后等这么久再自动发 Note Off（测群延迟/包络用）")
    s.add_argument("--off-only", action="store_true", help="只发 Note Off")

    s = sub.add_parser("cc", help="发 Control Change")
    s.add_argument("num", type=int, help="控制器号 0–127（7=音量 10=声像 91=混响发送）")
    s.add_argument("val", type=int, help="值 0–127")

    s = sub.add_parser("pc", help="发 Program Change（切音色）")
    s.add_argument("prog", type=int, help="音色号 0–127")

    s = sub.add_parser("bend", help="发 Pitch Bend（14 位，中心 8192）")
    s.add_argument("value", type=int,
                   help="0–16383（**中心 8192**）；或负数 -8192..-1 表示向下弯")

    s = sub.add_parser("sysex", help="发 SysEx")
    s.add_argument("kind", choices=["effect", "volume", "gm-reset", "raw"],
                   help="effect=F0 7D…；volume=GM2 主音量；gm-reset=GM System On；raw=手填")
    s.add_argument("vals", nargs="*", type=lambda x: int(x, 0),
                   help="effect: slot param value14 ｜ volume: value14 ｜ raw: 一串 0–127")

    s = sub.add_parser("raw", help="直接发十六进制字节（最通用）")
    s.add_argument("hex", nargs="*", help='如 "90 3C 64"；可给多条')
    s.add_argument("--file", help="从文件读（每行一条，支持 # 注释）")
    s.add_argument("--gap", type=float, default=0.2, metavar="秒",
                   help="多条之间间隔（默认 0.2）")

    s = sub.add_parser("scale", help="音阶自检（上行+下行）")
    s.add_argument("lo", type=int, help="起始音符号")
    s.add_argument("hi", type=int, help="结束音符号")
    s.add_argument("--vel", type=int, default=100)
    s.add_argument("--step", type=float, default=0.25, metavar="秒", help="每个音间隔")
    s.add_argument("--hold", type=float, default=0.15, metavar="秒", help="音内保持")

    s = sub.add_parser("chord", help="发一个和弦")
    s.add_argument("root", type=int, help="根音音符号")
    s.add_argument("kind", nargs="?", default="maj",
                   choices=["maj", "min", "dim", "aug", "sus4", "maj7", "min7", "dom7", "pow"])
    s.add_argument("--vel", type=int, default=100)
    s.add_argument("--hold", type=float, default=1.0, metavar="秒")

    sub.add_parser("panic", help="全通道 All Notes Off + All Sound Off")

    sub.add_parser("interactive", help="交互模式（输入十六进制或命令）")
    return p


def parse_hex_line(line):
    """把 `90 3C 64` 或 `0x90,0x3C,0x64` 解析成字节列表"""
    line = line.split("#")[0].strip()
    if not line:
        return []
    line = line.replace(",", " ").replace("0x", " ").replace("0X", " ")
    out = []
    for tok in line.split():
        try:
            v = int(tok, 16)
        except ValueError:
            raise ValueError(f"不是合法十六进制：{tok!r}")
        if not 0 <= v <= 255:
            raise ValueError(f"字节超范围：{tok}")
        out.append(v)
    return out


def cmd_raw(mo, args):
    lines = []
    if args.file:
        with open(args.file, encoding="utf-8") as f:
            lines = [l for l in f]
    lines += list(args.hex)
    n = 0
    for l in lines:
        data = parse_hex_line(l)
        if data:
            mo.send(data, f"({l.split('#')[0].strip()})")
            n += 1
            if n < len(lines) and args.gap > 0:
                time.sleep(args.gap)
    if n == 0:
        print("  ⚠ 没有可发的字节")


def cmd_interactive(mo, args):
    """交互模式：直接敲十六进制，或敲 `n 60 100` 这类简写"""
    print("  交互模式。输入：")
    print("    90 3C 64            直接发十六进制")
    print("    n 60 100 / f 60      Note On / Note Off")
    print("    c 7 100              CC#7 = 100")
    print("    q                    退出")
    while True:
        try:
            line = input("  midi> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not line or line.startswith("#"):
            continue
        if line in ("q", "quit", "exit"):
            break
        try:
            low = line.lower()
            if low[0] == "n" and " " in line:
                _, n, v = line.split()
                mo.send(note_on(args.ch, int(n), int(v)))
            elif low[0] == "f" and " " in line:
                _, n = line.split()
                mo.send(note_off(args.ch, int(n)))
            elif low[0] == "c" and " " in line:
                _, num, val = line.split()
                mo.send(cc(args.ch, int(num), int(val)))
            else:
                mo.send(parse_hex_line(line))
        except Exception as e:
            print(f"  ✗ {e}")
    print("  退出。")


def main():
    args = build_parser().parse_args()
    if not HAS_SERIAL and not args.dry_run and args.port:
        print("  ✗ 找不到 pyserial（本目录 lib/ 应自带）。用 --dry-run 可先看字节。")
        return 1

    try:
        mo = MidiOut(port=args.port, baud=args.baud, dry_run=args.dry_run,
                     byte_gap_us=args.byte_gap, verbose=not args.quiet)
    except Exception as e:
        print(f"  ✗ 打开串口失败：{e}")
        return 1

    if mo.dry_run and args.port:
        print(f"  [dry-run] 未打开 {args.port}")

    try:
        c = args.cmd
        if c == "note":
            if args.off_only:
                mo.send(note_off(args.ch, args.note), f"Note Off n={args.note}")
            else:
                mo.send(note_on(args.ch, args.note, args.vel),
                        f"Note On ch{args.ch} n={args.note} v={args.vel}"
                        f"  ({_note_name(args.note)})")
                if args.hold > 0:
                    time.sleep(args.hold)
                    mo.send(note_off(args.ch, args.note), "自动 Note Off")
        elif c == "cc":
            mo.send(cc(args.ch, args.num, args.val), f"CC#{args.num} = {args.val}")
        elif c == "pc":
            mo.send(program_change(args.ch, args.prog), f"PC = {args.prog}")
        elif c == "bend":
            mo.send(pitch_bend(args.ch, args.value), f"Bend = {args.value}")
        elif c == "sysex":
            if args.kind == "effect":
                if len(args.vals) != 3:
                    print("  ✗ effect 需要 3 个值：slot param value14"); return 1
                mo.send(sysex_effect(*args.vals), f"效果参数 slot={args.vals[0]} param={args.vals[1]} val={args.vals[2]}")
            elif args.kind == "volume":
                if len(args.vals) != 1:
                    print("  ✗ volume 需要 1 个值：value14"); return 1
                mo.send(sysex_master_volume(args.vals[0]), f"主音量 = {args.vals[0]}")
            elif args.kind == "gm-reset":
                mo.send(gm_reset(), "GM System On")
            else:
                mo.send(sysex(args.vals), "SysEx(raw)")
        elif c == "raw":
            cmd_raw(mo, args)
        elif c == "scale":
            if not 0 <= args.lo <= 127 or not 0 <= args.hi <= 127:
                print("  ✗ 音符号必须 0–127"); return 1
            if args.lo > args.hi:
                args.lo, args.hi = args.hi, args.lo
            print(f"  音阶 {_note_name(args.lo)} → {_note_name(args.hi)}"
                  f"（{args.hi - args.lo + 1} 个音，上行+下行）")
            for msg, gap in seq_scale(args.ch, args.lo, args.hi, args.vel,
                                      args.step, args.hold):
                mo.send(msg)
                time.sleep(gap)
        elif c == "chord":
            msgs = seq_chord(args.ch, args.root, args.kind, args.vel)
            for m in msgs[:len(msgs) // 2]:
                mo.send(m)
            time.sleep(args.hold)
            for m in msgs[len(msgs) // 2:]:
                mo.send(m)
        elif c == "panic":
            print("  全通道 All Notes Off + All Sound Off")
            mo.send_many(panic_msgs(), gap_s=0.01)
        elif c == "interactive":
            cmd_interactive(mo, args)
    finally:
        mo.close()

    if args.dry_run:
        print(f"  [dry-run] 共 {mo.n_bytes} 字节（未发送）")
    return 0


#  音名（只用于打印，便于对谱）
_NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def _note_name(n):
    if not 0 <= n <= 127:
        return "?"
    return f"{_NOTE_NAMES[n % 12]}{n // 12 - 1}"


if __name__ == "__main__":
    sys.exit(main())
