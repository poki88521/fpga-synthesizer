#!/usr/bin/env python3
"""把 simulation/out/demo.txt（每行 "左 右" 两个 16-bit 有符号整数）转成 WAV。

用法： python3 simulation/tools/wav.py [输入txt] [输出wav] [采样率]
"""
import sys, struct, wave, os

src = sys.argv[1] if len(sys.argv) > 1 else "simulation/out/demo.txt"
dst = sys.argv[2] if len(sys.argv) > 2 else "simulation/out/demo.wav"
fs  = int(sys.argv[3]) if len(sys.argv) > 3 else 48828

if not os.path.exists(src):
    sys.exit(f"找不到 {src}")

L, R = [], []
with open(src) as f:
    for line in f:
        p = line.split()
        if len(p) < 2:
            continue
        l, r = int(p[0]), int(p[1])
        L.append(max(-32768, min(32767, l)))
        R.append(max(-32768, min(32767, r)))

n = min(len(L), len(R))
if n == 0:
    sys.exit("输入里没有样本")

peak = max(max(abs(v) for v in L), max(abs(v) for v in R))
rms  = (sum(v * v for v in L) / n) ** 0.5

with wave.open(dst, "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(fs)
    frames = bytearray()
    for i in range(n):
        frames += struct.pack("<hh", L[i], R[i])
    w.writeframes(bytes(frames))

print(f"{dst}")
print(f"  样本数   : {n}  ({n/fs:.2f} 秒 @ {fs} Hz)")
print(f"  峰值     : {peak} / 32767  ({20*__import__('math').log10(max(peak,1)/32767):.1f} dBFS)")
print(f"  RMS      : {rms:.0f}")
print(f"  非零样本 : {sum(1 for v in L if v) } / {n}")
