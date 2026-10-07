# 集成接口说明 + Verilog 命名红线（sakiko → poki / majiao）

> 日期：2026-10-08
> 触发：poki 提醒「`program` 是 Verilog 关键字，注意命名冲突」
> 我这边：已建自动检查器扫过全部 RTL，**模块三 23 个文件零冲突**；并把检查并入统一测试入口

---

## 一、`program` 的事 —— 你说得对，而且危害比想象的大

`program` 在 **SystemVerilog 里是块结构关键字**（`program … endprogram`），
在 Verilog-2001 里虽未列入保留字，但：

- **iverilog 往往不报错**（只在特定上下文才当关键字）→ 本地自测能过
- **Gowin 综合器 / 别的仿真器可能直接拒** → 到上板才发现

**正确命名建议（Program Change 相关）**：

| 想表达 | ❌ 别用 | ✅ 建议 |
|---|---|---|
| Program Change 消息 | `program` / `program_change` | `prog_change` / `pc` / `pc_msg` |
| 音色号（PC 的值） | `program` / `program_num` | `prog_num` / `pc_val` / `timbre_slot` |
| Bank Select | `bank` | `bank_msb` / `bank_lsb`（**这两个本来就对**） |

> 你们的 `timbre_map` 输入是 `(bank_msb, program)` —— 把 `program` 改成 **`prog_num`** 或 **`pc_val`** 即可。
> 文档里的措辞（"Program Change"、`program`）是**协议术语**，不用改；改的只是**RTL 标识符**。

---

## 二、我建了自动检查器（已并入测试入口）

**`kw_check.py`** —— 扫 RTL，报告两类问题：

1. **关键字冲突**（181 个关键字表，含 SV 扩展）：模块名 / 端口名 / 信号名 / 参数名 / 实例名
2. **高危近义名**：不一定报错，但在某些工具/版本里是保留字，或极易误用

```bash
python3 kw_check.py                  # 扫本仓库 rtl/
python3 kw_check.py --dir <目录>     # 扫指定目录
python3 kw_check.py --files a.v b.v  # 扫指定文件
```

**当前结果**（模块三 23 个文件）：
```
✅ 无关键字冲突、无高危名
```

**负向测试**（我故意造了一份违规文件验证它真的能抓）：
```
✗ L4  [关键字] `program`      ⚠ `program` 是 SV 关键字；用 `prog` / `pc_val` 代替
✗ L5  [关键字] `time`
✗ L8  [关键字] `event`
✗ L10 [关键字] `logic`
⚠ L9  [高危名] `buffer`
⚠ L11 [高危名] `signal`
❌ 4 处关键字冲突（必须改）
```
退出码 1（可直接接 CI）。

### 高危名清单（建议统一避开）

| 名称 | 为什么 | 建议替代 |
|---|---|---|
| `program` | SV 块结构关键字 | `prog` / `pc_val` / `prog_num` |
| `time` | Verilog 关键字 | `tstamp` / `cnt` / `tick_cnt` |
| `event` | Verilog 关键字 | `evt` / `ev_*` |
| `buffer` | Verilog 关键字 | `buf_mem` / `line_buf` |
| `logic` `bit` `void` `int` `new` `class` `package` `import` `with` `cover` `packed` | SV 关键字 | `lgc` / `bitv` / `dummy` / `i` / `nxt` / `cls` / `pkg` / `imp` / `wth` / `cov` / `pack` |
| `signal` | 部分工具保留 | `sig` / `sgn` |
| `state` | 不是关键字，但 `reg [1:0] state` 易与状态机混淆 | `st` / `cur_st` |
| `edge` | 关键字片段 | `eg` / `trig` |

---

## 三、集成接口说明（你们接线直接照这个）

我给 `full_top` 加了 **3 个参数 + 6 组端口**，默认值 **保持原"自检模式"行为不变**
（所以现有 31 项测试一条没动、全部仍然通过）。

### 3.1 三个参数

```verilog
full_top #(
    .USE_PLL(0),              // 0 = clk50 直连；1 = clk12288 + PLL（上板正式用 1）
    .TEST_MODE_DEFAULT(1),    // 1 = 上电进测试模式（32 谱线自检）；正式跑用 0

    // ↓↓↓ 集成扩展点（默认 0 = 自检模式；置 1 = 由你们驱动）↓↓↓
    .VOICE_SRC(0),            // 1 = 声部源改由外部单声部层给（ext_aud_in/ext_ch_in/ext_vld）
    .EXT_TABLE(0),            // 1 = 通道表参数改由外部调度层给（ext_volume…ext_send_del）
    .EXT_FXPARAM(0)           // 1 = 效果参数/主音量改由外部调度层给（ext_reverb_* … ext_master_vol）
) u_top ( ... );
```

> ⚠ **三个参数必须同时置 1**（要么全自检、要么全外部），混用会出现"参数来自一处、声部来自另一处"的意外组合。

### 3.2 你们要驱动的端口

| 组 | 端口 | 位宽 | 说明 |
|---|---|---|---|
| **声部源** | `ext_aud_in` | `P*24` | P 路并行干信号（Q1.23），与 `slot` 同拍有效 |
| | `ext_ch_in` | `P*4` | 每路声部所属 MIDI 通道号（**0~15 = `midi_channel − 1`**） |
| | `ext_vld` | `P` | 每路声部有效 |
| **通道表** | `ext_volume` / `ext_expression` | `NCH*7` | 7 bit（0~127） |
| | `ext_pan_gL` / `ext_pan_gR` | `NCH*16` | **Q1.15**，等功率律（中心 0.7071 = **23170**） |
| | `ext_send_rev` / `ext_send_cho` / `ext_send_del` | `NCH*7` | 7 bit 发送量 |
| **效果参数** | `ext_reverb_size/decay/damping/return` | `16` 有符号 | Q1.15 |
| | `ext_reverb_pre_delay` | `16` 无符号 | 采样数 |
| | `ext_chorus_rate` | `16` 无符号 | 相位增量 |
| | `ext_chorus_depth/mix/return` | `16` 有符号 | Q1.15 |
| | `ext_delay_time` | `16` 无符号 | 采样数（上限 `DLY_MAX=24576`） |
| | `ext_delay_feedback/mix/return` | `16` 有符号 | Q1.15 |
| **主输出** | `ext_master_vol` | `14` | SysEx 主音量 0~16383 |
| | `ext_mute` | `1` | 1 = 静音 |
| | `ext_test_mode` | `1` | 运行时测试模式（替代上电常量） |

### 3.3 ⚠ 三条时序红线（**违反会出咔哒或 X**）

**① 通道表参数只在 `frame_stb` 帧边界改**
`chan_table` 是双缓冲（你们 §四.2 的设计），在帧中间改会读到"半新半旧"。
`frame_stb` 就是 `pt8211_tx.sample_stb`，也是你们文档里的"全系统唯一提交时刻" —— 一致。

**② 复位期间必须把所有 `ext_*` 输入钳到确定值（尤其 `ext_vld=0`）**
我实测踩到：复位释放那一拍 `ch_vld=1`，若此时 `ext_aud_in` 是 **X**，X 会被采进通道累加器 → **整链全 X**。
（表现：`sample_l=x`、`slot_vld=0`、输出恒 0。）

**③ `slot_vld` 的四条契约照 §8.5.1 执行**（你们文档 §三.七 已对齐）
每采样恰好 G 个、每个 1 拍宽、`slot` 在那一拍有效且递增、第一个脉冲距 `frame_stb` ≥1 拍。

### 3.4 接线参考

我写了 **`tb_integration.v`**，里面有两个 mock（mock 单声部层 + mock 调度层），
**可以直接照抄成你们顶层的接线骨架**：

```verilog
full_top #(
    .USE_PLL(1), .TEST_MODE_DEFAULT(0),
    .VOICE_SRC(1), .EXT_TABLE(1), .EXT_FXPARAM(1)
) u_full_top (
    .clk50(clk50), .clk12288(clk12288),
    .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),
    // 单声部层 → 通道层
    .ext_aud_in(voice_aud), .ext_ch_in(voice_ch), .ext_vld(voice_vld),
    // 调度层 → 通道表（**只在 frame_stb 帧边界更新**）
    .ext_volume(chan_volume), .ext_expression(chan_expression),
    .ext_pan_gL(chan_panL), .ext_pan_gR(chan_panR),
    .ext_send_rev(chan_send_rev), .ext_send_cho(chan_send_cho), .ext_send_del(chan_send_del),
    // 调度层 → 效果参数
    .ext_reverb_size(fx_reverb_size), .ext_reverb_decay(fx_reverb_decay),
    .ext_reverb_damping(fx_reverb_damping), .ext_reverb_pre_delay(fx_reverb_predelay),
    .ext_reverb_return(fx_reverb_return),
    .ext_chorus_rate(fx_chorus_rate), .ext_chorus_depth(fx_chorus_depth),
    .ext_chorus_mix(fx_chorus_mix), .ext_chorus_return(fx_chorus_return),
    .ext_delay_time(fx_delay_time), .ext_delay_feedback(fx_delay_feedback),
    .ext_delay_mix(fx_delay_mix), .ext_delay_return(fx_delay_return),
    // 调度层 → 主输出
    .ext_master_vol(master_vol), .ext_mute(master_mute), .ext_test_mode(test_mode)
);
```

---

## 四、我这边的验证结果

| 项 | 结果 |
|---|---|
| 关键字冲突 | **0**（23 个 RTL 文件全过；检查器本身做过负向测试） |
| 全量回归 | **32 项全过**（原 31 + 新增集成 6 项），323 秒 |
| 新增 `tb_integration` | 集成模式下 **6 项全过**：无 X / 双极性 / 不削顶 / 帧边界改参数 / 部分静音 / vld=0 / mute |
| 默认参数回归 | 加扩展点后**默认行为未变**（31 项一条没动仍全过） |

### tb_integration 踩过的 4 个坑（都是**测试方法**问题，写下来免得你们也踩）

1. **等待要按"采样数"，不能按"时钟拍数"**：`f_s=48 kHz`、`f_clk=50 MHz`
   ⇒ **1 个采样 = 1024 拍**。`repeat(2000)@(posedge clk)` 只够 2 个采样。
2. **复位期间必须钳住所有外部输入**（见 §3.3 红线②）——否则 X 灌进链路。
3. mock 里别用 `negedge rst_n`（`sys_rst_n` 是 X→1，**没有下降沿**，异步分支永不触发）；
   输出要**寄存**，在 `generate` 里 `assign` 读内存会失败。
4. **激励要有真实交流分量**：50% 方波几乎全是直流，会被 `dc_block`（时间常数 ≈1160 采样）
   在约 1 万采样内抽干，看起来像"设计没声音"。用正弦（共享 `sine_src.vh`，带线性插值）。

---

## 五、需要你们做的

1. **改 `program` 命名**（`timbre_map` 等处）→ 建议 `prog_num` / `pc_val`
2. 有空时把 `kw_check.py` 加到你们的检查流程（或我合入时一起跑）
3. 接线照 §3.4 的骨架；三条时序红线务必遵守（尤其**复位期间钳住 `ext_*`**）

有问题直接问，我这边继续跑验证。
