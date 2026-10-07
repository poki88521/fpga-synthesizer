## 零、目录
- [[#一、简介]]
- [[#二、协议格式]]
    - [[#传输格式]]
    - [[#运行状态]]
    - [[#状态字节表]]
        - [[#系统消息]]
        - [[#通道消息]]
- [[#三、控制变更（Control Change）]]
    - [[#CC 简介]]
    - [[#CC 号表]]
    - [[#特殊 CC]]
        - [[#音色库选择（CC0 / CC32）]]
        - [[#效果发送量（CC91 / CC93 / CC94）]]
        - [[#复位（CC121）]]
        - [[#14 位配对]]
        - [[#其他]]
- [[#四、音色库选择（Bank Select）]]
    - [[#原理]]
    - [[#注意事项]]
    - [[#关于鼓]]
    - [[#示例]]
- [[#五、General MIDI]]
    - [[#GM 简介]]
    - [[#GM1]]
    - [[#GM2]]
    - [[#Program Change 规定]]
- [[#六、SysEx]]
    - [[#格式]]
    - [[#主音量调节]]
- [[#参考来源]]

---
## 一、简介

> **状态标注约定**：本表「本项目落点」一列中，标 **（暂缓）** 的字段属本期不实现的功能
> （LFO / 颤音 / FM / 双波表 / 鼓组，详见 `技术文档.md` 附录 B），
> 其字段已从状态表移出，**RTL 阶段不要按本表去读这些字段**。
MIDI 是一种串行通信协议，用于在电子乐器与计算机之间传输演奏信息。

它传输的不是声音本身，而是**演奏动作的描述**（按了哪个键、力度多大、踏板是否踩下等）。接收方（音源）根据这些描述实时合成声音。因此同一份 MIDI 数据在不同设备上播放，音色可能不同，但演奏内容完全一致。

一条 MIDI 消息的基本形态是：**状态字节 + 若干数据字节**。状态字节说明「这是什么消息、属于哪个通道」，数据字节说明「具体数值」。

---
## 二、协议格式

### 传输格式
- **波特率 31250**，每个字节传输 **10 位**：起始位 1 位（0） + 数据 8 位 + 停止位 1 位（1）
- 数据字节的高位标志其类型：
    + **状态字节**：最高位为 **1**（`0b1xxx xxxx`）
    + **数据字节**：最高位为 **0**（`0b0xxx xxxx`），取值范围 0–127
- 整体结构通常为：**1 个状态字节 + 1~2 个数据字节**

### 运行状态
**连续发送多条同类型的通道消息时，后续消息的状态字节可以省略** —— 这一机制称为「运行状态（Running Status）」。

**示例**（连续弹三个音，通道 1）：

```
标准写法    90 3C 64   90 3E 64   90 40 64
运行状态    90 3C 64      3E 64      40 64
                          ↑ 省略了状态字节 90
```

**四条规则：**

| 收到 | 对运行状态的影响 |
|---|---|
| 通道状态字节（`0x80`–`0xEF`） | **替换**为新状态，继续有效 |
| System Common / SysEx（`0xF0`–`0xF7`） | **清除**，之后必须重新出现完整状态字节 |
| System Real-Time（`0xF8`–`0xFE`） | **不影响**，保持原状态 |
| 数据字节（`0x00`–`0x7F`） | 按当前状态解析 |

**两个实现要点：**
- **实时消息可以插入到一条消息的数据字节之间**，它既不打断当前消息的解析，也不清除运行状态。解析时须先把实时字节剔除
- 数据字节数量多余或不足时：**多余**的数据字节应视为下一条运行状态消息的开头；**不足**则等待下一个状态字节，此时未完成的消息被重置

> 对本项目：接收方（FPGA）必须实现运行状态，否则连续演奏时解析会出错。

### 状态字节表

#### 系统消息
特点：**不含通道号**，作用于整个设备。

| 状态字节 | 含义 | 数据字节数 | 数据结构 | 范例（十六进制 / 二进制） |
|---|---|---|---|---|
| `0xF0` | SysEx 开始 | 可变 | 厂商 ID + 数据… + `0xF7` | `F0 7E 7F 09 03 F7`<br>`1111 0000 · 0111 1110 · 0111 1111 · 0000 1001 · 0000 0011 · 1111 0111` |
| `0xF1` | MTC Quarter Frame | 1 | 数据字节 0–127 | `F1 2A`<br>`1111 0001 · 0010 1010` |
| `0xF2` | Song Position Pointer | 2 | LSB, MSB（14 位） | `F2 00 40`<br>`1111 0010 · 0000 0000 · 0100 0000` |
| `0xF3` | Song Select | 1 | 歌曲号 0–127 | `F3 05`<br>`1111 0011 · 0000 0101` |
| `0xF4` | Undefined | 0 | — | `F4`<br>`1111 0100` |
| `0xF5` | Undefined | 0 | — | `F5`<br>`1111 0101` |
| `0xF6` | Tune Request | 0 | — | `F6`<br>`1111 0110` |
| `0xF7` | EOX / SysEx 结束 | 0 | — | `F7`<br>`1111 0111` |
| `0xF8` | Timing Clock | 0 | — | `F8`<br>`1111 1000` |
| `0xF9` | Undefined | 0 | — | `F9`<br>`1111 1001` |
| `0xFA` | Start | 0 | — | `FA`<br>`1111 1010` |
| `0xFB` | Continue | 0 | — | `FB`<br>`1111 1011` |
| `0xFC` | Stop | 0 | — | `FC`<br>`1111 1100` |
| `0xFD` | Undefined | 0 | — | `FD`<br>`1111 1101` |
| `0xFE` | Active Sensing | 0 | — | `FE`<br>`1111 1110` |
| `0xFF` | System Reset | 0 | — | `FF`<br>`1111 1111` |

> 仅 `0xF0` / `F1` / `F2` / `F3` 带数据字节，其余系统消息为单字节。

#### 通道消息
特点：**含通道号** `n`（0–F，对应通道 1–16），只作用于指定通道。

| 状态字节   | 含义                                              | 数据字节数 | 数据结构                   | 范例（十六进制 / 二进制）                                    |
| ------ | ----------------------------------------------- | ----- | ---------------------- | ------------------------------------------------- |
| `0x8n` | Note Off                                        | 2     | 音符号 0–127, 释放力度 0–127  | `80 3C 40`<br>`1000 0000 · 0011 1100 · 0100 0000` |
| `0x9n` | Note On                                         | 2     | 音符号 0–127, 力度 0–127    | `90 3C 64`<br>`1001 0000 · 0011 1100 · 0110 0100` |
| `0xAn` | Polyphonic Key Pressure                         | 2     | 音符号 0–127, 压力值 0–127   | `A0 3C 32`<br>`1010 0000 · 0011 1100 · 0011 0010` |
| `0xBn` | [[#三、控制变更（Control Change）\|Control Change（CC）]] | 2     | 控制器号 0–127, 控制器值 0–127 | `B0 07 7F`<br>`1011 0000 · 0000 0111 · 0111 1111` |
| `0xCn` | Program Change                                  | 1     | 音色号 0–127              | `C0 10`<br>`1100 0000 · 0001 0000`                |
| `0xDn` | Channel Pressure                                | 1     | 压力值 0–127              | `D0 40`<br>`1101 0000 · 0100 0000`                |
| `0xEn` | Pitch Bend Change                               | 2     | LSB, MSB；14 位，中心 8192  | `E0 00 40`<br>`1110 0000 · 0000 0000 · 0100 0000` |

**两点注意：**
- **力度 0 的 Note On 等价于 Note Off**（常用左手法规避 Note Off 与 Note On 混用）
- **Pitch Bend 是 14 位**：`值 = MSB × 128 + LSB`，中心 8192（LSB=0，MSB=64）

---
## 三、控制变更（Control Change）

### CC 简介
**CC 是 MIDI 中用于「连续调节类」参数的消息类型**，区别于 Note On/Off 这类「事件类」消息。音量、声像、踏板、调制轮等均通过 CC 传输。

**结构**（3 字节）：

```
Bn  CC号  值
│   │     └─ 0–127，控制器值
│   └─────── 0–127，控制器号
└─────────── 状态字节；n = 通道号 0–F
```

**要点：**
- 控制器号与值都只有 **7 位（0–127）**，这是 MIDI 单字节传数据的限制
- 需要更高精度时，规范用**两个 CC 拼成 14 位**（MSB + LSB 机制），如 CC7 + CC39
- 控制器号共 **128 个**，含义由 MIDI 规范分配（见下表）

### CC 号表
带链接的是 [[#特殊 CC]] 中详细展开的项。

| CC | 名称 | 说明 | 本项目落点 |
|---|---|---|---|
| [[#音色库选择（CC0 / CC32）\|0]] | Bank Select MSB | 音色库号高 7 位 | 通道表 `bank_msb` |
| 1 | Modulation Wheel | 调制轮 | 通道表 `mod_wheel`（**暂缓**，随 LFO） |
| 2 | Breath Controller | 呼吸控制器 | — |
| 4 | Foot Controller | 脚踏控制器 | — |
| 5 | Portamento Time | 滑音时间 | — |
| 6 | Data Entry MSB | 数据输入高字节（配合 RPN/NRPN） | — |
| 7 | Channel Volume | 通道音量 | 通道表 `volume` |
| 8 | Balance | 左右平衡 | — |
| 10 | Pan | 声像（64 = 居中） | 通道表 `pan` |
| 11 | Expression | 表情（与 CC7 相乘） | 通道表 `expression` |
| 12 / 13 | Effect Control 1 / 2 | 效果控制 | — |
| 16–19 | General Purpose Controller 1–4 | 通用控制器 | — |
| [[#音色库选择（CC0 / CC32）\|32]] | Bank Select LSB | 音色库号低 7 位 | 通道表 `bank_lsb` |
| 33–63 | LSB for CC 1–31 | 上述控制器的低字节 | — |
| 64 | Damper / Sustain Pedal | 延音踏板 | 通道表 `sustain_pedal` |
| 65 | Portamento On/Off | 滑音开关 | — |
| 66 | Sostenuto | 持音踏板 | 通道表 `sostenuto_pedal` |
| 67 | Soft Pedal | 弱音踏板 | — |
| 68 / 69 | Legato Footswitch / Hold 2 | 连奏开关 / 保持 2 | — |
| 70 | Sound Controller 1 | 音色变化 | — |
| 71 | Sound Controller 2 | 谐振 / 音色亮度 | 通道表 `resonance_mod` |
| 72 | Sound Controller 3 | 释音时间 | 通道表 `release_mod` |
| 73 | Sound Controller 4 | 起音时间 | 通道表 `attack_mod` |
| 74 | Sound Controller 5 | 亮度 / 截止频率 | 通道表 `filter_cutoff_mod` |
| 75–79 | Sound Controller 6–10 | Decay / 颤音速率 / 颤音深度 / 颤音延迟 / 音色控制 | 77 关联 `vibrato_depth`（**暂缓**，随 LFO） |
| 80–83 | General Purpose Controller 5–8 | 通用控制器 | — |
| 84 | Portamento Control | 滑音控制 | — |
| 88 | High Resolution Velocity Prefix | 高清力度前缀（较新规范追加） | — |
| [[#效果发送量（CC91 / CC93 / CC94）\|91]] | Effect 1 Depth | 混响发送量 | 通道表 `send_reverb` |
| 92 | Effect 2 Depth | 颤音深度（GM1）/ GM2 未强制 | — |
| [[#效果发送量（CC91 / CC93 / CC94）\|93]] | Effect 3 Depth | 合唱发送量 | 通道表 `send_chorus` |
| [[#效果发送量（CC91 / CC93 / CC94）\|94]] | Effect 4 Depth | 依标准而异 | 通道表 `send_delay` |
| 95 | Effect 5 Depth | 效果 5 深度 | — |
| 96 / 97 | Data Increment / Decrement | 数据递增 / 递减 | — |
| 98 / 99 | NRPN LSB / MSB | 非注册参数号 | — |
| 100 / 101 | RPN LSB / MSB | 注册参数号 | RPN 0,0 读取 |
| 120 | All Sound Off | 立即静音（不等释音） | — |
| [[#复位（CC121）\|121]] | Reset All Controllers | 复位所有控制器 | — |
| 122 | Local Control On/Off | 本地控制开关 | — |
| 123 | All Notes Off | 关闭所有音符 | — |
| 124 / 125 | Omni Off / On | 全通道模式开关 | — |
| 126 / 127 | Mono / Poly Mode On | 单音 / 复音模式 | — |

> 未列出的号段（3、9、14–15、20–31、85–87、89–90、102–119）在 MIDI 1.0 中为保留 / 未定义。

### 特殊 CC

#### 音色库选择（CC0 / CC32）
用于扩展音色寻址空间。**详见 [[#四、音色库选择（Bank Select）]]。**

#### 效果发送量（CC91 / CC93 / CC94）

| CC | 名称 | 说明 |
|---|---|---|
| 91 | Reverb Send Level | 混响发送量。响应曲线相对幅度**线性**，**值 127 = 发送量 100%** |
| 93 | Chorus Send Level | 合唱发送量。值 127 = 最大发送 |
| 94 | Effect 4 Depth | **含义依标准而异**，见下 |

- CC91 / CC93 在 GM2 中被列为**必需控制器**
- GM2 默认值：CC91 = **40（0x28）**；CC93 默认通常为 0

**CC94 的差异：**

| 标准 | CC94 含义 |
|---|---|
| MIDI 1.0 早期 / GM1 | Effect-4 Depth（Celeste / Detune 音准加宽） |
| GM2 | **未作强制定义**（GM2 只规范 91、93） |
| Roland GS | Delay Send Level（延迟发送量） |
| Yamaha XG | Variation Effect Send Level |

> 本项目需要延迟发送量，**拟沿用 GS 惯例使用 CC94，并在实现中写明该约定**。

#### 复位（CC121）
CC121（Reset All Controllers）用于把控制器恢复到默认值。

**重要例外：以下内容不会被 CC121 复位**
- Program Change
- Bank Select（CC0 / CC32）
- Channel Volume（CC7）
- Pan（CC10）
- Portamento Time（CC5）
- Reverb Send（CC91）
- Chorus Send（CC93）

→ 演奏中的音量与发送量不会被 CC121 清掉。

#### 14 位配对
单个 CC 的数据只有 7 位（128 级），精度不够时用**两个 CC 拼成 14 位**（16384 级）。

**配对规则：**

```
CC 0–31   = MSB（高位 / 粗调）
CC 32–63  = LSB（低位 / 细调）

对应关系：LSB 号 = MSB 号 + 32
合成公式：值 = MSB × 128 + LSB
```

**常见配对表：**

| MSB | 名称 | LSB |
|---|---|---|
| 0 | Bank Select | 32 |
| 1 | Modulation | 33 |
| 2 | Breath | 34 |
| 4 | Foot | 36 |
| 5 | Portamento Time | 37 |
| 6 | Data Entry | 38 |
| 7 | Channel Volume | 39 |
| 8 | Balance | 40 |
| 10 | Pan | 42 |
| 11 | Expression | 43 |
| 12 / 13 | Effect Control 1 / 2 | 44 / 45 |

> 注意 **CC10（声像）的 LSB 是 42**，不是 43。

**重要：三处的高低位顺序不一致**

| 项目 | 字节顺序 |
|---|---|
| 14 位 CC 配对 | **先 MSB 后 LSB**（如先 CC0 再 CC32） |
| Pitch Bend | **先 LSB 后 MSB**（`En ll mm`） |
| RPN / NRPN 数据 | **先 MSB 后 LSB**（先 CC6 再 CC38） |

> 实现时极易搞反，需特别注意。

> 另：**CC64 及以上是单字节 7 位控制器，没有 LSB 配对**。只有 CC0–31 参与配对。

#### 其他
以下为已知但**尚未讨论清楚**的内容，此处仅记录，待后续确认。

**（1）RPN / NRPN（CC 98–101 + CC6）**
用 CC98–101 选择参数号，再用 CC6 赋值：

```
Bn 65 00   Bn 64 00   Bn 06 vv
   ↑CC101      ↑CC100     ↑CC6
   RPN MSB     RPN LSB     数据
```

常用 RPN：

| RPN (MSB, LSB) | 含义 |
|---|---|
| 0, 0 | 弯音范围（Pitch Bend Sensitivity，单位半音） |
| 0, 1 | 微调（Fine Tuning） |
| 0, 2 | 粗调（Coarse Tuning） |
| 0, 5 | 调制深度范围 |
| 127, 127 | RPN 空（终止） |

> 本项目目前只用到 **RPN 0,0（弯音范围）**。
> GM2 另有一组 NRPN 用于音源编辑（鼓件音高、滤波、包络等），**尚未逐条核实**，需要时再查规范原文。

**（2）通道模式消息（CC 120–127）**
All Sound Off / Reset All Controllers / All Notes Off / Omni / Mono / Poly 等。**本项目是否实现尚未确定。**

**（3）GS / XG 厂商扩展**
Roland GS 与 Yamaha XG 对部分 CC（92、94 等）的定义与 GM 不同。**本项目默认不实现厂商扩展。**

---
## 四、音色库选择（Bank Select）

### 原理
MIDI 的 CC 只有 7 位数据，单靠 Program Change 只能选 128 个音色。为扩展寻址空间，规范把两个未使用的控制器号定义为「音色库选择」：

| 控制器 | 名称 | 作用 |
|---|---|---|
| CC0 | Bank Select MSB | 库号的**高 7 位** |
| CC32 | Bank Select LSB | 库号的**低 7 位** |

**合并算法：**

```
Bank = CC0 × 128 + CC32

取值范围：0 – 16383（共 16384 个库）
总寻址空间：16384 × 128 = 2,097,152 个音色位置
```

### 注意事项
**三条必须遵守的行为：**

1. **发送顺序固定**：`CC0 → CC32 → Program Change`，中间**不能插入**其他消息（尤其别的 Program Change）
2. **单独发送 Bank Select 不立即生效**：库号会「挂起」，直到下一个 Program Change 到达才一起生效
3. **Bank Select 不改变正在发声的音符**

**对本项目的直接影响：**
- 因为第 2 条，接收方（FPGA）必须把 `bank_msb` / `bank_lsb` 作为**待用值**缓存，收到 Program Change 时才一起生效
- 因为第 3 条，音色切换是「**新音起效**」语义（与 GM2 对 Program Change 的规定一致）

### 关于鼓
鼓通道的音色选择机制与普通通道**不同**，可视为音色库选择的一个特殊应用。

**与普通通道的区别**

| | 普通通道 | 鼓通道 |
|---|---|---|
| `note` 决定 | 音高 | **哪一个乐器** |
| `program` 决定 | 音色 | **哪一套鼓组** |

**鼓组选择：Bank MSB = 120**

```
CC0（Bank MSB）= 120（0x78）   →   进入鼓组库
CC32（Bank LSB）= 0
Program Change  = 鼓组号
```

| 鼓组 | Program |
|---|---|
| Standard | 0 |
| Room | 8 |
| Power | 16 |
| Electronic | 24 |

**鼓音符映射（部分）**

| 音符号 | 乐器 |
|---|---|
| 35 | Acoustic Bass Drum |
| 36 | Bass Drum 1 |
| 38 | Acoustic Snare |
| 39 | Hand Clap |
| 42 | Closed Hi-Hat |
| 44 | Pedal Hi-Hat |
| 46 | Open Hi-Hat |
| 49 | Crash Cymbal 1 |
| 51 | Ride Cymbal 1 |

> GM1 覆盖音符号 35–81，GM2 扩展到 27–87。

**两条特殊行为**

1. **Note Off 被忽略**：打击乐是固定时长的，音符长度由音色自身的包络决定
2. **镲互斥**：42 / 44 / 46（闭镲 / 踩镲 / 开镲）三者互斥，敲击其中一个须立刻静掉另外两个

**鼓通道上无效的 CC**

| CC | 说明 |
|---|---|
| 5 | Portamento Time |
| 64 / 65 / 66 / 67 | 各类踏板 |
| 71 / 72 / 73 / 74 | 谐振 / 释音 / 起音 / 亮度 |
| 84 | Portamento Control |

> 鼓件的独立调节（音高、声像、滤波等）在 GM2 中由 NRPN 实现，不在 CC 范围内。
>
> 对本项目：技术文档中以 **`bank MSB = 120`** 作为鼓通道的判定依据。

### 示例
**场景**：在通道 1 选择「库 120、音色 16」。

| 步骤 | 消息 | 含义 |
|---|---|---|
| 1 | `B0 00 78` | CC0（Bank MSB）= 120（0x78） |
| 2 | `B0 20 00` | CC32（Bank LSB）= 0 |
| 3 | `C0 10` | Program Change = 16 |

二进制展开：

```
B0 00 78    1011 0000 · 0000 0000 · 0111 1000
B0 20 00    1011 0000 · 0010 0000 · 0000 0000
C0 10       1100 0000 · 0001 0000
```

**注意**：三条消息必须按此顺序、连续发送。若在第 1、2 条之后插入了其他 Program Change，会选到错误的音色。

> 本项目音色数远小于 128，**16384 个库远用不完**。`bank` 的实际用途是区分**音色集合**（如「基础音色库」/「自定义音色库」），只需 2~3 个取值。

---
## 五、General MIDI

### GM 简介
**GM（General MIDI）是 MIDI 协会制定的推荐规范（Recommended Practice），不是硬件标准。**

它解决的问题是：MIDI 只规定了「传输什么」，没规定「收到后发出什么声音」。所以同一份 MIDI 文件在不同设备上，0 号音色可能是钢琴、也可能是长笛。

GM 通过**固定音色与鼓组的位置**来统一播放结果，使**同一份 MIDI 文件在任何 GM 设备上播放结果一致**。

### GM1
发布于 1991 年。

- **128 个音色固定位置**（0 = Acoustic Grand Piano，40 = Violin 等）
- 16 个 MIDI 通道，**通道 10 固定为鼓组**
- 规定最低复音数
- 规定必须响应的控制器：CC1、CC7、CC10、CC11、CC64、CC120、CC121、CC123 等
- System On 消息：`F0 7E 7F 09 01 F7`

### GM2
发布于 1999 年，文档号 RP-024。在 GM1 基础上扩展：

| 项目 | GM1 | GM2 |
|---|---|---|
| 音色 | 128 固定 | 增加变奏库、多鼓组 |
| 鼓通道 | 通道 10 | 通道 10（可另加通道 11） |
| 必需 CC | 1 / 7 / 10 / 11 / 64 等 | **追加 71 / 72 / 73 / 74 / 84 / 91 / 93** |
| 效果 | 无要求 | **必须有 1 个混响 + 1 个合唱**，每通道独立发送量 |
| 效果联动 | — | 必须提供 **Chorus → Reverb 发送** |
| 全局控制 | — | 通用 SysEx 主音量、全局参数控制 |
| System On | `F0 7E 7F 09 01 F7` | `F0 7E 7F 09 03 F7` |

**GM2 效果默认值**：混响类型默认 `0x04`（Large Hall）；合唱类型默认 `0x02`（Chorus 3）。

### Program Change 规定
GM2 规范原文：

> *Currently sounding Notes shall not be released or muted when a Program Change is received.*

**收到 Program Change 时，正在发声的音符不应被释放或静音。**

→ 即音色切换为「**新音起效**」：新音色只对之后按下的音符生效，正在响的音保持原音色。

> **这不是自选策略，而是 GM2 的明文要求**，可作为设计合规性依据。

---
## 六、SysEx

### 格式
**SysEx（System Exclusive）是厂商自定义消息**，用于传输标准 CC 与状态字节无法表达的内容。

结构：

```
F0  <厂商 ID / 通用 ID>  <数据…>  F7
│                          │      └─ F7 = EOX，结束
│                          └──────── 数据字节
└─────────────────────────────────── F0 = SysEx 开始
```

通用 SysEx 由第二个字节区分类型：

| 第二字节 | 类型 |
|---|---|
| `7E` | Universal Non-Real-Time |
| `7F` | Universal Real-Time |

> 消息总长度可变，由 `F7` 界定结束。

### 主音量调节
**MIDI 中没有任何标准 CC 用于控制主音量，只有这条 SysEx。**

```
F0 7F <device ID> 04 01 ll mm F7
│  │  │           │  │  │  │  └─ F7 = EOX 结束
│  │  │           │  │  │  └──── mm = 音量 MSB（高 7 位）
│  │  │           │  │  └─────── ll = 音量 LSB（低 7 位）
│  │  │           │  └────────── 01 = Master Volume
│  │  │           └───────────── 04 = Device Control Message
│  │  └───────────────────────── device ID（7F = 广播所有设备；00–1F = 指定设备）
│  └──────────────────────────── 7F = Universal Real-Time SysEx
└─────────────────────────────── F0 = SysEx 开始
```

- 音量为 **14 位**：`ll` 为低 7 位、`mm` 为高 7 位，合计 0–16383
- 广播给所有设备时 device ID 填 `7F`

**示例：**

| 目标 | 消息 | 二进制 |
|---|---|---|
| 最大音量 | `F0 7F 7F 04 01 7F 7F F7` | `1111 0000 · 0111 1111 · 0111 1111 · 0000 0100 · 0000 0001 · 0111 1111 · 0111 1111 · 1111 0111` |
| 约 50% | `F0 7F 7F 04 01 00 40 F7` | `… · 0000 0000 · 0100 0000 · …` |
| 静音 | `F0 7F 7F 04 01 00 00 F7` | `… · 0000 0000 · 0000 0000 · …` |

> 标准中与音量相关的 CC 都是**每通道**的：CC7（通道音量，另有 CC39 作 LSB 构成 14 位）、CC11（表情）。

---
## 参考来源

| 文档 | 链接 |
|---|---|
| GM2 规范（RP-024，英文版） | https://amei.or.jp/midistandardcommittee/Recommended_Practice/e/GM2-v12a.pdf |
| GM2 规范（日文版） | https://amei.or.jp/midistandardcommittee/Recommended_Practice/GM2_japanese.pdf |
| GM2 Guidebook | http://www.amei.or.jp/specifications/GM2Guidebook.pdf |
| CA-24（GM2 通用 Real-Time SysEx 推荐做法） | https://amei.or.jp/midistandardcommittee/Recommended_Practice/e/ca24.pdf |
| MIDI 协会官网 | https://midi.org/ |

> 以上链接来自公开检索结果。MIDI 1.0 详细规范（含完整 CC 定义）由 MIDI Association 发布，需要完整原文时可从 midi.org 获取。
