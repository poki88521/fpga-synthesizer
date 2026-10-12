#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
timbre_test.py —— 音色（Program Change）上板测试脚本

背景
    2026-10-09 之前，调度层 `voice_alloc` 的音色槽取的是 `note[2:0]`，
    导出 Program Change **完全无效**（换音色后声音不变，上板实测发现）。
    现已接入 `timbre_map`：`timbre_slot = program[2:0]`（恒等映射，8 槽）。

本脚本要测什么（按顺序）
    1. 8 个音色槽逐一试听 —— 是否都出声、彼此是否有区别
    2. 恒等映射验证       —— pc 8 应与 pc 0 相同，pc 15 应与 pc 7 相同
    3. "新音起效"语义     —— 换音色不影响正在发声的音（GM2 要求）
    4. Bank Select 缓存   —— 单独发 CC0 不应有任何变化
    5. 音高一致性         —— 换音色不应改变音高

用法
    python midi/timbre_test.py -p COM7
    python midi/timbre_test.py -p COM7 --ch 1 --note 60
    python midi/timbre_test.py -p COM7 --only 1        # 只跑第 1 项
    python midi/timbre_test.py -p COM7 --dry-run       # 只看会发什么字节

    ⚠ 音频输出要接好（喇叭/耳机），本脚本靠**人耳判断**，不是自动判定的。
"""

import argparse
import sys
import time
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import midi_serial as ms          # noqa: E402


# ---------------------------------------------------------------------------
def open_out(port, baud, dry, byte_gap):
    """兼容不同版本的 MidiOut 签名。"""
    for kwargs in (dict(port=port, baud=baud, dry_run=dry, byte_gap_us=byte_gap),
                   dict(port=port, baud=baud, dry_run=dry),
                   dict(port=port, baud=baud)):
        try:
            return ms.MidiOut(**kwargs)
        except TypeError:
            continue
    return ms.MidiOut(port)


def pause(msg, sec=0.0):
    if sec:
        time.sleep(sec)
    try:
        input("      ↳ {0}   [回车继续] ".format(msg))
    except (EOFError, KeyboardInterrupt):
        raise SystemExit("\n  已中断")


def play(mo, ch, note, vel, hold, gap=0.0):
    """弹一个音，响 hold 秒后自动 Note Off。"""
    mo.send(ms.note_on(ch, note, vel), "Note On  n={0} v={1}".format(note, vel))
    time.sleep(hold)
    mo.send(ms.note_off(ch, note), "Note Off n={0}".format(note))
    if gap:
        time.sleep(gap)


def set_timbre(mo, ch, prog, label=""):
    mo.send(ms.program_change(ch, prog),
            "Program Change pc={0}{1}".format(prog, (" " + label) if label else ""))


# ---------------------------------------------------------------------------
def test1_slots(mo, a):
    print("\n" + "=" * 74)
    print(" 测试 1：8 个音色槽逐一试听")
    print("=" * 74)
    print(" 每个音色弹同一个音（note {0}），中间停 1 秒。".format(a.note))
    print(" 要听的是：")
    print("   · 是否 8 个都出声（某几个没声 = 那个波表槽是空的）")
    print("   · 彼此是否有区别（都一样 = 映射没生效，或槽内容重复）")
    print("   · 音高是否一致（换音色不该改音高）")
    print()
    for prog in range(8):
        # 每种音色配一个干净的音（先 panic，避免上一个音还在释放）
        mo.send_many(ms.panic_msgs(a.ch))
        time.sleep(0.15)
        set_timbre(mo, a.ch, prog, "→ 槽 {0}".format(prog))
        time.sleep(0.05)
        print("      [{0}/7] 音色 {0}".format(prog))
        play(mo, a.ch, a.note, a.vel, a.hold, gap=0.9)
    mo.send_many(ms.panic_msgs(a.ch))
    pause("8 个音色都听过了吗？")


def test2_identity(mo, a):
    print("\n" + "=" * 74)
    print(" 测试 2：恒等映射验证（program 只取低 3 位）")
    print("=" * 74)
    print(" 映射是 timbre_slot = program[2:0]，所以：")
    print("     pc 0 与 pc 8   → 同一个槽 0")
    print("     pc 7 与 pc 15  → 同一个槽 7")
    print(" 每一对应该听起来**完全相同**。")
    print()
    for lo, hi in ((0, 8), (7, 15), (3, 11)):
        mo.send_many(ms.panic_msgs(a.ch))
        time.sleep(0.15)
        for prog, tag in ((lo, "低"), (hi, "高")):
            set_timbre(mo, a.ch, prog)
            time.sleep(0.05)
            print("      pc {0:<3} (槽 {1})".format(prog, prog % 8))
            play(mo, a.ch, a.note, a.vel, a.hold, gap=0.6)
        pause("pc {0} 和 pc {1} 听起来一样吗？（应该一样）".format(lo, hi))
    mo.send_many(ms.panic_msgs(a.ch))


def test3_new_note(mo, a):
    print("\n" + "=" * 74)
    print(" 测试 3：\"新音起效\"语义（GM2 要求）")
    print("=" * 74)
    print(" 步骤：")
    print("   1. 用音色 0 按下一个音，**保持不松**")
    print("   2. 保持期间切换到音色 3")
    print("   3. 那个正在响的音，音色**不应该变** ← 这是正确行为")
    print("   4. 松开后重新按，此时才是音色 3")
    print()
    mo.send_many(ms.panic_msgs(a.ch))
    time.sleep(0.2)
    set_timbre(mo, a.ch, 0)
    time.sleep(0.05)
    mo.send(ms.note_on(a.ch, a.note, a.vel), "Note On  n={0}（保持，音色 0）".format(a.note))
    print("      已按下 note {0}，音色 0 —— 请听住这个音".format(a.note))
    pause("听到了吗？（它会一直响）", 1.0)

    set_timbre(mo, a.ch, 3, "← 正在响的音不该变")
    time.sleep(1.2)
    pause("正在响的音**变了**吗？（不应该变）")

    mo.send(ms.note_off(a.ch, a.note), "Note Off")
    time.sleep(0.3)
    print("      现在重新按同一个音，应该是音色 3：")
    play(mo, a.ch, a.note, a.vel, a.hold, gap=0.5)
    pause("重新按的音是音色 3 吗？（应该和刚才那个不一样）")
    mo.send_many(ms.panic_msgs(a.ch))


def test4_bank(mo, a):
    print("\n" + "=" * 74)
    print(" 测试 4：Bank Select 单独发送不生效")
    print("=" * 74)
    print(" 本期 bank_msb **未参与映射**（timbre_map 的 map_fn 里没用它）。")
    print(" 所以下面这些操作，声音都应该**没有任何变化**：")
    print("   · 单独发 CC0（Bank MSB）")
    print("   · 单独发 CC32（Bank LSB）")
    print("   · CC0 → CC32 → PC 完整序列")
    print()
    mo.send_many(ms.panic_msgs(a.ch))
    time.sleep(0.15)
    set_timbre(mo, a.ch, 2)
    time.sleep(0.05)
    print("      基准：音色 2")
    play(mo, a.ch, a.note, a.vel, a.hold, gap=0.5)

    mo.send(ms.cc(a.ch, 0, 1), "CC0 = 1（Bank MSB）")
    time.sleep(0.1)
    print("      发过 CC0 后：")
    play(mo, a.ch, a.note, a.vel, a.hold, gap=0.5)

    mo.send(ms.cc(a.ch, 32, 0), "CC32 = 0（Bank LSB）")
    time.sleep(0.1)
    print("      再发 CC32 后：")
    play(mo, a.ch, a.note, a.vel, a.hold, gap=0.5)
    pause("这三次听起来一样吗？（应该一样）")

    mo.send_many([ms.cc(a.ch, 0, 1), ms.cc(a.ch, 32, 0), ms.program_change(a.ch, 2)], gap_s=0.02)
    time.sleep(0.15)
    print("      最后：CC0 → CC32 → PC 2 完整序列（仍应是音色 2）")
    play(mo, a.ch, a.note, a.vel, a.hold, gap=0.5)
    mo.send_many(ms.panic_msgs(a.ch))


def test5_pitch(mo, a):
    print("\n" + "=" * 74)
    print(" 测试 5：音高一致性（换音色不改音高）")
    print("=" * 74)
    print(" 同一组音（C4 E4 G4），分别在音色 0 和音色 5 下弹，音高应完全相同。")
    print()
    notes = [60, 64, 67]
    for prog in (0, 5):
        mo.send_many(ms.panic_msgs(a.ch))
        time.sleep(0.15)
        set_timbre(mo, a.ch, prog)
        time.sleep(0.05)
        print("      音色 {0}：".format(prog))
        for n in notes:
            play(mo, a.ch, n, a.vel, a.hold, gap=0.25)
        time.sleep(0.6)
    pause("两轮的音高一样吗？（应该一样）")
    mo.send_many(ms.panic_msgs(a.ch))


TESTS = {
    1: ("8 个音色槽逐一试听", test1_slots),
    2: ("恒等映射验证", test2_identity),
    3: ("\"新音起效\"语义", test3_new_note),
    4: ("Bank Select 不生效", test4_bank),
    5: ("音高一致性", test5_pitch),
}


# ---------------------------------------------------------------------------
def build_parser():
    p = argparse.ArgumentParser(
        description="音色（Program Change）上板测试",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例：\n"
               "  python midi/timbre_test.py -p COM7\n"
               "  python midi/timbre_test.py -p COM7 --only 1\n"
               "  python midi/timbre_test.py -p COM7 --dry-run\n")
    p.add_argument("-p", "--port", help="串口，如 COM7")
    p.add_argument("-b", "--baud", type=int, default=31250, help="波特率（默认 31250）")
    p.add_argument("--ch", type=int, default=1, help="MIDI 通道 1–16（默认 1）")
    p.add_argument("--note", type=int, default=60, help="测试用音符号（默认 60 = C4）")
    p.add_argument("--vel", type=int, default=100, help="力度（默认 100）")
    p.add_argument("--hold", type=float, default=0.7, help="每个音持续秒数（默认 0.7）")
    p.add_argument("--byte-gap", type=int, default=320, help="字节间隔微秒（默认 320 = MIDI 标准）")
    p.add_argument("--only", type=int, choices=sorted(TESTS), help="只跑指定的某一项")
    p.add_argument("--dry-run", action="store_true", help="只打印字节，不打开串口")
    p.add_argument("-y", "--yes", action="store_true",
                   help="不逐项等回车（自动连续跑完，靠耳朵听）")
    return p


def main():
    a = build_parser().parse_args()
    ch = ms._ch(a.ch)

    if not a.dry_run and not a.port:
        print("错误：需要 -p COMx（或用 --dry-run 只看字节）", file=sys.stderr)
        return 2

    print("=" * 74)
    print(" 音色（Program Change）上板测试")
    print("=" * 74)
    print("  串口   : {0}".format(a.port if not a.dry_run else "(dry-run)"))
    print("  通道   : {0}".format(a.ch))
    print("  测试音 : note {0}  vel {1}".format(a.note, a.vel))
    print("  映射   : timbre_slot = program[2:0]  → 8 个槽，program 每 8 个循环一次")
    print()
    print("  ⚠ 确认音频输出（喇叭/耳机）已接好；本脚本靠人耳判断。")
    print("  ⚠ 若按 Ctrl+C 可随时中断，脚本会发 All Notes Off。")

    mo = open_out(a.port, a.baud, a.dry_run, a.byte_gap)
    global pause
    if a.yes:
        pause = lambda msg, sec=0.0: (time.sleep(sec or 0.6))

    try:
        mo.send_many(ms.panic_msgs(ch))
        time.sleep(0.2)
        if a.only:
            todo = [a.only]
        else:
            todo = sorted(TESTS)
        for i in todo:
            name, fn = TESTS[i]
            fn(mo, a)
        print("\n" + "=" * 74)
        print(" 全部测试结束 — 请把现象反馈回来")
        print("=" * 74)
    except KeyboardInterrupt:
        print("\n  已中断")
    finally:
        try:
            mo.send_many(ms.panic_msgs(ch))
        except Exception:
            pass
        mo.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
