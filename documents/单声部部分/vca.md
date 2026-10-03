

# ADSR 包络模块技术文档

**适用平台：高云 GW5A-138K**

**系统时钟：50 MHz**

**音频采样率：约 48 kHz**

**文档版本：v1.0**

---

## 一、模块功能

ADSR 包络发生器产生随时间变化的音量包络值 `env_value`，送给 VCA 模块与音频样本相乘，控制音符的音量变化。

ADSR 包含五个状态：IDLE、ATTACK、DECAY、SUSTAIN、RELEASE。

当前暂不接入力度，`velocity_gain` 使用默认值。后续加入力度时只需在声部分配阶段计算，ADSR 核心逻辑不变。

---

## 二、五个状态的作用

| 状态 | 作用 | 对最终效果的影响 |
|---|---|---|
| IDLE | 等待按键，静音 | 无按键时不出声 |
| ATTACK | 音量从 0 升到最大 | 决定声音“出现”的快慢 |
| DECAY | 音量从最大降到 Sustain | 决定声音“变弱”的快慢 |
| SUSTAIN | 按住时保持的电平 | 决定持续音的大小 |
| RELEASE | 松开后音量降到 0 | 决定声音“消失”的快慢 |

### 2.1 ATTACK

- 每个采样周期 `env_value += attack_step`
- 到达 65535 后进入 DECAY
- `attack_step` 大 → 上升快 → 声音突然出现
- `attack_step` 小 → 上升慢 → 声音渐渐浮现

### 2.2 DECAY

- 每个采样周期 `env_value -= decay_step`
- 降到 `sustain_level` 后进入 SUSTAIN
- `decay_step` 大 → 下降快
- `sustain_level` 决定衰减后剩余音量

### 2.3 SUSTAIN

- `env_value` 保持 `sustain_level`
- `sustain_level` 高 → 按住时声音大
- `sustain_level` 低 → 按住时声音小
- `sustain_level = 0` → 按住也没有持续音

### 2.4 RELEASE

- 每个采样周期 `env_value -= release_step`
- 降到 0 后回到 IDLE
- `release_step` 大 → 松开后快速消失
- `release_step` 小 → 松开后慢慢消失

---

## 三、参数来源

| 参数 | 来源表 | 字段 |
|---|---|---|
| Attack 时间 | 音色参数表 | `adsr_attack` |
| Decay 时间 | 音色参数表 | `adsr_decay` |
| Sustain 电平 | 音色参数表 | `adsr_sustain` |
| Release 时间 | 音色参数表 | `adsr_release` |
| 包络曲线 | 音色参数表 | `adsr_curve` |
| Attack 调制 | 通道状态表 | `attack_mod` |
| Release 调制 | 通道状态表 | `release_mod` |
| 延音踏板 | 通道状态表 | `sustain_pedal` |
| 按键状态 | 声部状态表 | `gate` |
| 待释放标记 | 声部状态表 | `pending_release` |

时间参数换算为每采样步进值：

```
attack_step = 65536 / (adsr_attack × fs)
```

例如 `adsr_attack = 10 ms`，`fs = 48000`：

```
attack_step = 65536 / (0.01 × 48000) ≈ 137
```

---

## 四、接口定义

| 信号 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `clk` | 输入 | 1 | 系统时钟 |
| `rst_n` | 输入 | 1 | 低电平复位 |
| `sample_en` | 输入 | 1 | 采样使能 |
| `gate` | 输入 | 1 | 按键按下时 = 1 |
| `attack_step` | 输入 | 16 | Attack 每采样增量 |
| `decay_step` | 输入 | 16 | Decay 每采样减量 |
| `sustain_level` | 输入 | 16 | Sustain 目标电平 |
| `release_step` | 输入 | 16 | Release 每采样减量 |
| `env_value` | 输出 | 16 | 当前包络值 |
| `env_state` | 输出 | 3 | 当前状态 |

---

## 五、关键代码

```verilog
module adsr_env (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_en,
    input  wire        gate,
    input  wire [15:0] attack_step,
    input  wire [15:0] decay_step,
    input  wire [15:0] sustain_level,
    input  wire [15:0] release_step,
    output reg  [15:0] env_value,
    output reg  [2:0]  env_state
);

    localparam IDLE    = 3'd0;
    localparam ATTACK  = 3'd1;
    localparam DECAY   = 3'd2;
    localparam SUSTAIN = 3'd3;
    localparam RELEASE = 3'd4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            env_value <= 16'd0;
            env_state <= IDLE;
        end else if (sample_en) begin
            case (env_state)
                IDLE: begin
                    env_value <= 16'd0;
                    if (gate)
                        env_state <= ATTACK;
                end
                ATTACK: begin
                    if (env_value + attack_step >= 16'hFFFF) begin
                        env_value <= 16'hFFFF;
                        env_state <= DECAY;
                    end else begin
                        env_value <= env_value + attack_step;
                    end
                end
                DECAY: begin
                    if (env_value <= sustain_level + decay_step) begin
                        env_value <= sustain_level;
                        env_state <= SUSTAIN;
                    end else begin
                        env_value <= env_value - decay_step;
                    end
                end
                SUSTAIN: begin
                    env_value <= sustain_level;
                    if (!gate)
                        env_state <= RELEASE;
                end
                RELEASE: begin
                    if (env_value <= release_step) begin
                        env_value <= 16'd0;
                        env_state <= IDLE;
                    end else begin
                        env_value <= env_value - release_step;
                    end
                end
                default: env_state <= IDLE;
            endcase
        end
    end

endmodule
```

---

## 六、不同音色的 ADSR 典型值

| 音色 | Attack | Decay | Sustain | Release | 物理原因 |
|---|---|---|---|---|---|
| 钢琴 | 较长（~125 ms） | 中等 | 低（0.2~0.4） | 中等 | 琴槌击弦后能量持续衰减 |
| 吉他 | 极短（< 30 ms） | 短 | 极低 | 短 | 拨弦瞬间注入能量 |
| 贝斯 | 短 | 中等 | 中 | 短 | 拨弦+琴体共振 |
| 小提琴 | 中等（50~150 ms） | 短 | 高（0.8~1.0） | 中等 | 弓持续摩擦弦 |

参数获取方式：

1. SoundFont 提取：`.sf2` 文件中每个乐器携带音量包络发生器值。
2. 合成器手册：Roland、Yamaha 等厂商设备说明书。
3. 实测分析：对真实乐器录音，在音频软件中测量包络曲线。
4. 自定义设计：创造非标准音色时自行设定。

---

## 七、力度预留

当前无力度要求，`velocity_gain` 使用默认值（建议 `16'h7FFF`，约等于 0.5）。

预留接口：

- 声部状态表已有 `velocity` 与 `velocity_gain` 字段。
- 音色参数表已有 `vel_sensitivity` 字段。
- 后续加入力度时，在声部分配阶段计算：

```
velocity_gain = f(velocity, vel_sensitivity)
```

写入声部状态表，VCA 直接读取，无需改动 ADSR 核心逻辑。

---

## 八、移植步骤

1. 实现 ADSR 状态机：IDLE → ATTACK → DECAY → SUSTAIN → RELEASE。
2. 时间参数换算：将 `adsr_attack` 等时间参数换算为每采样步进值。
3. 连接状态变量：从声部状态表读 `env_value`、`env_state`，更新后写回。
4. 连接包络参数：从音色参数表、通道状态表读取。
5. 力度预留：`velocity_gain` 当前接默认值，后续接入计算逻辑。

---

## 九、注意事项

- 包络曲线 `adsr_curve` 可选线性或指数，指数更接近真实乐器。
- 时间参数换算时注意整数除法精度，可用移位近似。
- 延音踏板 `sustain_pedal` 影响 RELEASE 状态转移。
- 力度当前为默认值，预留字段，后续接入无需改动 ADSR 核心。

---

**文档结束**