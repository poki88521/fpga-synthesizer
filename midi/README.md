# 串口 MIDI 发送工具 · 用法

> 工具：`midi/midi_serial.py`（本目录）
> 日期：2026-10-08
> 用途：上板实测时给 FPGA 发 MIDI（音阶自检、单音长按测群延迟、CC 扫频看滤波、SysEx 改效果参数）

---

## 一、它解决什么问题

本项目的 FPGA 有 **4 路标准 MIDI UART 输入**（`full_system.midi_rx[3:0]`，31250 baud / 8N1）。
`测试清单.md` 里一堆"待实测"项（PT8211 群延迟、滤波响应、效果器听感、声部分配）
过去都卡在**没有 MIDI 源**。这个脚本就是那个源。

**不依赖外部安装**：pyserial 已自带在 `midi/lib/`（460 KB），无需 pip。

---

## 二、硬件接线

```
PC (USB-TTL 串口模块)                FPGA
   TX  ────────────────────────▶  midi_rx[0]   （乐器端口 1）
   GND ────────────────────────   GND
                              ──  midi_rx[1..3]  （可选：其他 3 路）
```

### ⚠ 三条硬性注意

| # | 注意 | 后果 |
|---|---|---|
| 1 | **必须 3.3V 电平**的 USB-TTL 模块 | 用 RS-232 电平（±12V）直连会**打坏 IO** |
| 2 | **TX 接 RX**（交叉），GND 必须共地 | 收不到 |
| 3 | 若经光耦/长线，加 `--byte-gap 320` | 全速发可能丢字节 |

**串口名**：Linux 是 `/dev/ttyUSB0`（插上后用 `ls /dev/ttyUSB*` 看）；
Windows 是 `COM3` 之类（设备管理器 → 端口）。

---

## 三、快速上手

```bash
cd myMain/beta/midi

# ① 先确认会发什么（不接硬件也能用）
python3 midi_serial.py --dry-run note 60 100

# ② 连通性自检：音阶（最直观——能听见就说明整链通了）
python3 midi_serial.py -p /dev/ttyUSB0 scale 48 72 --step 0.3

# ③ 单音长按（测包络/群延迟）
python3 midi_serial.py -p /dev/ttyUSB0 note 60 100 --hold 2
```

---

## 四、子命令

| 子命令 | 说明 | 例子 |
|---|---|---|
| `note` | Note On（可自动 Note Off） | `note 60 100` / `note 60 100 --hold 2` |
| `cc` | Control Change | `cc 7 100`（音量）· `cc 10 64`（声像居中）· `cc 91 127`（混响发送满） |
| `pc` | Program Change（切音色） | `pc 16` |
| `bend` | Pitch Bend（14 位，**中心 8192**） | `bend 8192`（不弯）· `bend 16383`（向上到底）· `bend -1000`（略向下） |
| `sysex` | SysEx 三种 | `sysex effect 1 2 1000` · `sysex volume 16383` · `sysex gm-reset` |
| `raw` | **直接发十六进制**（最通用） | `raw "90 3C 64" "80 3C 40"` · `raw --file 序列.txt` |
| `scale` | 音阶自检（上行+下行） | `scale 60 72 --vel 100 --step 0.25` |
| `chord` | 和弦 | `chord 60 maj` · `chord 57 min7 --hold 2` |
| `panic` | 全通道 All Notes Off + All Sound Off | `panic` |
| `interactive` | 交互模式（试参数最方便） | `interactive` |

**常用选项**：`-p/--port` · `--ch`（通道 1–16，默认 1）· `--dry-run` ·
`--byte-gap US`（字节间隔微秒，0=全速）· `-q`（安静模式，便于脚本调用）

---

## 五、对着本项目协议的实用序列

### 5.1 音色 / 通道
```bash
# 通道 1 切到音色 16
python3 midi_serial.py -p /dev/ttyUSB0 pc 16

# 鼓组库（CC0 Bank MSB = 120 = 0x78），然后切音色
python3 midi_serial.py -p /dev/ttyUSB0 cc 0 120
python3 midi_serial.py -p /dev/ttyUSB0 pc 0
```

### 5.2 混音参数（验证效果器听感）
```bash
# 干声（发送全 0）
python3 midi_serial.py -p /dev/ttyUSB0 raw "B0 5B 00" "B0 5D 00" "B0 5E 00"
# 混响满（CC91）
python3 midi_serial.py -p /dev/ttyUSB0 cc 91 127
# 合唱满（CC93）/ 延迟满（CC94）
python3 midi_serial.py -p /dev/ttyUSB0 cc 93 127
python3 midi_serial.py -p /dev/ttyUSB0 cc 94 127
```

### 5.3 效果参数 SysEx（`F0 7D <slot> <param> <val_hi> <val_lo> F7`）
```bash
# 组 1、参数 2、值 1000  → 发 F0 7D 01 02 07 68 F7
python3 midi_serial.py -p /dev/ttyUSB0 sysex effect 1 2 1000
```

### 5.4 主音量 SysEx（GM2：`F0 7F 00 04 01 ll mm F7`）
```bash
python3 midi_serial.py -p /dev/ttyUSB0 sysex volume 16383   # 满
python3 midi_serial.py -p /dev/ttyUSB0 sysex volume 8192    # 一半
python3 midi_serial.py -p /dev/ttyUSB0 sysex volume 0       # 静音
```

### 5.5 40 kHz 采样带宽 / 滤波扫频（CC74 = 截止频率调制）
```bash
# 从暗到亮扫一遍（听音色变化）
for v in 0 16 32 48 64 80 96 112 127; do
  python3 midi_serial.py -p /dev/ttyUSB0 -q cc 74 $v
  sleep 0.2
done
```

### 5.6 **测群延迟**（`测试清单.md` 的 T-6）
```bash
# 长按单音，用示波器/声卡看"MIDI 字节发出"到"喇叭出声"的时延
python3 midi_serial.py -p /dev/ttyUSB0 note 60 127 --hold 5
```
> 更精确的做法：加 `--byte-gap 320` 让字节按标准节拍发，便于对齐时基。

---

## 六、自检（不接硬件）

```bash
python3 selftest_midi_serial.py
```
用 **pseudo-terminal 模拟串口做回环**：CLI 发 → PTY 另一端收 → **逐字节比对**。
覆盖 note / cc / pc / bend / sysex×3 / raw / scale / 通道换算 / `--byte-gap`，
全部与 `MIDI协议.md` 的范例对齐。

期望结尾：`✅ 真实串口写入全部通过`

---

## 七、交互模式（试参数最快）

```bash
python3 midi_serial.py -p /dev/ttyUSB0 interactive
```
```
midi> 90 3C 64        直接发十六进制
midi> n 60 100        Note On
midi> f 60            Note Off
midi> c 7 100         CC#7 = 100
midi> q               退出
```

---

## 八、故障排查

| 现象 | 检查 |
|---|---|
| `打开串口失败：Permission denied` | Linux 下加 `sudo`，或把用户加进 `dialout` 组 |
| `找不到 pyserial` | 确认 `midi/lib/serial/` 存在（本工具自带） |
| 发了没声音 | ① 3.3V 电平？② TX/RX 交叉？③ 共地？④ FPGA 是否已烧录？⑤ 通道号对不对（`--ch`）？ |
| 偶发丢音 | 加 `--byte-gap 320`；或检查线长/光耦 |
| 想确认"到底发了什么" | 任何命令加 `--dry-run`，会逐字节打印 |
| Windows 下中文乱码 | 工具已强制 UTF-8 输出；若仍乱码，`chcp 65001` |

---

## 九、实现要点（供改代码的人）

1. **字节构造是纯函数**（`note_on` / `cc` / `sysex_effect` …），不含 I/O
   —— 便于单独测试，也便于别的脚本 `import` 复用。
2. **`pitch_bend` 语义已明确**：`0–16383，中心 8192`（与 `硬件实现.md` 的 `bend_value` 一致）；
   另接受负数 `-8192..-1` 表示向下弯。
   > 早先写成"只在负数时加偏置"，导致 `0` 有歧义（本意"向下弯到底"却得到"不弯"）——
   > 已修，并在自检里锁住。
3. **`termios.error` 不继承 `OSError`/`ValueError`**：PTY 不支持设波特率时抛的就是它。
   所以打开串口的降级分支必须 `except Exception`，否则永远进不去（我第一版就写错了）。
   真串口不受影响。
