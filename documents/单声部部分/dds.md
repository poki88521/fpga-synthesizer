# DDS 模块技术文档

**适用平台：高云 GW5A-138K**

**系统时钟：50 MHz**

**音频采样率：约 48 kHz（每采样周期 1042 个时钟拍）**

**文档版本：v1.0**

---

## 一、模块功能

DDS（直接数字频率合成）模块负责生成原始波形样本。

它通过一个 32 位相位累加器产生连续增长的数字相位，取相位的高 12 位作为波表 ROM 的地址索引，查表输出 16 位有符号波形样本。

输出频率公式：

```
f_out = phase_inc × f_s / 2^32
```

其中：

- `phase_inc`：32 位频率控制字
- `f_s`：音频采样率，约 48 kHz

---

## 二、接口定义

| 信号 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `clk` | 输入 | 1 | 系统时钟 50 MHz |
| `rst_n` | 输入 | 1 | 低电平复位 |
| `sample_en` | 输入 | 1 | 采样使能脉冲，每 1042 拍一个 |
| `phase_inc` | 输入 | 32 | 频率控制字 |
| `wave_sel` | 输入 | 2 | 音色选择，0~3 |
| `phase_acc` | 输出 | 32 | 相位累加器当前值，写回声部状态表 |
| `wave_out` | 输出 | 16 | 波形样本，送往 SVF |

---

## 三、参数来源

| 参数 | 来源表 | 字段 |
|---|---|---|
| 频率控制字 | 声部状态表 | `phase_inc` |
| 主波表索引 | 音色参数表 | `wave_main` |
| 辅助波表索引 | 音色参数表 | `wave_aux` |
| 主/辅混合比例 | 音色参数表 | `wave_mix` |

当前仅使用 `wave_main` 的低 2 位作为 `wave_sel`，支持 4 种音色。

---

## 四、波表文件（`.mi`）

波表存储在高云 BSRAM 中，配置为 ROM 模式，初始化文件为 `.mi`（Hex 格式）。

**存储结构**：多个音色连续存放，每个音色一个完整周期 4096 点，每点 16 位有符号补码。

| 音色 | 地址范围 |
|---|---|
| 音色 0 | 0 ~ 4095 |
| 音色 1 | 4096 ~ 8191 |
| 音色 2 | 8192 ~ 12287 |
| 音色 3 | 12288 ~ 16383 |

**`.mi` 文件头部**：

```
#File_format=Hex
#Address_depth=16384
#Data_width=16
```

**ROM 地址拼接**：

```
rom_addr = {wave_sel[1:0], phase_acc[31:20]}
```

- `wave_sel[1:0]`：2 位音色选择
- `phase_acc[31:20]`：12 位相位索引
- 总地址位宽：14 位

---

## 五、实现原理

### 5.1 相位累加器

每个采样周期，相位累加器加上 `phase_inc`：

```
phase_acc <= phase_acc + phase_inc
```

32 位寄存器溢出后自动回绕，一个完整回绕对应波形的一个周期。

### 5.2 取高位查表

波表只有 4096 个点，需要 12 位地址。取相位累加器的高 12 位：

```
phase_index = phase_acc[31:20]
```

低 20 位不参与查表，但保留在累加器中，保证频率精度。频率分辨率由 32 位决定：

```
Δf = f_s / 2^32 ≈ 0.000011 Hz
```

若相位只有 12 位，频率分辨率只有约 11.72 Hz，无法输出 440 Hz 等非整数倍频率。

### 5.3 地址拼接

将 2 位音色选择放在高位，12 位相位索引放在低位：

```
rom_addr = {wave_sel, phase_acc[31:20]}
```

这样改变 `wave_sel` 就切换音色，改变 `phase_inc` 就改变音高，两者互不干扰。

### 5.4 ROM 读取

高云 BSRAM 为同步读，给地址后下一个时钟周期输出数据。输出比地址晚一拍，对 48 kHz 音频无影响。

---

## 六、关键代码

```verilog
module dds_voice (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_en,
    input  wire [31:0] phase_inc,
    input  wire [1:0]  wave_sel,
    output reg  [31:0] phase_acc,
    output reg  [15:0] wave_out
);

    reg  [13:0] rom_addr;
    wire [15:0] rom_data;

    // 相位累加
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            phase_acc <= 32'd0;
        else if (sample_en)
            phase_acc <= phase_acc + phase_inc;
    end

    // 生成 ROM 地址
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rom_addr <= 14'd0;
        else if (sample_en)
            rom_addr <= {wave_sel, phase_acc[31:20]};
    end

    // 例化 ROM
    BSRAM_ROM u_rom (
        .clk  (clk),
        .addr (rom_addr),
        .dout (rom_data)
    );

    // 输出锁存
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            wave_out <= 16'd0;
        else
            wave_out <= rom_data;
    end

endmodule
```

---

## 七、移植步骤

1. 准备波表数据：从 SoundFont 或免费波表包提取单周期波形，量化为 16 位有符号整数。
2. 生成 `.mi` 文件：按上述头部格式编写，数据按音色顺序排列。
3. 在高云 EDA 中配置 BSRAM：IP Core Generator → BSRAM → Read-Only → 地址深度 16384 → 数据宽度 16 → 加载 `.mi` 文件。
4. 例化 ROM 模块，接入 DDS 逻辑。
5. 连接 `phase_acc` 到声部状态表写端口，确保每个采样周期更新。
6. 将 `wave_out` 连接到 SVF 的 `audio_in`。

---

## 八、注意事项

- 16 位有符号数必须用补码，`-1` 写 `FFFF`，`32767` 写 `7FFF`。
- 相位累加器不清零，频率切换时保持相位连续。
- 扩展音色数量时，增大 `wave_sel` 位宽，同时更新 `.mi` 文件的 `Address_depth`。
- 若使用双波表混合，需额外一个 ROM 读端口和一个乘法器，按 `wave_mix` 加权求和。

---