# -*- coding: utf-8 -*-
"""用 pseudo-terminal 验证 midi_serial.py **真的把字节写进了串口**。
   PTY 的 master 端当"接收方"（相当于 FPGA 的 UART RX）。"""
import os, sys, time, subprocess, threading

#  ⚠ 本脚本与 midi_serial.py **同目录**（原来放在 _t/ 子目录里，
#    搬出来时这里少改了一层，导致子进程找不到 midi_serial.py → 返回码 2）
TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(TOOLS, 'lib'))

def run(args, expect_hex, label):
    master, slave = os.openpty()
    sname = os.ttyname(slave)
    got = bytearray(); stop = threading.Event()
    def reader():
        os.set_blocking(master, False)
        while not stop.is_set():
            try:
                d = os.read(master, 4096)
                if d: got.extend(d)
                else: time.sleep(0.005)
            except BlockingIOError: time.sleep(0.005)
            except OSError: break
    th = threading.Thread(target=reader, daemon=True); th.start()
    time.sleep(0.1)
    r = subprocess.run([sys.executable, os.path.join(TOOLS,'midi_serial.py'),
                        '-p', sname, '-q'] + args, capture_output=True, text=True)
    time.sleep(0.4); stop.set(); th.join(timeout=1)
    os.close(master); os.close(slave)
    want = bytes(int(x,16) for x in expect_hex.split())
    ok = bytes(got) == want
    print(f"  {'✓' if ok else '✗'} {label:24s} 发 {' '.join(f'{b:02X}' for b in want):26s} 收 {' '.join(f'{b:02X}' for b in got)}")
    if r.returncode != 0: print(f"      ⚠ 返回码 {r.returncode}: {r.stdout.strip()[:100]}")
    return ok

ok = True
print("=== 真实串口回环（PTY 当 FPGA 的 UART RX）===")
for args, want, label in [
    (['note','60','100'],                       "90 3C 64",              "note 60 100"),
    (['note','60','100','--hold','0.05'],       "90 3C 64 80 3C 40",     "note --hold"),
    (['cc','7','100'],                          "B0 07 64",              "cc 7 100"),
    (['pc','16'],                               "C0 10",                 "pc 16"),
    (['bend','8192'],                           "E0 00 40",              "bend 8192 中心"),
    (['sysex','effect','1','2','1000'],         "F0 7D 01 02 07 68 F7",  "sysex effect"),
    (['sysex','volume','16383'],                "F0 7F 00 04 01 7F 7F F7","sysex volume"),
    (['sysex','gm-reset'],                      "F0 7E 7F 09 01 F7",     "sysex gm-reset"),
    (['raw','90 3C 64','80 3C 40','--gap','0'], "90 3C 64 80 3C 40",     "raw 两条"),
    (['--ch','10','note','60','100'],           "99 3C 64",              "通道 10 → 状态 99"),
]:
    ok &= run(args, want, label)

print()
print("=== scale 完整序列回环（60→62，上行+下行）===")
ok &= run(['scale','60','62','--step','0','--hold','0'],
          "90 3C 64 80 3C 40 90 3D 64 80 3D 40 90 3E 64 80 3E 40 "
          "90 3E 64 80 3E 40 90 3D 64 80 3D 40 90 3C 64 80 3C 40", "scale 60 62")

print()
print("=== --byte-gap 生效？===")
master, slave = os.openpty(); sname = os.ttyname(slave)
t0 = time.time()
subprocess.run([sys.executable, os.path.join(TOOLS,'midi_serial.py'),
                '-p', sname, '-q', '--byte-gap', '2000', 'note','60','100'],
               capture_output=True, text=True)
dt = time.time() - t0
os.close(master); os.close(slave)
good = dt > 0.004; ok &= good
print(f"  {'✓' if good else '✗'} --byte-gap 2000µs × 3 字节耗时 {dt*1000:.1f} ms（应 > 4ms，真串口等效 31250 baud 的 320µs/字节节拍）")

print()
print("✅ 真实串口写入全部通过" if ok else "❌ 有失败项")
sys.exit(0 if ok else 1)
