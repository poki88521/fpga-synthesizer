# -*- coding: utf-8 -*-
"""
beat_table.py —— 用**真实波表**算每个和弦的“声学拍频表”

思路：波表每个音色的分音幅度 a_k 用最小二乘从 2048 点里拟合出来（比 FFT 更不怕泄漏）。
两音和弦里，若 a 的第 ka 次分音与 b 的第 kb 次分音靠得很近（|Δf| < 30 Hz），
它们相加会产生 |Δf| 包络起伏：
    这一对的调制深度  m = 2·a1·a2 / (a1² + a2²)      （0~100%）
    它对总能量的权重 w = 2·a1·a2 / Σa²
⇒ 只要 w 够大且 m 高，就是能听见的“拍频/粗糙感”。

这一步完全不用仿真：波表 + 音高就够了。它给出“若听感是声学拍频，应该听到多少 Hz”的判据。
"""
import numpy as np

WT = r"D:/code/fpga-synthesizer/develop/board/full_system/data/wave_table.hex"
NH = 12          # 拟合到 12 次分音


def load_wt(path):
    v = []
    for ln in open(path):
        ln = ln.strip()
        if not ln:
            continue
        x = int(ln, 16)
        if x >= 0x8000:
            x -= 0x10000
        v.append(x)
    return np.array(v, float)


def harmonics(s, nh=NH):
    """
    波表是按整数分音合成的一整周期，所以 rfft 的 bin 幅度**就是**分音幅度
    （a_k = 2|X_k|/N，无泄漏）。不用 lstsq —— 本机 numpy 的 LAPACK 会让进程崩。
    """
    N = s.size
    X = np.fft.rfft(s)
    amp = np.zeros(nh + 1)
    for k in range(1, nh + 1):
        amp[k] = 2.0 * abs(X[k]) / N
    amp[0] = abs(X[0]) / N
    return amp


def hz(n):
    return 440.0 * 2 ** ((n - 69) / 12.0)


def chord_beats(notes, amp, names, max_df=30.0, min_w=1e-4):
    """列出这个和弦里所有近重合分音对，按权重排序"""
    rows = []
    total = 2 * np.sum(amp ** 2) * len(notes) if amp.any() else 1.0
    for i in range(len(notes)):
        for j in range(i + 1, len(notes)):
            fa, fb = hz(notes[i]), hz(notes[j])
            for ka in range(1, len(amp)):
                if amp[ka] <= 0:
                    continue
                for kb in range(1, len(amp)):
                    if amp[kb] <= 0:
                        continue
                    x, y = ka * fa, kb * fb
                    d = abs(x - y)
                    if d > max_df or d < 1e-9:
                        continue
                    a1, a2 = amp[ka], amp[kb]
                    m = 2 * a1 * a2 / (a1 ** 2 + a2 ** 2)
                    w = 2 * a1 * a2 / total
                    if w < min_w:
                        continue
                    rows.append((w, d, names[i], ka, x, names[j], kb, y, m))
    rows.sort(reverse=True)
    return rows


def main():
    v = load_wt(WT)
    print("波表 %d 点，8 槽 x 2048" % v.size)
    amps = {}
    for slot in range(8):
        s = v[slot * 2048:(slot + 1) * 2048]
        amps[slot] = harmonics(s)
        a = amps[slot]
        txt = " ".join("%dF:%.1fdB" % (k, 20 * np.log10(a[k] / a[1] + 1e-12))
                       for k in range(1, NH + 1) if a[k] / a[1] > 3e-3)
        print("槽 %d : %s" % (slot, txt))

    chords = [
        ("C4+E4 大三度", [60, 64]),
        ("C4+Eb4 小三度", [60, 63]),
        ("C4+G4 纯五度", [60, 67]),
        ("C4+C5 八度", [60, 72]),
        ("C4+E4+G4 大三和弦", [60, 64, 67]),
        ("C4+E4+G4+B4 大七", [60, 64, 67, 71]),
        ("C4+E4（低八度 C3+E3）", [48, 52]),
        ("C4+E4（高八度 C5+E5）", [72, 76]),
    ]

    for slot in (0, 5, 6):
        print("\n" + "=" * 96)
        print("音色槽 %d%s" % (slot, "（默认钢琴）" if slot == 0 else ""))
        print("=" * 96)
        a = amps[slot]
        for name, notes in chords:
            rows = chord_beats(notes, a, [str(n) for n in notes])
            print("\n  %-26s" % name)
            if not rows:
                print("      30 Hz 内没有近重合分音 -> 结构上不可能有拍频")
                continue
            for w, d, na, ka, x, nb, kb, y, m in rows[:3]:
                print("      Δ=%6.2f Hz   %s %dF(%.1f) x %s %dF(%.1f)"
                      "   该对调制深度 %3.0f%%   能量权重 %5.1f%%"
                      % (d, na, ka, x, nb, kb, y, 100 * m, 100 * w))


if __name__ == "__main__":
    main()
