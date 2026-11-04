#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fix_wavetable.py —— 定点修改波表某槽的个别谐波（默认槽 0 的 4F/5F）

背景（2026-11-02 诊断）：
    C4+E4 的 10.3 Hz 拍频来自 **C4 的 5 次分音(1308.2) × E4 的 4 次分音(1318.5)**。
    包络纹波幅度 = 2·min(a5F, a4F)。当前 a5F = −24.6 dB(0.059)、a4F = −8.1 dB(0.394)
    ⇒ min = 5F ⇒ 想真正削弱拍频，必须压 **5F**（只压 4F 反而让相对深度变大）。

    ⚠ 槽 0 的 4F 之所以这么强（−8.1 dB，而 full_system.v 注释写的是 13.3% = −16.2 dB），
      是因为 rebuild_wave_table.py 的"谐波量化"把源里 bin7（= 3.5× 基频，12.8% 能量）
      折进了 round(3.5)=4 次谐波。

用法：
    python fix_wavetable.py                        # dry-run，打印改前/改后指标
    python fix_wavetable.py --att5 -11 --att4 -6   # 指定衰减（dB）
    python fix_wavetable.py --att5 -11 --att4 -6 --write   # 真正写盘（两处产物）
    python fix_wavetable.py --write --out <file>   # 只写指定文件

安全措施：
    · 只改指定槽的那几个谐波，其余槽的 2048 行**逐字节保留**（改完会逐行比对并报告）
    · 写盘前把原文件备份为 <file>.bak_YYYYmmdd_HHMM
    · 改完重新把峰值归一化回原峰值（保持整体响度不变，只改音色比例）
"""
import argparse
import datetime
import os
import shutil

import numpy as np

NPT = 2048
NSLOT = 8
C4 = 261.6255653006
E4 = 329.6275569129
FS = 48000.0


def load_hex(path):
    v = []
    for ln in open(path):
        s = ln.strip()
        if not s:
            continue
        x = int(s, 16)
        v.append(x - 65536 if x >= 32768 else x)
    return np.array(v, dtype=np.int64)


def harm_amp(sig):
    """整周期信号：rfft 的 bin 幅度就是分音幅度（无泄漏）"""
    N = sig.size
    X = np.fft.rfft(sig.astype(np.float64))
    amp = 2.0 * np.abs(X) / N
    amp[0] /= 2
    return amp


def apply_gains(s, gains_db, renorm_peak=None, clip=32767):
    """
    按谐波增益重建该槽。gains_db: {k: dB}
    renorm_peak: 若给出，重建后线性缩放使峰值回到该值（保持响度）
    """
    N = s.size
    S = np.fft.rfft(s.astype(np.float64))
    for k, db in gains_db.items():
        if k < S.size:
            S[k] *= 10 ** (db / 20.0)
    y = np.fft.irfft(S, N)
    if renorm_peak is not None and np.max(np.abs(y)) > 0:
        y = y * (renorm_peak / np.max(np.abs(y)))
    y = np.rint(y)
    y = np.clip(y, -clip, 32767)
    return y.astype(np.int64)


def beat_metrics(a5, a4):
    """a5/a4 是线性幅度（相对 1F=1）。返回包络纹波与相对深度"""
    mn = min(a5, a4)
    mx = max(a5, a4)
    ripple = 2 * mn
    depth = 2 * a5 * a4 / (a5 ** 2 + a4 ** 2 + 1e-30)
    return ripple, depth, ripple / (mx + 1e-30)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default=r"D:/code/fpga-synthesizer/develop/board/full_system/data/wave_table.hex")
    ap.add_argument("--file2", default=r"D:/code/fpga-synthesizer/develop/wave_table/out/wave_table.hex")
    ap.add_argument("--slot", type=int, default=0)
    ap.add_argument("--att5", type=float, default=-11.0, help="5 次分音衰减 dB（负=衰减）")
    ap.add_argument("--att4", type=float, default=0.0, help="4 次分音衰减 dB")
    ap.add_argument("--no-renorm", action="store_true", help="不做峰值归一化")
    ap.add_argument("--write", action="store_true")
    a = ap.parse_args()

    v = load_hex(a.file)
    if v.size != NPT * NSLOT:
        raise SystemExit("点数不对: %d" % v.size)
    s = v[a.slot * NPT:(a.slot + 1) * NPT].copy()
    amp0 = harm_amp(s)

    gains = {}
    if a.att5:
        gains[5] = a.att5
    if a.att4:
        gains[4] = a.att4
    pk0 = np.max(np.abs(s))
    y = apply_gains(s, gains, renorm_peak=None if a.no_renorm else pk0)
    amp1 = harm_amp(y)

    print("=" * 92)
    print("槽 %d  修改: %s   峰值归一化: %s" %
          (a.slot, gains if gains else "无", "关" if a.no_renorm else "回 %d" % pk0))
    print("=" * 92)
    print("%-6s %12s %12s %12s" % ("谐波", "改前dB", "改后dB", "变化dB"))
    for k in range(1, 13):
        if amp0[k] / amp0[1] < 1e-4 and amp1[k] / amp1[1] < 1e-4:
            continue
        d0 = 20 * np.log10(amp0[k] / amp0[1] + 1e-15)
        d1 = 20 * np.log10(amp1[k] / amp1[1] + 1e-15)
        print("%-6d %12.1f %12.1f %12.1f" % (k, d0, d1, d1 - d0))

    print("\n峰值: 原 %d -> 新 %d（%.2f dB）" % (pk0, np.max(np.abs(y)),
                                          20 * np.log10(np.max(np.abs(y)) / pk0 + 1e-15)))
    print("RMS : 原 %.0f -> 新 %.0f（%.2f dB）" %
          (np.sqrt(np.mean(s.astype(float) ** 2)), np.sqrt(np.mean(y.astype(float) ** 2)),
           10 * np.log10(np.mean(y.astype(float) ** 2) / np.mean(s.astype(float) ** 2) + 1e-15)))

    #  ---- 拍频预测（C4 + E4，以 1F 为 0 dB）----
    def lin(k, amp):
        return amp[k] / amp[1]

    print("\n拍频预测（C4 5F @%.1f Hz  ×  E4 4F @%.1f Hz，Δ=%.2f Hz）"
          % (5 * C4, 4 * E4, abs(5 * C4 - 4 * E4)))
    for tag, amp in (("改前", amp0), ("改后", amp1)):
        a5, a4 = lin(5, amp), lin(4, amp)
        r, m, rel = beat_metrics(a5, a4)
        print("  %s: 5F=%.1f dB  4F=%.1f dB  纹波 2·min=%.4f  拍频深度 %.0f%%  相对 4F 载波 %.0f%%"
              % (tag, 20 * np.log10(a5), 20 * np.log10(a4), r, 100 * m, 100 * rel))

    #  ---- 完整性：其余槽逐行比对 ----
    new_v = v.copy()
    new_v[a.slot * NPT:(a.slot + 1) * NPT] = y
    diff_slots = [k for k in range(NSLOT) if k != a.slot
                  and not np.array_equal(new_v[k * NPT:(k + 1) * NPT], v[k * NPT:(k + 1) * NPT])]
    print("\n其它槽是否被改动: %s" % ("无（逐行一致）" if not diff_slots else diff_slots))
    print("本槽改动点数: %d / %d，最大改动 %d LSB"
          % (int(np.sum(y != s)), NPT, int(np.max(np.abs(y - s)))))
    print("无符号回绕检查: 新峰值 %d（< 32768: %s）"
          % (int(np.max(np.abs(y))), bool(np.max(np.abs(y)) < 32768)))

    if not a.write:
        print("\n[dry-run] 未写盘。加 --write 才会写。")
        return

    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M")
    lo, hi = a.slot * NPT, (a.slot + 1) * NPT
    for path in [a.file, a.file2]:
        if not path or not os.path.exists(path):
            print("跳过（不存在）: %s" % path)
            continue
        raw = open(path, "rb").read()
        eol = b"\r\n" if b"\r\n" in raw[:4096] else b"\n"
        trail = b"" if raw.endswith(eol) else b""
        #  ⚠ 只替换本槽那 2048 行，其余行**原样字节保留**（换行符也保留）
        txt = raw.decode("ascii")
        lines = txt.split(eol.decode())
        if lines and lines[-1] == "":
            lines = lines[:-1]
        if len(lines) != NPT * NSLOT:
            print("!! %s 行数 %d 异常，跳过" % (path, len(lines)))
            continue
        for i in range(NPT):
            lines[lo + i] = "%04X" % (int(y[i]) & 0xFFFF)
        out = eol.decode().join(lines) + (eol.decode() if raw.endswith(eol) else "")

        bak = "%s.bak_%s" % (path, stamp)
        shutil.copy2(path, bak)
        with open(path, "wb") as f:
            f.write(out.encode("ascii"))
        print("已写 %s\n  备份 %s" % (path, bak))

        #  回读校验：行数、大小、只动了本槽
        chk_raw = open(path, "rb").read()
        chk = load_hex(path)
        same_size = (len(chk_raw) == len(raw))
        others_ok = np.array_equal(chk[:lo], v[:lo]) and np.array_equal(chk[hi:], v[hi:])
        slot_ok = np.array_equal(chk[lo:hi], y)
        chg = [i for i in range(len(lines))
               if lines[i] != raw.decode("ascii").split(eol.decode())[i]]
        out_of_slot = [i for i in chg if not (lo <= i < hi)]
        print("  回读: 字节数一致=%s  其它槽逐行一致=%s  本槽等于新表=%s  改动行=%d  槽外改动行=%d"
              % (same_size, others_ok, slot_ok, len(chg), len(out_of_slot)))
        if not (same_size and others_ok and slot_ok and not out_of_slot):
            print("  !! 校验未通过，请用备份回退: %s" % bak)


if __name__ == "__main__":
    main()
