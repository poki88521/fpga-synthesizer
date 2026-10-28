# baseline_G —— 混响增益结构重构（5 处结构性缺陷修复）

> 归档时间：**2026-10-28 17:20**
> 构建时间：综合 16:40:10 / P&R 17:07:44
> 上板试听结论（用户）：**「声音很干净」** —— 症状 A（有音 + 开混响 → 炸）**已解决**
> 分支：`feature/fix`（HEAD = `b37d29a`，本轮改动未提交）

---

## 1. 这个位流里有什么

**唯一的 RTL 改动：`rtl/global/fx_reverb.v` 重构**（其余 `src` 下文件与 14:04 那版完全相同）。
同步到 Gowin 工程后 `src/global/fx_reverb.v` 与仓库 `rtl/global/fx_reverb.v` 逐字节一致：

```
rtl/global/fx_reverb.v              SHA256 264D61DF7CB277F91A4A8957F0211E7073006707F2725AB9B4B6DBA55B97B1CB
board/.../src/global/fx_reverb.v    SHA256 同左
full_system.fs                      SHA256 9E2A0EE23FDD989BAF8D1452BF95D77A29CE0FABFBA7CC6496AE86487277CC6D
```

### 修掉的 5 处缺陷（都有仿真量化证据）

| # | 缺陷 | 证据 |
|---|---|---|
| ① 主因 | `comb_w` 的 `>>>` 作用在**位拼接**上（拼接永远无符号 → 逻辑右移），负反馈值补 0 变巨正、再被 `sat24` 钳到 +满量程 ⇒ 反馈变"半波整流 + 正反馈" | 0.6 FS/1 kHz：注入仅 0.0019 FS，单条梳状 62 ms 冲到 1.00 FS、16 条之和 **12.4 FS**、湿声满量程、**23% 采样削顶** |
| ② | 全通输出 `ap_out` 25 位**无饱和截断**到 24 位 | 一次 20000 帧仿真发生 **110703 次**符号翻转 |
| ③ | 右声道每条线是 `len+25` 但偏移表按左声道 `len` 累加 ⇒ 每条线环尾盖住下一条开头 25 个采样 | 右声道电平比左声道高 **1.5 倍** |
| ④ | 全通反馈用 `ap_x`（上一采样读出）而非当前 `m0`，等价把全通延时改成 N+1 | 与 Freeverb allpass.hpp 公式不符 |
| ⑤ | 全通链第 1 级**没接到"16 条梳状之和"**：`ap_wire[0] <= ap_in_c` 每条线都执行，li==19 锁存时把它覆盖成别的级的值 | `comb_sum>>>1 = 155` 的那帧，下一帧 `ap_in[0] = 0`（应为 155），`ap_in[1]=-155 / ap_in[2]=+155` |

### 结构上的额外变化

- 缩放常数全部集中到文件头 `localparam`（`INJ_SH=23 / SUM_SH=1 / RET_SH=13`）+ 注释里的逐级增益预算表。
- 湿声电平 **+6 dB**（`RET_SH` 14→13）：旧版只有 −20 dBFS，正对应"混响开/关几乎听不出区别"。
  实测（0.6 FS 单音、满发送）：1 kHz → L 0.094 / R 0.204 FS；60 Hz → 0.211 / 0.206 FS。
- 梳状求和处与出口各加一级**软限幅**（0.75 FS 拐点、以上斜率 1/4，纯比较+加+移位、无乘法器），杜绝硬削顶。
- 全部通反馈的 `m0×16384` 换成算术右移 1 位：**少一个 48 位乘法器**；删掉冗余状态 `ap_rd/ap_wire/ap_fb`：
  **净 −192 个寄存器**（P&R 实测 Register 30905 → 30717）。
- `ifdef SIMULATION` 下每帧打印软限幅次数与湿声峰值（综合后不存在，不占硬件）。

---

## 2. 构建与验证数据

### 时序（`full_system.tr`）

```
Setup 违例端点  0 / 103184（分析 211620 条路径）
Hold  违例端点  0
TNS            0.000（所有时钟）
clk_sys        Fmax 49.209 MHz（约束 49.152）  最差 slack +0.024 ns   ← 贴线
clk50 / clk12288 / 显示 PLL   157.744 / 389.436 / 80.404 MHz
布线 Phase 0~3 全完成，最大拥塞 0.889（R23C69、R74C103），非 PR0004
```

最差路径（与混响无关，全是干路）：

```
rst_sync_0_s0 → mx_l_s_2_s9 … mx_l_s_22_s   （main_mix 干路累加）
→ u_master/u_vol/u_vol_l/acc_r_0_s          （主音量乘法 15.1→17.7 ns）
→ u_master/g_lim.u_lim/env_4_s3 → env_21_s*  （soft_limiter 包络）
→ env_d1_16_s0                               （28.938 / 28.961）
```

### 资源（对比 14:04 那版）

| 项 | 旧 | 本版 |
|---|---|---|
| Logic (LUT+ALU) | 42565 (31%) | **42879 (32%)** |
| Register | 30905 (23%) | **30717 (23%)** |
| BSRAM | 190/340 (56%) | **190/340** |
| DSP | 185/298 (63%) | **185/298** |
| PRIMARY / LW | 8/8 / 8/8 | **8/8 / 8/8**（时钟墙仍在） |

### 仿真（本机 iverilog，`-g2012 -DSIMULATION`）

```
tb_fx_reverb     PASS  7 项（16 条梳状回声位置 / 右声道+25 / 首拍标定 2479=理论 / 无饱和 / 衰减 / 1:1）
tb_reverb_level  PASS  湿声 L 0.081 FS(−21.8 dBFS) / R 0.160 FS(−15.9 dBFS)，无削顶
tb_fx_top / tb_fx_agg / tb_fx_bypass(4 变体) / tb_fx_chorus / tb_fx_param / tb_mix_chain   PASS
tb_full_system / tb_limiter / tb_voice_mono / tb_dc_block / tb_norm_sat / tb_mix_timeout    PASS
全系统 iverilog 编译（42 个 .v + 桩）  exit=0
```

---

## 3. 已知遗留 / 未做的事

```
① 症状 B（空载周期性爆音，关混响也有）：本轮**没有针对性修复**。
   但混响内部回路已换（旧版会把饱和值写回延迟线、尾巴永不衰减），
   若 B 与混响自激有关可能已自然消失 —— 上板请专门确认一次。
② fx_top 的 LAT_MAX=128 < 混响实际 200 拍/采样 ⇒ 湿声恒比干声晚 1 个采样（20.8 µs）。
   听不出，但不是"0 延迟"。要修就把 LAT_MAX 提到 256（一行）。
③ fx_chorus：mix 仍 0.70（交接文档建议改 0.45，属听感调参，未动）。
   另发现真 bug：左右声道写同一个地址，后写的右声道覆盖左声道样本。
④ tb_fx_delay 仍 FAIL（回声整体晚 1 拍），源自上一轮给 fx_delay 加"读→写流水"，
   TB 期望值没跟着 +1。
⑤ 本版时序余量仅 +24 ps（贴线），**任何后续改动都要重看 .tr**。
```

---

## 4. 文件清单与还原

```
full_system.fs              位流（39.08 MB，17:07:44）★烧这个
full_system.tr              时序报告（违例 0 / Fmax 表 / 最差路径）
full_system.rpt.txt         P&R 报告（资源 + 时钟资源 + 布局布线摘要）
full_system.timing_paths    最差路径逐级延时（1961 行）
full_system_synthesis.log   综合日志（确认分析/编译了哪些文件）
full_system_syn_rsc.xml     综合资源明细（u_rev: LUT 1467 / DSP 9 / BSRAM 72）
full_system.cst / .sdc      引脚与时序约束（与 rtl/top/full_top.cst/.sdc 一致）
full_system.gprj            Gowin 工程文件
fx_reverb_pre_refactor_20261028.v   重构**前**的 fx_reverb.v（SHA256 4FEEA324…，24525 字节）
                                    ⚠ 只供 A/B 对照/回滚，不参与本版构建
```

**还原 RTL 到本版状态**：把 `rtl/global/fx_reverb.v` 与 `board/full_system/src/global/fx_reverb.v`
都换成本版（SHA256 `264D61DF…`），再跑 `board/full_system/sync_src.ps1`。
**回滚到重构前**：把上面那个 `fx_reverb_pre_refactor_20261028.v` 复制回两个位置（SHA256 `4FEEA324…`），
它带着本文档 §1 表里的 5 个 bug，仅用于对照。

**复现量测**：`develop/scratch/agent/tb_reverb_diag2.v`（逐级峰值 + 包络，支持
`+FREQ= +NIN= +NFR=`）与 `simulation/tb/tb_reverb_level.v`（电平回归）。
