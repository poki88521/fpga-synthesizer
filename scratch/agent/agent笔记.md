# agent 工作笔记（持续更新）

> **2026-10-24 归档说明**：`交接文档_20261021.md` 与 `当前状态交接_20261020.md` 已删除，
> 其中**被实测证伪**的结论记录于此，避免以后再被误导：
> ① "`samples_rdy` 每帧 4 次是炸的根因" —— **错**。4 个时隙各扫一遍是设计如此，改成 1 次会让 3 个时隙饿死。
> ② "音高 2 倍是 DDS 相位增量算错" —— **错**。是波表槽 0/1 里塞了 2 个周期（2048 点）。
> ③ "CC7 降下来还炸 ⇒ 失真与音量无关" —— **错**。CC7 在乐器口被 `midi_filter` 丢弃，音量从未变过。
> ④ 真正根因见下面「★★★ "炸"已修好」一节：混响 8 条梳状输出直接相加、内部硬削顶。

## ★★★ "炸"已修好（2026-10-23 上板确认）

**根因：混响 `fx_reverb` 内部 8 条梳状滤波器输出直接相加、没有缩放，
内部节点达到 5.2 倍满量程，被 `sat24` 每帧钳位 706 拍 → 削顶失真；
钳位值又写回延迟线，于是尾巴永不衰减（对应"等 10 秒不衰减"）。**

```
诊断过程（关键：先用仿真把范围缩小）
  ① 上板：CC11 127→8（−24 dB）音量变小但"炸"的质感不变
     ⇒ 排除削波/电平相关 ⇒ 是"与幅度无关"的形状类失真
     （后来才知道：交接文档里"CC7=2 也炸 ⇒ 与音量无关"这条无效——
       midi_filter.v:139 里 CC7/10/91/93/94 只在 port3（A17 混音口）生效，
       乐器口 C21 上直接被丢弃，那几次测试音量从未变过）
  ② 仿真（新增 tb_slot_probe 的 dump + 新建 tb_chain_probe）证明
     **声部层 + 通道层 + 主混音（干路）是干净的**：
        声部 voice_out：1F 263.2 / 2F −16.2 / 3F −27.0 dB，非谐波 −42 dB，撞 sat24 0 次
        干路 main_l ：峰峰 53.3%FS、**跳变 0 次**、4F −8.3 dB（钢琴表理论 −8.8 dB，吻合）
     ⇒ "炸"只能在效果器（TB 里 FX 输入接 0，等于没测）
  ③ 上板对比 A/B：同一个持续音，只改 CC91/93/94
     a.csv（效果器开）最强峰 738 Hz、RMS(Δ)=2.10 V
     b.csv（效果器关）最强峰 **261.7 Hz**、RMS(Δ)=1.19 V
     ⇒ 高频是效果器造出来的；且"关掉效果器 = 正常" ✔
  ④ 单路隔离：CC91 单走最大 → 炸；CC93/94 最大 → 只有很轻的影响
     ⇒ 主因是混响
  ⑤ 混响探针 tb_reverb_probe（262 Hz 正弦 + 实板参数）定量复现并定标：
     >>>15  内部 5.20×FS 削顶 706.6 拍/帧 最强峰 5670 Hz 尾巴恒定 18.6%FS
     >>>19  内部 1.59×FS 削顶   4.3 拍/帧
     >>>20  内部 1.06×FS 削顶   0.1 拍/帧 最强峰 262.5 Hz（但发送 127 时又回到 1.27→上板仍炸）
     >>>23  内部 0.45×FS 削顶   0.0 拍/帧 ret 44.8%FS 尾巴单调衰减（T60≈3s）★ 采用
```

**最终改动（2 处，已上板验证"炸"消失）**

```
rtl/global/fx_reverb.v   L281/282   (bus*size) >>> 15  →  >>> 23     梳状网络输入 ÷256
rtl/top/full_top.v       L531       reverb_return 16000 → 32767      补回湿声电平
```
`board/full_system/src` 已同步；备份见 `scratch/backup/`（三套状态：÷15 / ÷32 / ÷256）。

**遗留（已知、轻微）**
```
· CC91（混响发送）拉到 127 时仍有轻微失真：湿声 44.8%FS + 干路 0.6 FS ≈ 1.05 FS
  → 是 main_mix 的 sat24 在削。一行可解：reverb_return 32767 → 26000（湿声降到 0.36）
· fx_delay 有同类"轻症"：p_fb=22000(0.67) ⇒ 反馈环稳态增益 ≈3 倍，
  wdata <= sat24(wl_n) 在输入 >0.33 FS 时开始削顶（对应"CC94 最大有一点影响"）
  → 解法：wdata 除以 2 后再读回补偿，或 p_fb 降到 15000
· fx_chorus 没问题（交叉淡化，输出 ≤ max(bus,wet)）
```

**用户结论：修好了，只剩 CC91 开到最大有轻微失真。**

---

> 本文件是 agent 自己的工作记忆，**取代** `交接文档_20261021.md` 里的结论部分
> （那份文档对"炸"的根因判断已被实测证伪：根因不是 `samples_rdy` 次数）。
> 最后更新：2026-10-21 20:24

---

## 0. 一句话现状

`炸` 的主机制（音高精确 2 倍 + 波表非谐波分量）**已修**，声部层的结构性缺陷
（波表槽/参数差一个时隙、4 声部共用状态、包络站不住）**已在 RTL 修完并通过全部
仿真回归**，等重新综合+P&R 后上板验证。

---

## 1. 当前 RTL 状态（2026-10-21 这一轮改动）

| 文件 | 改了什么 |
|---|---|
| `rtl/voice/dds_voice.v` | ① `timbre_r` 在 `dds_en` 沿锁存后再拼地址；② `phase_acc` → `phase_r[0:3]`（按 `slot` 选）；③ 新增 `slot` 输入，`phase_acc` 输出改为 wire |
| `rtl/voice/svf_voice.v` | `low/band` → `low_r[0:3]/band_r[0:3]`；流水相位 0 锁存 `s1_slot`，相位 3 写回同一份；新增 `slot` 输入 |
| `rtl/voice/adsr_vca.v` | `env_value/env_state` → `env_r[0:3]/st_r[0:3]`；这两个名字保留为"当前时隙那份"的组合读，**组合逻辑一行未改**；新增 `slot` 输入 |
| `rtl/voice/voice_mono.v` | ① 新增 `slot` 端口并下传三级；② 新增 134 bit **时隙参数锁存**（f/q/ftype/ADSR 四步长/slevel/velgain/vcagain/sust），SVF 与 ADSR 改用锁存值；③ ADSR 的 `gate` 改用 `data_gate_r`（`dds_en` 沿锁存） |
| `rtl/top/full_system.v` | `voice_mono` 接 `.slot(slot)` |

**数据文件**：`board/full_system/data/wave_table.hex` 与 `wave_table/out/wave_table.hex`
已替换为"每槽严格 1 个周期"的新表（见 §2.1），两者 SHA256 相同。

**新增工具**（都在 `wave_table/`）：
```
rebuild_wave_table.py   重建波表（--write 写盘 / --verify 回读校验 / 默认 dry-run）
analyze_periods.py      逐槽判断"2048 点里有几个周期"
verify_rom_init.py      解码综合网表 pROM 的 INIT_RAM，逐位核对位流里的波表
```

**新增测试台**：
```
simulation/tb/tb_wave_pitch.v   波表+DDS 音高专项（1x / 2x 判定），1000 帧≈10 s 仿真
simulation/tb/tb_slot_probe.v   时隙/预取时序探针（pf_gate vs 锁存 gate、每帧包络步数）
```

**为接新端口而改过的旧 TB**（各加了一行 `.slot(2'd0)`）：
`tb_svf_voice.v`、`tb_adsr_vca.v`、`tb_dds_voice.v`、`tb_voice_mono.v`、`tb_wave_real.v`；
其中 `tb_voice_mono.v` 还有一处层次赋值改成 `u_dds.phase_r[0]`（`phase_acc` 已是 wire）。

---

## 2. 已验证的结论（带数字，别再重复查）

### 2.1 2 倍音高的根因 = 波表数据，不是 `samples_rdy`

```text
DDS 口径：idx = phase_acc[31:21]（11 位 = 2048 点）走完一个相位周期
          → 每槽必须恰好 1 个波形周期
实测（majiao 源文件与烧录表逐位一致）：
  slot0 钢琴    bin2 占 82.3%  → 2 周期  → 输出 2x
  slot1 吉他    bin2 占 96.6%  → 2 周期  → 2x
  slot2 管风琴  bin1~4 各约 25% → 1 周期 ✓（注意：最强 bin 是 bin3(25.55%)，
                                      按"最强 bin"判会误判成 3 周期，会把好槽做坏）
  slot3 长笛    bin1 占 98.2%   → 1 周期 ✓
  slot4~7 旧合成波（三角/方/锯齿）→ 1 周期 ✓
判据（别只看最强 bin）：
  半周期自相关 r(1024) > 0 且"P 倍数 bin 能量 > 75%" 才算 P 周期
  · 真 2 周期          → r(1024) 为正（piano +0.33 / guitar +0.47）
  · 1 周期 + 强 2 次谐波 → r(1024) 必为负（锯齿 -1、方波 -1）
算术对账：phase_inc(60)=23409859 → 每帧 11.16 个表点 → 3.82 ms 扫完 2048 点
          = 261.6 Hz；表里有 2 个周期 → 523 Hz（实板实测 524.5 / 2100 ✓）
DDS 行为模型复现：旧表 slot0 → 523.00 Hz，新表 → 262.00 Hz
```

重建后的槽内容（用于判断"音色为什么变薄"）：
```
slot0 钢琴：基频 85.7% + 4 次谐波 13.3%   （原 12.8% 的非谐波 bin7 并入最近谐波）
slot1 吉他：基频 97.3% + 2 次谐波 2.4%
```

### 2.2 `samples_rdy` 每帧 4 次是**设计使然**

每帧 4 个时隙（`slot_vld` 在 `cyc=1/33/65/97`，`STRIDE=32`），`wave_fetch` 每时隙扫
一次 2P 地址 → 每帧 4 次 `rdy`。**不能改成 1 次**，否则 3 个时隙的 24 个声部拿不到数据
（`full_system.v` 的注释里记着 STRIDE=8 时的这个旧故障）。

### 2.3 声部层的结构性缺陷（这轮修掉的）

```text
① voice_fetch 预取语义：slot_vld 那拍把 pf_* 换成**下一时隙**的声部
   · phase_inc 由 dds_voice 在沿前采样        → 属于声部 g ✓
   · 波表地址在 start_d（沿后）才锁          → 原来取到声部 g+1 ✗（已用 timbre_r 修）
   · SVF/ADSR 使能在 rdy_d1 / rdy_d4（十几拍后）→ 原来全是声部 g+1 ✗（已用参数锁存修）
② 一条泳道只有一套 phase/svf/env 状态，却要服务 4 个声部 → 已拆成 4 份（按 slot 索引）
③ 包络站不住的机制（探针实测）：ADSR 每帧被推进 4 次，其中 3 次 gate=0
   → SUSTAIN 里立刻判"松键"进 RELEASE → 任何音都是"一击+长尾"
   修后：slot0 env 6000→9000→12000（每帧 +1 步），slot1/2/3 各自独立
```

### 2.4 位流里确实带着新波表（可复用）

综合后 `impl/gwsynthesis/full_system.vg` 里波表被推断成 16 个 `pROM`（每位一个），
带 `INIT_RAM_00..3F`。`verify_rom_init.py` 按"bit i = 地址 i、缺失块=全零"解码比对：

```text
2026-10-21 17:35 那次构建：16384 地址 × 16 位 全部一致  PASS
```

⚠ **高云对全零的 `INIT_RAM` 块不生成 `defparam`**（默认即 0）。按"缺失=错"判会误报。

---

## 3. 仿真回归状态（改完全部通过）

### 3.0 ⚠ 2026-10-21 晚：上板"完全没声音"的两个根因 + 修复

现象：烧 21:32 那版位流后**正常模式全静音**，`变音色/音高/响度` 都无声，
但**测试模式正常**（测试模式注入在 `voice_aud`，不走声部层 → 说明通道/效果/DAC 链路是好的）。

根因是**两个"差一拍"的使能错位**。它们在旧代码里也存在，但那时 4 个时隙共用一套状态，
"上一拍的值"仍是同一个音的值，所以听不出来；**方案 A 让每时隙状态独立之后，它们变成
"取到别的声部的 0"，于是全静音**：

```
① chan_buf 与 VCA 输出错位
   adsr_vca 在 sample_en(=vca_en) 的**时钟沿**才把结果写进 audio_out，
   而 voice_mono 原来 `assign data_vld = vca_en;` → chan_buf 在同一沿采样，
   拿到的是**上一个时隙**的音频。
   修：data_vld 后移 1 拍（data_vld_r <= vca_en）。
② VCA 与 SVF 输出错位
   svf_voice 的 4 级流水在 rdy_d1 启动，在 rdy_d1+3 的沿才写 audio_out，
   即 **rdy_d5** 才有效；而 vca_en 原来是 rdy_d4，早一拍 → VCA 乘到上一时隙的滤波结果。
   修：vca_en = rdy_d5（新增 rdy_d5 寄存器）。
```

**诊断过程（可复用）**：在探针 TB 里逐拍打印
`slot / rdy / rdy_d1 / rdy_d5 / data_vld / env / svf_out / vca_sat / audio_out`，
一眼就能看到"`d5=1` 那拍 `env=0`、下一拍 `env` 才变"和"`sat` 算对了但 `audio_out` 没跟上"。

**注意**：探针只跑 8 帧会误判成"仍然全零"——那时包络还在起音的最初 2 帧里。
必须跑到 100+ 帧再统计。实测 200 帧：`gate=1 的 data_vld = 198 次，输出为 0 的只有 2 次`
（就是起音前两帧），`|voice_out| 峰值 = 5874511`（70% 满量程）。

修复后回归：`tb_voice_mono` / `tb_adsr_vca` / `tb_svf_voice` 全 PASS，全系统编译 exit=0，
rtl↔board 40 个 .v 哈希一致。

```text
tb_svf_voice    PASS  参考比对失配 0 处；通带 2169929/2097152、阻带 -38.4 dB、稳定
tb_adsr_vca     PASS  量程 97149 步全在 [0,32767]
tb_dds_voice    PASS  8000 样本逐位一致；槽内回绕 167 点；相位连续
tb_voice_mono   PASS  整链 50.0% 满量程；两泳道逐位一致（无串扰）；释放归零
tb_wave_pitch   PASS  20.48 ms 过零 10 次（2x 会是 42 次）；timbre 锁存 bad_slot=0
tb_slot_probe   PASS  每声部每帧只推进一次、状态互不污染
全系统 iverilog 编译 exit=0（含 simulation/models/gowin_prim_stub.v）
```

---

## 4. 已知残余风险 / 未解释的现象

### 4.0.0b ✅ 2026-10-22 14:51：P&R **零违例**（也验证了"违例↔耗时"相关性）

```
构建             Setup违例    TNS       最差slack   Fmax        P&R总时长   布线Phase1
10-21 17:35        491     -1778 ns   -5.215    39.124 MHz    37 min      ~30 min
10-21 21:32        673     -1460 ns   -3.466    41.997 MHz    62 min      54m56s
10-21 23:21        201       -76 ns   -0.805    47.282 MHz    42 min      32m33s
10-22 14:51          0         0 ns   +0.005    49.163 MHz    29m34s      21m45s   ★
```
⇒ **违例数与 P&R 时间正相关**：673→201→0 违例，62→42→29.5 分钟。

零违例的关键：`adsr_vca` 的 `env_vca` 被综合器并进 **p40 DSP 的 B 口输入寄存器（BREG）**，
把 "slot → 4 选 1 mux → 两个 DSP 乘串联 → 进位链 → audio_out"（21.07 ns）断开。
现在最差路径变成 `wave_fetch` 的 ROM 地址（`n1087_s/DOUT → pROM/AD`，**+0.005 ns**）。
⚠ **余量只有 5 ps**：以后任何改动都可能把它推过线，改完一定要看 `.tr`。

位流：38.86 MB，14:51:46。

### 4.0.0c ⭐ 2026-10-22 晚：仿真证明**干路数字域是干净的**

两个离线探针 TB（不需要板子）：

```
tb_slot_probe.v  （加 dump）声部层波形 → scratch/agent/probe_voice.txt
tb_chain_probe.v （新）干路全链：声部 → chan_layer → main_mix（FX 输入接 0）
                       → scratch/agent/probe_chain.txt
分析脚本：analyze_voice_wave.py、analyze_sim_dump.py
```

**结果（钢琴槽 0 / note 60 / 稳态）**

```
声部层 voice_out（208 ms，分辨率 4.9 Hz）
  1F 263.2 +0.0 dB / 2F −16.2 / 3F −27.0 / 4F −32.6 / 非谐波 −42.3 dB，撞 sat24 = 0 次

干路 main_l（61 ms 稳态）
  峰峰 53.3% FS，**跳变 >10%FS = 0 次**，|Δ|max/RMS = 2.2
  基频 260.4 Hz；2F −27.9 / 3F −24.0 / **4F −8.3**
  钢琴表本来就是「基频 85.7% + 4 次谐波 13.3%」→ 4F 理论 −8.8 dB，完全吻合
  非谐波 −45.3 dB
```

⇒ **声部层 + 通道层 + 主混音（数字干路）没有失真、没有跳变、没有削波。**
⇒ "炸"只可能来自：① 效果器（TB 里 FX 输入接 0，未测）；② 硬件侧（时序/DAC/模拟）；
③ TB 条件与实板不同（多声部、别的音色、真实 ADSR 参数）。

⚠ 2026-10-22 上板实测两条关键事实：
```
· CC11 127 → 8（−24 dB）：音量明显变小，但"炸"的质感**不变**
  ⇒ 不是阈值型削波（削波会随电平减轻），是"与幅度无关"的形状/断点类失真
· CC91/93/94 = 0 关效果器：先出现"非常非常微弱、不炸"，后来又"还是炸"——两次矛盾，需重测
  ⇒ 但干路既然干净，**效果器成为头号嫌疑**
```

### 4.0.0 ⭐ 2026-10-22：仍"炸"的根因 = `audio_out` 建立时间不足（192/201 违例）
23:21 那版位流上板后：音高正确（C24 实测 **261.3 Hz**，2F 只有 **−34.6 dB** → 2 倍音高问题
**确认修好**），但**仍然炸**。C24 波形分析（`material/waveform/c24.csv`，60 ms）：

```
相邻采样差值 >0.5 V 的有 85 处；最狠一处 −1.25 V → +0.95 V 一步跳 2.2 V
参考：干净 261 Hz 在 20 kSa/s 下每点最大变化约 0.12 V
→ 波形里有大量不连续 = 咔哒/毛刺
```

对照 P&R 报告，最差路径正是音频输出寄存器（**201 个违例里 192 个 = 8 泳道 × 24 bit**）：

```
slot_0_s0（扇出 2613）--5.9 ns 布线--> env_r[slot] 的 4 选 1 mux
  → p40 DSP 乘（audio × env）→ prod DSP 乘（× g_vt）→ 进位链 → audio_out
数据延时 21.07 ns vs 周期 20.345 ns → slack −0.793 ns
```

**修法（2026-10-22 已做，功能不变）**：`adsr_vca` 里加 `env_vca <= env_value`，VCA 用 `env_vca`。
env 每时隙只变一次、`vca_en` 在时隙后段，两者在 `vca_en` 那拍完全相等。
把 "slot → mux → 5.9 ns 布线" 这 6.1 ns 从路径摘掉 → 预计 slack 从 −0.79 变到 +5 左右。

回归：`tb_slot_probe` 数字与改前**完全一致**（198 / 2 / 5874511）、`tb_adsr_vca` PASS、
`tb_voice_mono` PASS、全系统编译 exit=0、rtl↔board 哈希一致。

**同时改探针**：`dbg_sd_va`（E25）原来只取泳道 0，实测泳道 0 空闲时读到 2.9 V 直流、按键不变
（MIDI 分配器把音符分到哪条泳道是任意的）。改成 **8 条泳道求和后寄存**（空闲声部贡献 0）
→ 只反映真正在响的声部。

**剩余已知违例**：`wave_fetch` 的 ROM 地址路径（`n1087_s/DOUT → pROM/AD`，约 9 个端点，−0.805 ns）。
先不动（改动要挪一整个扫描周期，风险高）；192 个违例消失后布线器有更多余量，可能自行收敛。
若仍不收敛，零风险的办法是把 `-route_option 2` 换成 1（时序优先）。

### 4.0 预取路径：vtab 4 选 1 + 三级流水（2026-10-21 晚已做）

原来 `pf_phase_inc` 一拍里串：
`slot → vtab[vid]（**隐性 32 选 1** 读 mux）→ vib_bend_ratio(16×16) → apply_ratio(32×16) → 饱和`，
实测数据延时 23.7 ns vs 周期 20.345 ns → slack −3.466 ns。

**两处改动**：
```
① vtab 读降到 4 选 1：本泳道 vid = {nslot, gl}，低 3 位 gl 是 generate 常量，
   候选只有 4 条。原来写 `vtab[vid]` 综合没利用这个常量关系，做成了大 mux
   （路径里 5 级 LUT、跨区跳线合计约 13 ns）。改成显式 4 选 1：
       (nslot==0)? vtab[{0,gl}] : (nslot==1)? vtab[{1,gl}] : ...
② 三级流水（每级只做一件事）：
   A slot_vld    ：读出并锁存要用的 79 位字段（it_r = phinc|vcagain|velgain|note|ch|timbre|gate）
   B slot_vld+1  ：ratio_r <= bend×vib（16×16）；其余 pf_* 字段同时写
   C slot_vld+2  ：pf_phase_inc <= phinc×ratio（32×16）+ 饱和
```
时隙周期 32 拍，第 3 拍出结果（余量约 29 拍）；voice_mono 在**下一个** slot_vld 才采样 pf_*，
语义不变。新增寄存器约 760 个（it_r 632 + ratio_r 128），DSP 仍 84。

回归：`tb_voice_fetch` / `tb_sched_subsystem` / `tb_voice_mono` 全 PASS；
`tb_slot_probe` 数字与改动前完全一致（`gate=1 的 dv=198 / 输出0=2 / max|out|=5874511`）。

### 4.0.1 P&R 耗时构成（2026-10-21 21:32 那次，实测）

```
Total Placement   6m28s        ← 每次都很稳定
Routing Phase 1  54m56s        ← 93% 的时间在这一步（拥塞 + -timing 迭代）
Routing Phase 2   0m03s        ← 注意：日志按阶段刷盘，实际不是卡在 Phase 2
Total            62m03s
历史区间：37 ~ 63 分钟（与违例数无相关性：392 违例跑过 62 分钟，491 违例跑 37 分钟）
```

**提速杠杆**（按可用性排序，未经验证的要先做 A/B）：
```
① 功能验证阶段用 `-timing`（时序驱动）关掉跑 P&R —— 时序好坏不影响"能不能出声"的判断
② 批量改完再跑一次 P&R，别改一行跑一次
③ `place_option 1`（牺牲布局时间换更好布局）→ 可能让布线更快，需实测
④ 设计规模：这轮 +3224 寄存器 / +1738 LUT（4 选 1 状态阵列），是拥塞上升的主因
工具链：`D:\Gowin\...\IDE\bin\gw_sh.exe` 是 Tcl 控制台，可无头跑 综合/P&R 做 A/B
        （需先在 IDE 里关闭工程，避免文件占用）
```
```text
① P&R 时序违例（10-21 17:35 那版：Setup 491、最差 −5.215 ns、Fmax 39.124 MHz）
   全部落在 u_sched/u_sq/slot_1_s0 → u_sched/u_vf/pf_phase_inc_*_s0
   = voce_fetch 的 vib_bend_ratio(16x16) + apply_ratio(32x16) 两个 DSP 乘法串一拍
   表现：偶发"咔哒/音准抖"，不是持续炸。根本解 = 待处理_预取时序.md 的两级拆分（不增 DSP）
② 波表数据本身薄（钢琴 85.7%+4 次谐波、吉他≈纯正弦）→ "薄/闷"是数据，不是 bug
③ 起音变慢：包络恢复设计速率后，槽0 的 a_step=2 ≈ 340 ms（改前被 4x 速，约 85 ms）
   觉得太慢就调 timbre 参数表的 a_step，不用改逻辑
④ **未解释**：交接文档记"等 10 秒不衰减"，但按代码包络应在 100~300 ms 内衰到 0
   （探针仿真里确实看到 env 在掉）。若新位流仍"响了不衰减"，说明模型还缺一块
⑤ 高音区混叠：波表 2048 点，高音时谐波超 Nyquist（但新表谐波很少，影响应远小于以前）
```

---

## 5. 上板验证清单（烧新位流后按顺序做）

### 5.0 三级音频探针（2026-10-21 加，PMOD1 / J24）

```
Pin  脚号  信号                                  含义
C24  1    dbg_sd    = sample_l                   通道+效果+主输出之后（DAC 之前）
E25  2    dbg_sd_va = voice_aud[泳道0]           SVF + 包络 + VCA 之后
L17  3    dbg_sd_wv = DDS 波表输出[泳道0]        SVF 之前（直接看波表内容）
```
三路都是 `sd_out`（一阶 1 位 sigma-delta，clk_sys 49.152 MHz），24 位信号取 `[23:8]` 喂进去。
RTL：`full_system` 例化两个 `sd_out`；`full_top` 新增 `dbg_voice_aud` 输出；
`voice_mono` 新增 `dbg_wave` 输出。CST 两份（`rtl/top/full_top.cst` ↔ `board/.../full_system.cst`）已同步。

**⚠ 关键：RC 截止频率要按目的选**
```
判音高：R=1k + C=100nF → fc≈1.59 kHz   （干净，但把 1.5 kHz 以上全滤掉）
判"炸"：R=1k + C=10nF  → fc≈15.9 kHz   （要两节串联更干净）
        用 1.59 kHz 测"炸"会把高频失真滤掉，看起来一切正常 —— 这是个大坑
```
示波器：**1 MΩ 输入**、DC 耦合、1 V/div（50 Ω 会把 3.3 V 压到 0.48 V）。

**判据表**：
```
wv 脏            → 波表数据 / DDS 插值有问题
wv 干净、va 脏   → SVF / 包络 / VCA 有问题
va 干净、sd 脏   → 通道层 / 效果器 / 主输出有问题（先把 CC91/93/94 设 0 排除效果尾巴）
三路都干净       → 数字域干净，若耳机还炸则查 DAC / 功放 / 模拟
```

```text
① 对照组：program 3（长笛）——波表与路径都没变，应与以前一致
② 主判定：program 0/1 弹 C4 → 示波器 FFT 最强峰 260~265 Hz
           若 1046 Hz 有约 −17 dB 分量 = 钢琴表的 4 次谐波，正常
③ 按住 2 秒：声音应平稳持续（不再一击+长尾）
④ 和弦三音：应能分辨三个音，不再糊成一团
⑤ 若还炸：先分清是"偶发咔哒"（→ 预取时序）还是"持续宽带噪音"（→ 六路探针）
```

---

## 6. 常用命令

```powershell
# 重建 / 校验波表（在 wave_table 目录）
python rebuild_wave_table.py            # dry-run，只分析
python rebuild_wave_table.py --write    # 写两个产物 hex
python rebuild_wave_table.py --verify   # 回读产物 + 与快照逐行对比 + DDS 音高模型
python verify_rom_init.py               # 出位流后核对 INIT_RAM == 当前 hex

# 全系统编译（在 board/full_system 目录，便于 data/*.hex 被 $readmemh 找到）
iverilog -g2005 -o $env:TEMP\full.vvp -s full_system -I ..\..\rtl `
  (gci ..\..\rtl -recurse -filter *.v).FullName ..\..\simulation\models\gowin_prim_stub.v

# 专项仿真（在 board/full_system 目录）
vvp $env:TEMP\tb_wp.vvp     # tb_wave_pitch
vvp $env:TEMP\tb_sp.vvp     # tb_slot_probe

# P&R 是否真的重跑过：impl\pnr\full_system.tr 的时间戳必须晚于 cmd.do
```

---

## 7. 踩过的坑（新）

```text
① `buf` 是 Verilog 门级原语保留字！拿它当数组名会在**声明行**报
   "syntax error / invalid module item"，看起来像数组语法问题，其实是保留字。
② iverilog -g2005 不接受 `reg signed [23:0] a[0:N-1]`（带符号向量数组）；
   用无符号数组 + $signed() 比较即可。
③ Gowin 对全零的 INIT_RAM 块省略 defparam（缺失 = 0，不是错）。
④ 自己搭 voice_fetch 的 TB 时，ch_bend_ratio / ch_vib_ratio 必须接 Q2.14 的 16384，
   接 0 会让 apply_ratio 输出 0 → phase_inc=0 → 相位不动、完全没声音。
⑤ 不要用 `Get-Content -Raw` + `Set-Content` 改含中文的源码：会双重编码写坏文件
   （已踩：tb_wave_pitch.v）。改文件一律用编辑器工具，或 .NET ReadAllText/WriteAllText
   配 UTF8Encoding($false)。
⑥ 本工作区一度出现"子进程写盘被拒"（沙箱 ACL 未下发），DSH 的 write/edit 工具能写、
   python/pwsh 子进程不能写。切到完全权限后恢复。
```


---

# 2026-10-24 变更记录（显示接入 + 时序根治 + 表达力）

## 1. wave_fetch：rom_addr 打一拍（修 194 个 Setup 违例）★已验证
- 原写法：`rom_addr` 由组合 mux 直接驱动 ROM 的 AD 口 → 路径
  `an_r → 8选1 mux → ROM AD`，数据延时 21.6 ns（周期 20.345），slack **−1.227 ns**，194 个端点违例
- 改法：mux 结果打一拍再送 ROM；ROM 读延迟 1→2 拍，所以
  **存数索引 c−1 → c−2**、**扫描长度 NCT → NCT+1**（`c == NCT6 + 6'd1`）
- 结果：最差路径终点变成 `rom_addr_*_s0/D`，slack **+0.857 ns**（余量扩大约 60 倍）；0 违例
- 这条路径历史：10-22 +0.005 ns → 10-23 +0.014 ns → 接 LCD 后 −1.227 ns。**典型"贴线定时炸弹"**

## 2. ch_lfo：颤音深度 ×2（±0.5 → ±1.0 半音）
- `vib_d = vib_p >>> 6` 改 `>>> 5`；max mod_wheel(127) 时比例 16384±1000
- **颤音链路本来就是通的**（CC1 → mod_wheel → ch_lfo → ch_vib_ratio_bus →
  voice_fetch `vib_bend_ratio()` → `apply_ratio` → pf_phase_inc，预取每帧刷新）
  ⇒ 之前"没生效"其实是深度太小/从未测过

## 3. voice_mono：滤波器包络调制（filter_env_depth 第一版）
- `f_coeff_eff = l_f_coeff − ((32767 − env_value) >> 4)`，**打一拍**后送 SVF
- 只减不加 ⇒ 不会越过 Chamberlin SVF 稳定上限；env=满时 dip=0，env=0 时 dip=2047
- 目的：起音亮、尾音暗（原来是常量截止 → 音色单薄）
- 代价：+128 寄存器（8 泳道 × 16 位），最长逻辑级数 23→26

## 4. voice_alloc：力度平方曲线（vel_sensitivity 第一版）⚠未自动化验证
- `vel_gain_fn = {2'b0, vel, 7'd0}`（线性 vel<<7）→ `{9'd0,vel} * {9'd0,vel}`
- vel=127：16256 → 16129（差 0.09 dB，**最大响度不变**）
- vel=64：8192→4096（−6 dB）；vel=32：4096→1024（−12 dB）
- 在**分配器**里（每键一次），不在逐采样路径 ⇒ 无时序风险

## 5. soft_limiter：3 级 → 4 级流水（修 +0.013 ns 贴线）
- 违例路径：`mant_d2 → 切片 → 2 次查表 → 减 → 乘 → 加 → 48 位乘 → 移 → 减 → recip_d3`（20.255 ns）
- 拆法：插值结果先落 `recip_mant_d3`（含 `nk_d3`），THRESH 乘法放到下一级 → `recip_d4`；
  音频同步多延一拍（`l_d4/r_d4`），增益级改用级 4 信号
- 代价：整体延迟 +1 采样 = **+20.8 µs**（对 ≤10 ms 指标无影响）
- 验证：`tb_limiter` 5/5 PASS；`tb_limiter` 期望延迟已从 3 拍改 4 拍

## 6. ⚠⚠ 教训：两个"编译器不报错、时序也会过"的 bug
```
① 批量替换顺序错 → `recip_mant_d3 <= recip_mant_2` 锁存语句丢失
   → 该寄存器恒 0 → 限幅增益恒 0 → **过载时静音**（编译 0 错、时序 0 违例！）
② 新加寄存器漏复位 → 仿真里 X 经乘法污染整链输出
   （硬件上 Gowin 默认初始化 0，所以"上板可能侥幸正常"——正是最危险的那种）
⇒ 结论：**改完必须跑单元回归**（tb_limiter / tb_master_chain），不能只看编译通过
```

## 7. P&R 耗时波动（结论：不可预测，按 30~60 分钟预留）
```
构建            布局     Phase1    总计     违例
10-23 10:37    11m24s   32m20s   44m22s     0
10-23 22:35    16m08s   37m55s   54m49s    194
10-24 00:26A    9m22s   30m12s   40m03s     0
10-24 14:21C    7m59s    7m47s   16m16s     0   ← 最快
```
差异全在 Routing Phase 1（7m47s~37m55s）。规模/违例数都不是原因（C 版资源反而更多、
krit路径更紧）。**归因：布局器是确定性但对输入极敏感的退火，不同解 → 拥塞分布不同 → 迭代数差数倍。**
Phase2/3 若只有几秒，说明布线一次过、无需修时序。

## 8. 弯音（Pitch Bend）现状：**链路已全通，只差上板验证**
```
midi_filter 4'hE → F_BEND_VALUE(5'd15)  ✔
chan_table apply_field → 写 B_BVALUE，用 bend_tbl(64 项)双点插值算 B_BRATIO ✔
rd_bend_ratio → 影子模块 → ch_bend_ratio_bus → voice_fetch ✔
voice_fetch vib_bend_ratio() 合成 → apply_ratio → pf_phase_inc（预取每帧刷新）✔
```
- 当年"接上就 566→1092 违例"的问题，**已被 10-21 的三级预取流水线顺带解决**
  （baseline_A/C 都含这条链，且都是 0 违例）
- 所以不需要"活跃声部 phase_inc 重算"：预取每帧刷一次，按住不动的音也会跟着弯
- 上板测试：`bend 8192 / 16383 / 0`，范围 ±2 半音（B_BRANGE 复位值 2）

## 9. 待排查：仿真里 sample_l 恒为 X（只影响仿真，不影响上板）
```
10-22 的整链 dump 就已出现：512 帧里 507 帧 sample_l = X，
而 voice_aud / ch_l / dbg_va_r 都正常 ⇒ X 产生在"通道层之后、sample_l 之前"
最可能是 dither16 / dc_block / master_chain 之一有寄存器没被复位覆盖
后果：tb_full_system / tb_vel_amp / tb_timbre_e2e 这些"读 sample_l"的整链测试全部失效
（tb_vel_amp 因此无法验证力度曲线）
硬件上 Gowin 默认初始化为 0 ⇒ 上板无此问题
```

## 10. 位流备份约定（重要：Gowin 每次综合**原地覆盖** .fs）
```
目录：scratch/backups/
命名：baseline_<标签>_<日期>_<时分>_<改了什么>/
内容：full_system.fs + .tr + .rpt.txt + .timing_paths + .cst/.sdc/.gprj + README.md
现有：
  baseline_A_20261024_0026_display_romaddr_fix        （显示 + rom_addr 打拍）
  baseline_C_20261024_1421_display_romaddr_vibrato_filterenv（+ 颤音 + 滤波包络）
```

## 11. 赛题验收要点（详见 documents/赛题要求_原文.md）
```
基础：① ≥2 维自研交互（**在 majiao 手里，快做完**）② 逐样本合成 + 延迟 ≤10 ms
      ③ 复音 ≥4（我们 32）
拓展：① 复音 ≥32 → 测试模式 32 个对数振荡器，C24 探针 + FFT 数谱峰
      ② ≥3 维表情 + ≥2 音色 + 三种效果器（力度/表情/截止/谐振/起音/颤音/弯音）
      ③ 延迟 ≤5 ms + 可视化（LCD 波形，本轮集成）
      ④ LED 曲目指引（"实现"=必做）+ 蓝牙/App（"可搭载"=可选）
         ⚠ 我们**很可能放弃这一整条**（已与用户确认）
核心评分：活跃振荡器数 × 采样率 = 32 × 48 kHz = 1.536 M/s；现场要能数出 32 条谱峰
```

## 12. test_web（电脑端调试工具）按赛题需要的补充（只报告，未修改）
```
P0：CC 面板（CC11/74/71/73/72/7）、弯音滑杆、效果器开关（91/93/94）、和弦/齐发（4/8/16/32 音）
P1：端口提示（CC7/10/91/93/94 只在混音口 port3/A17 生效）、一键演示流程、单次事件打点计时
P2：测试模式提示、ADSR 可视化、预设保存
```

## 13. 文档状态
- `documents/技术文档.md` 原封未动
- 合并版在 `scratch/agent/技术文档_合并版_20261024.md`（826 行）：
  7 条附录勘误已就地插入正文（5 处带【勘误并入】标记）+ 新增「2026-10-17~10-23 变更」9 小节
- PT8211 规格已从 `测试清单.md` 迁入 `documents/硬件实现.md` 附录 C，测试清单已删除


---

# 2026-10-28 时序墙与混响噪声：结构性方案（P&R 进行中，先记下来）

## 一、PR0004 与"时钟资源墙"（来自上一轮对话，已验证的结论）

```
PR0004 "There are total 0 unrouted nets" ≠ 布不通，而是**布线器在 Phase 1 后放弃了 Phase 2/3**。
判别口诀（看 impl/pnr/full_system.rpt.txt）：
    Routing Phase 2 = 0m02s / Phase 3 = 0s  →  已撞墙，立刻停，别等
根因：rpt.txt 第 5 节 "Clock Resource Usage Summary"
    PRIMARY 8/8、LW 8/8（100%）→ 长线/时钟资源耗尽
解法：Place & Route → Configuration → Place → **Place Option** 改成 1（routability priority）
    → PRIMARY 7/8→5/8、LW 8/8→7/8，一次通过；代价是走线变长、时序变差
顺序：先试 2（timing priority），不行退 1
实测（2026-10-28，place_option=1）：
    布线跑完、出位流，但 **167 个 Setup 违例 / 最差 −2.184 ns / Fmax 44.388 MHz**，
    PRIMARY/LW **仍是 8/8、8/8**（说明 place_option 只影响"布得通"，不影响时钟资源占用）
    烧录现象：**不定期爆音**、混响无法分辨（延迟器那条 −2.18 ns 导致了数据出错）
```

## 二、烧违例版位流的历史规律（来自上一轮对话，重要）

- 烧过的版本**全部带违例**，功能层面全部正常（出声/音高/力度/CC/panic/32 复音/PC 都正常），
  从未出现跑飞、状态卡死、无法复位。
- 曾经的"失真"后来查明是**混响 bug**，不是时序。
- 唯一干净对照：同网表 place_option 1（−6.767/540 违例）vs 2（−3.323/509 违例）听感无差别。
- ⚠ 但 2026-10-28 这次（−2.184 ns）出现了**不定期爆音** ⇒ 延迟器路径的时序错误是**可听的**。
- 结论：可以烧违例版做调试，但**音频数据通路的违例必须修**（控制通路的可以忍）。

## 三、已做的时序修复（2026-10-28）

1. `fx_delay.v`：RAM 读出 → ×p_fb（24×16 变量乘）→ 48 位加 → sat24 → 写回，22.469 ns。
   在 wl/wr 后插一级寄存（`wl_r/wr_r`），反馈与湿声混音都用打拍值。
   代价：延迟时间 +1 采样（+20.8 µs）。
2. 若 `u_sched/g_mvol_11 → u_lim/env_d1_*`（−2.179 ns）成为新最差 → 同样插一级寄存（控制路径，安全）。

## 四、结构性方案（如果局部插寄存器还不够）

### A. 降低时钟/长线资源占用（治本）
```
思路：PRIMARY/LW 被"高扇出控制网络"占满。逐个排查这些信号：
    sample_stb（48 kHz 节拍，扇出≈全设计）、slot_vld、rst_n_sync、pf_vld、fx 的 en
做法（按代价排序）：
 ① 手动复制驱动（fanout tree）：把一个 strobe 拆成 4 份寄存器，各驱一片逻辑
    → 综合器不再把它提升为时钟/长线网络
 ② 本地生成节拍：不在全局分发 sample_stb，各模块用计数器自己产生"每 1024 拍一次"
 ③ 减少时钟域：LCD 像素时钟改用 clk50 分频（省 1 个 PLL + 1 条 PRIMARY），
    代价是刷新率下降（50/2 = 25 MHz → 约 30 Hz）
 ④ 拆分工程：音频一个工程、显示一个工程，分别烧不同位流（最后手段）
```

### B. 混响"沙沙"（结构性）
```
先说量级：每级截断噪声 ~1 LSB @24 位 = −144 dBFS，经回路增益 18.5（+25 dB）→ −119 dBFS
⇒ **纯截断不可能听得到**。所以噪声另有来源，候选：
 ① SD 调制器在输入接近 0 时的空闲极限环（1 位 SD 的经典问题）
 ② dc_block 的低频极限环（极点在 10~20 Hz 时容易自激，低音量时暴露）
 ③ 混响回路在 sat24 边界上的极限环（尤其 damping/decay 调大后）
排查手段（便宜、有效）：
 · 仿真：给 reverb 喂 0 输入、跑 1 s，看输出是否有非零周期信号（极限环）
 · 若确认是极限环 → 在回路里加 1 LSB 的抖动（TPDF）或把 sat24 换成软饱和
结构性改法（按代价）：
 ① 混响返回加**噪声门**（|wet| 小于阈值且无干声 → 0）：~80 LUT，静音段彻底干净
 ② 内部位宽 24 → 32 位：BSRAM 166 → 约 200（340 够），噪声降 48 dB
 ③ 减到 4 个梳状（噪声 −3 dB，空间感变差）—— 不推荐
```

## 五、当前分支状态
```
分支 feature/fix（从 feature/display 合入 develop 之后拉的）
未提交改动：voice_mono(滤波包络 >>5)、fx_reverb(四舍五入 + 湿声 (1,2,1)/4 高切 + damping 14000)、
            fx_delay(反馈路径加流水)、以及 G 版之前的全部改动
已归档位流：baseline_F（20:28，释放修复确认）
```


---

# 当前任务顺序（2026-10-29 记录，用户定的）

## 优先级
```
① **当前任务**：本轮 2 处改动（波表槽 4/5 + vg_of 每音色增益）上板验证
   → 用户中午验证；没问题他会做一轮 git 操作，然后提醒开始 ②
② **频谱显示**（下一步，用户明确优先）
③ **SysEx 实时编辑音色参数**（用户标注"不一定做？"，等 ② 之后再定）
```

## ① 本轮待验清单（2026-10-29）
```
· 槽 5 铜管：是否不再"电子"（原值是个幅度 24000 的**方波**，现换成候选 A）
· 槽 4 Pad：是否与槽 6 区分开（原来两者峰值/RMS 完全相同 = 重复波形）
· 响度：槽 4/5 是否与其它槽接近（vg_of：4→31975，5→61536）
· 其它 6 槽行为应完全不变（波表位模式未动）
· 回归：混响不炸 / 释放尾巴 / SysEx 主音量 / B21 探针
当前未提交改动：board/data/wave_table.hex、voice_fetch.v(×2)、两个文档
```

## ② 频谱方案（已定稿，待用户确认后开写）
```
布局   A：波形占 0~380 行，底部 380~480（100 px）画频谱柱
频带   **32 根对数分布**：f_i = 60 × (16000/60)^(i/31)，i=0..31
算法   **Goertzel 组**（不用 FFT）：y = x + 2cosω·y1 − y2
       32 频带顺序执行 = 32 拍/采样（1024 拍可用）⇒ 只占 1 个乘法器、3% 时钟
显示   幅度 → 20log10 → 0~100 px；attack 1 帧、release ≈200 ms
时钟   计算在音频域 clk_sys，结果写 **32×8 位双口 BSRAM**（1 块），
       渲染在已有 rtl/vis/（像素域）⇒ **不新增时钟域**（避开 PRIMARY/LW 8/8 时钟墙）
成本   DSP +1、LUT ≈ +400、BSRAM 166→167
新增   rtl/vis/spec_band.v
修改   rtl/vis/wave_render.v（底部画柱）、rtl/vis/vis_top.v（接线）
验证   仿真喂扫频信号 → 柱子应随频率依次点亮
可选   用某个 CC 切三种模式：0 仅波形 / 1 波形+频谱（默认）/ 2 全屏频谱
```

## ③ SysEx 实时编辑音色（暂缓）
```
已完成的地基：vg_of()（8×16 位可写初值）、SysEx field 0~8 编号表（已交网页端）
未做：tp_ram（8 槽 × 100 位寄存器组）、ev_tp_wr/slot/idx/val 写入通道、
      full_system 写入译码
代价：约半天 + 一轮综合；风险中等（要改 tp_of 那一整块）
价值：以后调音色不用综合（省每轮 1~1.5 小时）
```
