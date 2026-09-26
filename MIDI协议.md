## 传输结构
- 波特率31250，传输字节10位：起始1位（为0） + 数据8位 + 终止1位（为1）
- 数据字节8位，分为状态字节（首位为1）和数据字节（首位为0）
- 整体结构通常为：1状态字节 + 1~2数据字节

## 数据表格
系统消息（不包含通道号，适用于整个系统）的状态字节、数据字节数和数据结构如下。

| 状态字节 | 含义 | 数据字节数 | 数据结构 |
|---|---|---|---|
| `0xF0` | SysEx 开始 | 可变 | 厂商 ID + 数据字节… + `0xF7` |
| `0xF1` | MTC Quarter Frame | 1 | 数据字节（0–127） |
| `0xF2` | Song Position Pointer | 2 | LSB, MSB（14 位） |
| `0xF3` | Song Select | 1 | 歌曲号（0–127） |
| `0xF4` | Undefined | 0 | — |
| `0xF5` | Undefined | 0 | — |
| `0xF6` | Tune Request | 0 | — |
| `0xF7` | EOX / SysEx 结束 | 0 | — |
| `0xF8` | Timing Clock | 0 | — |
| `0xF9` | Undefined | 0 | — |
| `0xFA` | Start | 0 | — |
| `0xFB` | Continue | 0 | — |
| `0xFC` | Stop | 0 | — |
| `0xFD` | Undefined | 0 | — |
| `0xFE` | Active Sensing | 0 | — |
| `0xFF` | System Reset | 0 | — |

所有状态字节的含义、数据字节数和数据结构如下；`n` 表示通道号 0–F。

| 状态字节   | 含义                      | 数据字节数 | 数据结构                                      |
| ------ | ----------------------- | ----- | ----------------------------------------- |
| `0x8n` | Note Off                | 2     | 音符号（0–127）, 释放力度（0–127）                   |
| `0x9n` | Note On                 | 2     | 音符号（0–127）, 力度（0–127）；力度 0 等价 Note Off    |
| `0xAn` | Polyphonic Key Pressure | 2     | 音符号（0–127）, 压力值（0–127）                    |
| `0xBn` | Control Change          | 2     | 控制器号（0–127）, 控制器值（0–127）；CC 122–127 为通道模式 |
| `0xCn` | Program Change          | 1     | 音色号（0–127）                                |
| `0xDn` | Channel Pressure        | 1     | 压力值（0–127）                                |
| `0xEn` | Pitch Bend Change       | 2     | LSB, MSB；14 位，中心值 8192                    |

---

# Control Change（CC）详解

## CC 是什么

**CC = Control Change（控制变更）**，是 MIDI 中用于「连续调节类」参数的消息类型，区别于 Note On/Off 这类「事件类」消息。

**字节结构**（3 字节）：

```
Bn  CC号  值
│   │     └─ 0–127，控制器值
│   └─────── 0–127，控制器号
└─────────── B = 状态字节前缀；n = 通道号 0–F
```

例：通道 1 设置声像居中 → `B0 0A 40`（`0x0A` = 10 = 声像，`0x40` = 64 = 中间值）

**要点：**

- 控制器号和值都只有 **7 位（0–127）**，这是 MIDI 只用 1 字节传数据的限制
- 需要更高精度时，规范用**两个 CC 拼成 14 位**（MSB + LSB 机制），如 CC7 + CC39
- 控制器号共 **128 个**，含义由 MIDI 规范分配（见下表）

## CC 号对照表（MIDI 1.0 标准定义）

| CC | 名称 | 说明 | 本项目落点 |
|---|---|---|---|
| 0 | Bank Select MSB | 音色库号高 7 位 | 通道表 `bank_msb` |
| 1 | Modulation Wheel | 调制轮 | 通道表 `mod_wheel` |
| 2 | Breath Controller | 呼吸控制器 | — |
| 4 | Foot Controller | 脚踏控制器 | — |
| 5 | Portamento Time | 滑音时间 | — |
| 6 | Data Entry MSB | 数据输入高字节（配合 RPN/NRPN） | — |
| 7 | Channel Volume | 通道音量 | 通道表 `volume` |
| 8 | Balance | 左右平衡 | — |
| 10 | Pan | 声像 0–127（64 = 居中） | 通道表 `pan` |
| 11 | Expression | 表情（与 CC7 相乘） | 通道表 `expression` |
| 12 | Effect Control 1 | 效果控制 1 | — |
| 13 | Effect Control 2 | 效果控制 2 | — |
| 16–19 | General Purpose Controller 1–4 | 通用控制器 | — |
| 32 | Bank Select LSB | 音色库号低 7 位 | 通道表 `bank_lsb` |
| 33–63 | LSB for CC 1–31 | 上述控制器的低字节 | — |
| 64 | Damper / Sustain Pedal | 延音踏板 | 通道表 `sustain_pedal` |
| 65 | Portamento On/Off | 滑音开关 | — |
| 66 | Sostenuto | 持音踏板 | 通道表 `sostenuto_pedal` |
| 67 | Soft Pedal | 弱音踏板 | 通道表 `soft_pedal` |
| 68 | Legato Footswitch | 连奏开关 | — |
| 69 | Hold 2 | 保持 2 | — |
| 70 | Sound Controller 1 | 音色变化 | — |
| 71 | Sound Controller 2 | **谐振 / 音色亮度** | 通道表 `resonance_mod` |
| 72 | Sound Controller 3 | **释音时间** | 通道表 `release_mod` |
| 73 | Sound Controller 4 | **起音时间** | 通道表 `attack_mod` |
| 74 | Sound Controller 5 | **亮度 / 截止频率** | 通道表 `filter_cutoff_mod` |
| 75 | Sound Controller 6 | Decay 时间 | — |
| 76 | Sound Controller 7 | 颤音速率 | — |
| 77 | Sound Controller 8 | 颤音深度 | 关联 `vibrato_depth` |
| 78 | Sound Controller 9 | 颤音延迟 | — |
| 79 | Sound Controller 10 | 音色控制 10 | — |
| 80–83 | General Purpose Controller 5–8 | 通用控制器 | — |
| 84 | Portamento Control | 滑音控制 | — |
| 88 | High Resolution Velocity Prefix | 高清力度前缀（较新规范追加） | — |
| 91 | Effect 1 Depth | **混响发送量**（GM2） | 通道表（发送量） |
| 92 | Effect 2 Depth | 颤音深度（GM1）/ GM2 未强制 | — |
| 93 | Effect 3 Depth | **合唱发送量**（GM2） | 通道表（发送量） |
| 94 | Effect 4 Depth | 依标准而异（见下） | 待定 |
| 95 | Effect 5 Depth | 效果 5 深度 | — |
| 96 | Data Increment | 数据递增（配合 RPN/NRPN） | — |
| 97 | Data Decrement | 数据递减 | — |
| 98 | NRPN LSB | 非注册参数号低字节 | — |
| 99 | NRPN MSB | 非注册参数号高字节 | — |
| 100 | RPN LSB | 注册参数号低字节 | RPN 0,0 读取 |
| 101 | RPN MSB | 注册参数号高字节 | RPN 0,0 读取 |
| 120 | All Sound Off | 立即静音（不等释音） | — |
| 121 | Reset All Controllers | 复位所有控制器 | — |
| 122 | Local Control On/Off | 本地控制开关 | — |
| 123 | All Notes Off | 关闭所有音符 | — |
| 124 | Omni Off | 关闭全通道模式 | — |
| 125 | Omni On | 打开全通道模式 | — |
| 126 | Mono Mode On | 单音模式 | — |
| 127 | Poly Mode On | 复音模式（默认） | — |

**未列出的号段（3、9、14–15、20–31、85–87、89–90、102–119）在 MIDI 1.0 中为保留/未定义。**

## CC 中需要特别注意的几个

### CC0 / CC32 —— 音色库选择（Bank Select）

见下文「音色库选择机制」章节。

### CC91 / CC93 —— 效果发送量（GM2 必需）

| CC | 名称 | 说明 |
|---|---|---|
| 91 | Reverb Send Level | 混响发送量。响应曲线相对幅度**线性**，**值 127 = 发送量 100%** |
| 93 | Chorus Send Level | 合唱发送量。值 127 = 最大发送 |

- GM2 规范中将二者列为**必需控制器**（`[required]`）
- GM2 默认值：CC91 = **40（0x28）**；CC93 默认通常为 0
- GM1 中称 Effect-1/Effect-3 Depth，功能相同

### CC94 —— 含义依标准而异

| 标准 | CC94 含义 |
|---|---|
| MIDI 1.0 早期 / GM1 | Effect-4 Depth（Celeste / Detune 音准加宽） |
| **GM2** | **未作强制定义**（GM2 只规范 91、93） |
| Roland **GS** | **Delay Send Level（延迟发送量）** |
| Yamaha **XG** | Variation Effect Send Level |

### CC121 复位行为的例外

CC121（Reset All Controllers）**不会**复位以下控制器：
Program Change、Bank Select（CC0/CC32）、Channel Volume（CC7）、Pan（CC10）、Portamento Time（CC5）、Reverb Send（CC91）、Chorus Send（CC93）。

→ 演奏中的发送量与音量不会被 CC121 清掉。

### RPN / NRPN（CC 98–101 + CC6）

CC 98–101 用于选择「注册参数（RPN）」或「非注册参数（NRPN）」，再用 CC6（数据输入）赋值：

```
Bn 65 00   Bn 64 00   Bn 06 vv    →  RPN 0,0（弯音范围）= vv
↑CC101 MSB  ↑CC100 LSB  ↑CC6 数据
```

**常用 RPN：**

| RPN (MSB,LSB) | 含义 |
|---|---|
| 0, 0 | 弯音范围（Pitch Bend Sensitivity，单位半音） |
| 0, 1 | 微调（Fine Tuning） |
| 0, 2 | 粗调（Coarse Tuning） |
| 0, 5 | 调制深度范围 |
| 127, 127 | RPN 空（终止） |

**GM2 另定义了一组 NRPN 用于音源编辑（颤音、滤波、包络等），本稿未逐条核实，需要时再查 GM2 规范原文。**

---

# 音色库选择机制（Bank Select）

## 原理

MIDI 的 CC 只有 7 位数据，单靠 Program Change 只能选 128 个音色。为扩展寻址空间，规范把两个未使用的控制器号定义为「音色库选择」：

| 控制器 | 名称 | 作用 |
|---|---|---|
| CC0 | Bank Select MSB | 库号的**高 7 位** |
| CC32 | Bank Select LSB | 库号的**低 7 位** |

**合并算法：**

```
Bank = CC0 × 128 + CC32        取值范围 0–16383（共 16384 个库）
总寻址空间 = 16384 × 128 = 2,097,152 个音色位置
```

## 三条必须遵守的行为

1. **发送顺序固定**：`CC0 → CC32 → Program Change`，中间**不能插入**其他消息（尤其别的 Program Change）
2. **单独发送 Bank Select 不立即生效**：库号会「挂起」，直到下一个 Program Change 到达才一起生效
3. **Bank Select 不改变正在发声的音符**

## GM2 的库号规定

| 用途 | Bank MSB (CC0) | Bank LSB (CC32) |
|---|---|---|
| 基本音色（GM2 128 音色） | **121（0x79）** | **0** |
| 扩展 / 变奏音色 | **121（0x79）** | 1 起 |
| 鼓组 | **120（0x78）** | 0 |
| 鼓组变奏 | **120（0x78）** | 1 起 |

（GM1 兼容音色在很多 GM2 设备上位于 MSB=0 / LSB=0）

**注意：GS（Roland）、XG（Yamaha）、GM2 三套库映射互不通用，CC0/CC32 的具体取值取决于音源型号。**

---

# GM / GM2 规范

## GM = General MIDI

MIDI 协会制定的**推荐规范**（Recommended Practice），不是硬件标准。目的是让**同一份 MIDI 文件在任何 GM 设备上播放结果一致**。

### GM1（1991）

- **128 个音色固定位置**（0 = Acoustic Grand Piano，40 = Violin 等）
- 16 个 MIDI 通道，**通道 10 固定为鼓组**
- 规定最低复音数
- 规定必须响应的控制器：CC1、CC7、CC10、CC11、CC64、CC120、CC121、CC123 等
- 规定 GM System On 消息：`F0 7E 7F 09 01 F7`

### GM2（1999，文档号 RP-024）

在 GM1 基础上扩展：

| 项目 | GM1 | GM2 |
|---|---|---|
| 音色 | 128 固定 | 增加变奏库、多鼓组 |
| 鼓通道 | 通道 10 | 通道 10（可另加通道 11） |
| 必需 CC | 1/7/10/11/64 等 | **追加 71/72/73/74/84/91/93** |
| 效果 | 无要求 | **必须有 1 个混响 + 1 个合唱**，每通道独立发送量 |
| 效果联动 | — | 必须提供 **Chorus → Reverb 发送**（Send to Reverb） |
| 全局控制 | — | 通用 SysEx 主音量、全局参数控制 |
| System On | `F0 7E 7F 09 01 F7` | `F0 7E 7F 09 03 F7` |

**GM2 效果默认值：** 混响类型默认 `0x04`（Large Hall）；合唱类型默认 `0x02`（Chorus 3）。

### GM2 对 Program Change 的规定（重要）

> *Currently sounding Notes shall not be released or muted when a Program Change is received.*

**收到 Program Change 时，正在发声的音符不应被释放或静音。**

→ 即音色切换是「新音起效」语义：新音色只对之后按下的音符生效，正在响的音保持原音色。

---

# 通用 SysEx 消息

## 格式

通用 SysEx 分两类，由 `7E`（Non-Real-Time）和 `7F`（Real-Time）区分：

```
F0 7F <device ID> 04 01 ll mm F7     ← 主音量（Real-Time）
F0 7E 7F 09 03 F7                    ← GM2 System On（Non-Real-Time）
```

## 设备控制类（Sub-ID #1 = 04）

| Sub-ID #2 | 含义 |
|---|---|
| 01 | **Master Volume（主音量）** |
| 02 | Master Balance（主平衡） |
| 03 | Master Fine Tuning（主音分微调） |
| 04 | Master Coarse Tuning（主粗调，半音为单位） |
| 05 | Global Parameter Control（全局参数控制，GM2 用它控制全局效果参数） |

## 主音量 SysEx 详解

```
F0 7F <device ID> 04 01 ll mm F7
│  │  │           │  │  │  │  └─ F7 = EOX 结束
│  │  │           │  │  │  └──── mm = 音量 MSB（高 7 位）
│  │  │           │  │  └─────── ll = 音量 LSB（低 7 位）
│  │  │           │  └────────── 01 = Master Volume
│  │  │           └───────────── 04 = Device Control Message
│  │  └───────────────────────── device ID（7F = 广播给所有设备；00–1F = 指定设备）
│  └──────────────────────────── 7F = Universal Real-Time SysEx
└─────────────────────────────── F0 = SysEx 开始
```

- 音量是 **14 位**：`ll` 为低 7 位、`mm` 为高 7 位，合计 0–16383
- `F0 7F 7F 04 01 7F 7F F7` → 最大音量
- `F0 7F 7F 04 01 00 40 F7` → 约 50%
- `F0 7F 7F 04 01 00 00 F7` → 静音

**关键结论：MIDI 中没有任何标准 CC 用于控制主音量，只有这条 SysEx。**

标准里与音量相关的 CC 都是**每通道**的：CC7（通道音量，另有 CC39 作 LSB 构成 14 位）、CC11（表情）。

---

# 与本项目相关的要点汇总

| # | 要点 | 说明 |
|---|---|---|
| 1 | **Program Change 采用「新音起效」** | GM2 规范明文要求，非自选，可据此说明设计合规 |
| 2 | **发送量归通道表** | CC91/93 本就是通道级控制器；CC94 需自定语义（建议沿用 GS 的延迟发送） |
| 3 | **音色库用 CC0/CC32** | 本项目音色数远小于 128，bank 的实际用途是区分「基础音色库 / 自定义音色库」 |
| 4 | **Bank Select 需缓存** | 因「单独发送不生效」，FPGA 侧须把 `bank_msb`/`bank_lsb` 作为待用值，收到 PC 时才一起生效 |
| 5 | **效果内部参数无标准 CC** | 混响衰减、合唱速率、延迟时间等只能靠 SysEx（GM2 Global Parameter Control）或自定义途径 |
| 6 | **主音量只有 SysEx 途径** | 限幅、抖动等参数无标准，需自定义 |
| 7 | **鼓组暂忽略但需预留** | 通道 10 固定鼓组；鼓组内每个音符号对应不同打击乐音色（同通道多音色的极端情形） |
| 8 | **CC121 不复位音量与发送量** | 实现复位功能时需注意这一例外 |

---

# 参考来源

| 文档 | 链接 |
|---|---|
| GM2 规范（RP-024，英文版） | https://amei.or.jp/midistandardcommittee/Recommended_Practice/e/GM2-v12a.pdf |
| GM2 规范（日文版） | https://amei.or.jp/midistandardcommittee/Recommended_Practice/GM2_japanese.pdf |
| GM2 Guidebook | http://www.amei.or.jp/specifications/GM2Guidebook.pdf |
| CA-24：GM2 通用 Real-Time SysEx 推荐做法 | https://amei.or.jp/midistandardcommittee/Recommended_Practice/e/ca24.pdf |
| MIDI 协会官网 | https://midi.org/ |

> 说明：以上链接来自公开检索结果，其中 AMEI（日本电子乐器协会）网站托管了 MIDI 协会的推荐做法文档。MIDI 1.0 详细规范（含完整 CC 定义）由 MIDI Association 发布，需要完整原文时可从 midi.org 获取。

