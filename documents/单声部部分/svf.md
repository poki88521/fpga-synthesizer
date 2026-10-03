
# SVF 模块技术文档

**适用平台：高云 GW5A-138K**

**系统时钟：50 MHz**

**音频采样率：约 48 kHz**

**文档版本：v1.0**

---

## 一、模块功能

SVF（状态变量滤波器）对 DDS 输出的波形进行频域塑形。

采用 Chamberlin 数字结构，同时提供低通、带通、高通三种输出。截止频率和共振可独立调节。

---

## 二、原理与公式

### 2.1 差分方程

每采样周期依次执行：

```
low  = low + f × band
high = input - low - q × band
band = band + f × high
```

- `input`：输入信号（来自 DDS）
- `low`：低通输出
- `band`：带通输出
- `high`：高通输出
- `f`：频率系数，决定截止频率
- `q`：阻尼系数，决定共振强度

### 2.2 系数计算

频率系数：

```
f = 2 × sin(π × fc / fs)
```

其中 `fc` 为目标截止频率，`fs` 为采样率（约 48 kHz）。

阻尼系数：

```
q = 1 / Q
```

`Q` 为品质因数。`q` 越小，共振越强。

### 2.3 Q1.15 定点格式

`f` 和 `q` 均用 Q1.15 格式表示：16 位中 1 位符号 + 15 位小数，数值 `x` 代表 `x / 32768`。

| 小数 | 整数（十进制） | 整数（十六进制） |
|---|---|---|
| 1.0 | 32768 | 8000 |
| 0.5 | 16384 | 4000 |
| 0.25 | 8192 | 2000 |
| 0.1 | 3277 | 0CCD |

---

## 三、接口定义

| 信号 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `clk` | 输入 | 1 | 系统时钟 |
| `rst_n` | 输入 | 1 | 低电平复位 |
| `sample_en` | 输入 | 1 | 采样使能 |
| `audio_in` | 输入 | 16 | 来自 DDS，有符号 |
| `f_coeff` | 输入 | 16 | 频率系数，Q1.15 |
| `q_coeff` | 输入 | 16 | 阻尼系数，Q1.15 |
| `filter_type` | 输入 | 2 | 0=LP, 1=BP, 2=HP |
| `audio_out` | 输出 | 16 | 送往 VCA，有符号 |

---

## 四、参数来源

| 参数 | 来源表 | 字段 |
|---|---|---|
| 滤波器类型 | 音色参数表 | `filter_type` |
| 基准截止频率 | 音色参数表 | `filter_cutoff` |
| 基准谐振 | 音色参数表 | `filter_resonance` |
| 包络调制深度 | 音色参数表 | `filter_env_depth` |
| LFO 调制深度 | 音色参数表 | `filter_lfo_depth` |
| 截止频率调制 | 通道状态表 | `filter_cutoff_mod` |
| 谐振调制 | 通道状态表 | `resonance_mod` |
| 包络值 | 声部状态表 | `env_value` |
| LFO 输出 | LFO 模块 | `lfo_out` |

截止频率合成：

```
effective_fc = filter_cutoff
             + filter_env_depth × env_value
             + filter_lfo_depth × lfo_out
             + filter_cutoff_mod
```

然后由 `effective_fc` 计算 `f`。

---

## 五、内部状态

`filter_ic1`（对应 `low`）和 `filter_ic2`（对应 `band`）存储在声部状态表中，逐采样更新。

使用 **24 位有符号数**防止溢出。

---

## 六、关键代码

```verilog
module svf_voice (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_en,
    input  wire signed [15:0] audio_in,
    input  wire [15:0] f_coeff,
    input  wire [15:0] q_coeff,
    input  wire [1:0]  filter_type,
    output reg  signed [15:0] audio_out
);

    reg signed [31:0] low;
    reg signed [31:0] band;
    reg signed [31:0] high;

    wire signed [31:0] f_ext = {{16{f_coeff[15]}}, f_coeff};
    wire signed [31:0] q_ext = {{16{q_coeff[15]}}, q_coeff};
    wire signed [31:0] in_ext = {{16{audio_in[15]}}, audio_in};

    wire signed [31:0] f_band = (f_ext * band) >>> 15;
    wire signed [31:0] q_band = (q_ext * band) >>> 15;
    wire signed [31:0] f_high = (f_ext * high) >>> 15;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            low  <= 32'sd0;
            band <= 32'sd0;
            high <= 32'sd0;
        end else if (sample_en) begin
            low  <= low + f_band;
            high <= in_ext - low - q_band;
            band <= band + f_high;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            audio_out <= 16'sd0;
        else if (sample_en) begin
            case (filter_type)
                2'd0: audio_out <= low[30:15];
                2'd1: audio_out <= band[30:15];
                2'd2: audio_out <= high[30:15];
                default: audio_out <= low[30:15];
            endcase
        end
    end

endmodule
```

---

## 七、移植步骤

1. 确定系数计算方式：推荐查找表，预先算好 128 个频点的 `f` 值存入 ROM。
2. 例化 SVF 逻辑，按差分方程实现。
3. 连接状态变量：从声部状态表读 `filter_ic1`、`filter_ic2`，更新后写回。
4. 连接参数：从音色参数表、通道状态表、LFO 模块读取调制参数。
5. 根据 `filter_type` 选择输出。

---

## 八、注意事项

- 内部状态必须用 24 位以上有符号数，16 位会溢出。
- 截止频率较高时（> 5 kHz）必须用完整 sin 公式，不能用线性近似。
- `q` 越小共振越强，注意限制范围防止自激。
- 滤波器状态建立需要时间，快速切换截止频率时可能有瞬态。

---

**文档结束**
