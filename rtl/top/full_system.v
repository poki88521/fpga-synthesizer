//============================================================================
//  full_system —— 全系统集成顶层（三边合一的唯一入口）
//
//  组成：
//    · full_top          —— 模块三（sakiko）：通道处理层 + 全局处理层 + 主输出 + I2S
//    · sched_subsystem   —— 调度层（poki）：MIDI 解析/分配/表读写/预取/写回
//    · voice_mono × P    —— 单声部层（majiao）：DDS + SVF + ADSR/VCA
//    · wave_fetch + wave_table_rom —— 共享波表取数（majiao）
//
//  数据流：
//    MIDI → sched_subsystem ─┬─ ext_volume…ext_send_del ──▶ full_top（通道表）
//                            ├─ pf_phase_inc/timbre/gate ─▶ voice_mono × P
//                            └─ frame_stb/slot/slot_vld ──▶ 同步
//    voice_mono × P ─ aud_in/ch_in/vld ─▶ full_top ─▶ PT8211（BCK/WS/DIN）
//    voice_mono 运行状态 ─ rs_* ─▶ sched_subsystem（写回声部状态表）
//
//  ⚠ 三个 `VOICE_SRC/EXT_TABLE/EXT_FXPARAM` 参数：
//    本层固定 **VOICE_SRC=1 / EXT_TABLE=1 / EXT_FXPARAM=0**
//    —— 声部与通道表来自调度层，**效果参数用 full_top 内置默认值**
//    （`EXT_FXPARAM=0` 是刻意选择：效果参数不走调度层，三者本就独立，不需要"同时置 1"）。
//
//  ⚠ 端口名说明：`full_top` 内部已有 wire `sample_stb`，故对外叫 `sample_stb_o`；
//     调度层的 `frame_stb` 与它同源。
//
//  时钟 / 复位：
//    · clk50 / clk12288 同 full_top（USE_PLL=0 时只用 clk50）
//    · 复位由 `full_top` 内部产生（POR + PLL 锁定），经 `rst_n_sync_o` 给调度层，
//      保证全系统**同一复位沿**
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module full_system #(
    parameter integer USE_PLL            = 1,      // 上板用 1（49.152 MHz）；仿真 bring-up 可用 0
    parameter integer P                  = 8,
    parameter integer G                  = 4,
    parameter integer NCH                = 16,
    //  ⚠⚠ 2026-10-19：STRIDE 从 8 改成 32。
    //     原因：wave_fetch 每个时隙要串行扫 **2P = 16 个地址**（全片只有一份波表 ROM），
    //     而 STRIDE=8 让时隙每 8 拍就来一次 → 扫描指针被反复清零、**永远扫不完**。
    //     实测：每帧 slot_vld 4 次，rom_rdy 只有 **1 次** → 4 个时隙里 3 个拿不到波表数据，
    //     wave_out 停在旧值 → 输出变成阶梯状低频噪音（实板听感就是"炸/乱码"）。
    //     STRIDE=32 时：时隙在 1/33/65/97，扫描 17 拍完成，余量充足；
    //     4 个时隙 + 通道层 48 拍 ≈ 169 拍 / 1024，占 16.5%。
    parameter integer STRIDE             = 32,     // ⚠ 必须与调度层一致（且 ≥ 2P+余量）
    parameter integer N                  = P*G,    // 声部数 = 32
    parameter integer PA_DELAY           = 22,
    parameter integer POR_BITS           = 22,
    parameter integer TEST_MODE_DEFAULT  = 1,      // ⚠ 2026-10-17 改为 1：上电进测试模式（32 谱线，
                                                //   便于现场用频谱仪数峰）；首音到达自动切回正常合成

    // ---- 音色参数占位（音色参数表尚未实现，见 poki 交付说明 §五.1）----
    //  这些值会分发给 P 个 voice_mono。等音色参数表到位后，把这里换成
    //  "从 timbre_slot 查表" 即可，**接口不用改**。
    parameter integer DEF_F_COEFF        = 30000,  // SVF 频率系数（Q1.15，存 sin(πfc/fs)）
    parameter integer DEF_Q_COEFF        = 16384,  // SVF 阻尼（Q1.15，1.0 → Q=0.5）
    parameter integer DEF_FILTER_TYPE    = 0,      // 0=LP 1=BP 2=HP
    parameter integer DEF_WAVE_SEL       = 0,
    parameter integer DEF_ADSR_CURVE     = 0,      // 0=线性 1=指数
    parameter integer DEF_ATTACK_STEP    = 5,      // ≈125 ms @48 kHz
    parameter integer DEF_DECAY_STEP     = 20,
    parameter integer DEF_SUSTAIN_LEVEL  = 20000,  // Q1.15
    parameter integer DEF_RELEASE_STEP   = 8,
    //  ⚠ **不能写 `parameter integer`**：带类型限定就传不了字符串，
    //     实测 `"wave_table.hex"` 会被当成 0 → `$readmemh` 永不执行 →
    //     ROM 读出 X → 整条音频链全 X。字符串参数必须**不写类型**。
    //  ⚠ 路径相对**综合/仿真的工作目录**，不是相对本文件。
    //     默认给仓库里的相对路径，Gowin 工程根设在仓库根即可直接命中。
    //     （空字符串会让 $readmemh 永不执行 → 波表全 X → 整链无声，勿改回 ""）
    parameter         WAVE_INIT_FILE     = "data/wave_table.hex"
)(
    // ---- 时钟 ----
    input  wire         clk50,
    input  wire         clk12288,       // N22（USE_PLL=1 时用）

    // ---- MIDI（4 路串行，外部需先两级同步）----
    input  wire [3:0]   midi_rx,

    // ---- MS5351 I2C（上电配置 CLK2 = 24.576 MHz，见 rtl/common/ms5351_init.v）----
    output wire         scl,
    inout  wire         sda,
    output wire         mux_sel0,
    output wire         mux_sel1,
    output wire         mux_sel2,

    // ---- I2S 输出 ----
    output wire         HP_BCK,
    output wire         HP_WS,
    output wire         HP_DIN,
    output wire         PA_EN,

    // ---- 调试 LED（4 个空闲用户 LED，上板排查用）----
    //    [2:0] = 泳道 0 的 timbre_slot —— 发 pc N 应该跟着变（8 种组合）
    //    [3]   = 声部激活的上升沿展宽 40 ms —— 可接示波器测"按键→出声"延迟
    //  ⚠ 正式演示若不想要灯闪，把这几个 IO_LOC 注释掉即可（不影响功能）。
    output wire [3:0]   dbg_led,

    // ---- 1 位 sigma-delta 音频探针（PMOD1_IO0 / J24 第 1 脚，C24）----
    //    = sample_l 的一阶 SD 调制，**绕过 PT8211 DAC / 功放 / 耳机口**。
    //    用途：示波器测这一路 → FFT，看 FPGA 内部真正送进 DAC 的音频。
    //      这一路干净、耳机却炸 → 问题在 DAC / 功放 / 模拟通路
    //      这一路也炸           → 问题在 FPGA 内部
    output wire         dbg_sd,      // = sample_l      （整链最终输出，PMOD1_IO0 / C24）

    // ---- 2026-10-21 加的**分级**音频探针（同为 1 位 SD，便于一次定位"炸"在哪一级）----
    //    把中间信号也引出来，示波器一路一路比：
    //      dbg_sd_wv : CPU 内 DDS 波表输出（SVF/包络之前）  → 看波表本身干不干净
    //      dbg_sd_va : voice_aud[泳道0]（SVF+包络+VCA 之后）→ 看滤波器/包络有没有制造失真
    //      dbg_sd    : sample_l（通道+效果+主输出之后）      → 看后级有没有再添油加醋
    output wire         dbg_sd_va,   // PMOD1_IO1（J24 第 2 脚，E25）
    output wire         dbg_sd_wv,   // PMOD1_IO2（J24 第 3 脚，L17）

    // ---- 2026-10-23 加：800x480 LCD 波形可视化（sakiko 的 vis_top）----
    //    数据源是 full_top 的 mon_l（= sample_l 直连），**不影响音频通路**。
    //    引脚与面板时序取自已上板验证的 board/myProjForMWhichVis 工程。
    output wire         lcd_clk,     // H21
    output wire         lcd_en,      // A24
    output wire [5:0]   lcd_r,       // H19 J19 G25 H18 J18 K17（RGB666，高 6 位）
    output wire [5:0]   lcd_g,       // J16 K15 F22 G22 G21 G20
    output wire [5:0]   lcd_b,        // F20 G19 F19 F18 M17 M16

    // ---- 2026-10-25 加：延迟测量探针（示波器用）----
    //    第一个『有门控且音频非零』的采样帧拉高，松开音后拉低（上升沿 = 出声时刻）
    output wire         dbg_audio_on
);

assign dbg_led[3] = ~(dbg_evt_cnt != 22'd0);      // 同上，低电平点亮


    // ========================================================================
    // 0. MS5351 上电配置（必须用 clk50，不能用 PLL 输出 —— 否则死锁）
    //
    //    MS5351 上电默认输出 16 MHz。若此时 pll_49m 自由跑，会锁到 16 MHz
    //    → 输出 ≈32 MHz 而不是 49.152 MHz → 采样率和 MIDI 波特率全错。
    //    所以先用 I2C 把 CLK2 配成 24.576 MHz（MS2 ÷32），配置表与
    //    board/pll_test/pll_test.v（上板实测锁定成功的版本）逐字节一致。
    //
    //    时序余量：本模块耗时 ≈ 2 ms(S_SETTLE) + 26 项 ×0.3 ms ≈ 8 ms；
    //    full_top 的 POR（POR_BITS=22）≈ 84 ms @50 MHz，足够覆盖。
    //    若将来调小 POR_BITS，必须重新核算这个先后关系。
    // ========================================================================
    wire ms_ok;
    ms5351_init #(
        .CLK_HZ(50_000_000),      // clk50 是板载 50 MHz
        .I2C_HZ(100_000)
    ) u_ms5351 (
        .clk      (clk50),
        .scl      (scl),
        .sda      (sda),
        .mux_sel0 (mux_sel0),
        .mux_sel1 (mux_sel1),
        .mux_sel2 (mux_sel2),
        .ok       (ms_ok)
    );

    // ========================================================================
    // 1. 模块三：full_top（提供节拍 + 通道/全局/主输出）
    // ========================================================================
    wire         sample_stb;       // 全系统唯一提交时刻
    wire         rst_n_sync;
    wire         clk_sys;
    wire [13:0]  g_master_vol_w;    // 2026-10-24: SysEx master volume          // full_top 的系统时钟（USE_PLL=1 时 = PLL 的 49.152 MHz）
    wire [P*24-1:0] voice_aud;     // 单声部层 → 通道层
    wire [P*24-1:0] voice_dbg_wave; // 调试探针：各泳道的 DDS 波表输出（只用泳道 0）
    wire [23:0]     dbg_va_w;       // 调试探针：voice_aud 泳道 0
    wire [23:0]     dbg_wv_w;       // 调试探针：DDS 输出 泳道 0

    // 2026-10-23：可视化音频抽头（来自 full_top 的 mon_l/mon_r，纯直连）
    wire [15:0]     mon_l_w;
    wire [15:0]     mon_r_w;

    wire [P*4-1:0]  voice_ch;
    wire [P-1:0]    voice_vld;
    wire [P-1:0]    voice_data_vld;   // 每声部"音频就绪"脉冲（voice_mono 内部 vca_en）
    wire            voice_data_vld_any;
    wire [P-1:0]    voice_data_gate;  // 与音频同拍的门控（voice_mono 在 dds_en 锁存）
    wire [P*4-1:0]  voice_data_ch;    // 与音频同拍的通道号

    // 调度层 → full_top 的通道表参数
    wire [NCH*7-1:0]  ext_volume, ext_expression, ext_send_rev, ext_send_cho, ext_send_del;
    wire [NCH*16-1:0] ext_pan_gL, ext_pan_gR;

    full_top #(
        .USE_PLL          (USE_PLL),
        .P                (P),
        .G                (G),
        .NCH              (NCH),
        .STRIDE           (STRIDE),
        .PA_DELAY         (PA_DELAY),
        .POR_BITS         (POR_BITS),
        .TEST_MODE_DEFAULT(TEST_MODE_DEFAULT),
        .VOICE_SRC        (1),      // 声部来自单声部层
        .EXT_TABLE        (1),      // 通道表来自调度层
        .EXT_FXPARAM      (0),      // 效果参数用内置默认（见文件头说明）
        .MVOL_EXT         (1),           // 2026-10-24: master volume from SysEx
        .INTEG_CLAMP      (1)       // 结构保证：复位期间钳住 ext_*
    ) u_full_top (
        .clk50(clk50), .clk12288(clk12288),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),

        .ext_aud_in(voice_aud), .ext_ch_in(voice_ch), .ext_vld(voice_vld),
        .ext_any_gate(any_gate),
        .ext_data_vld(voice_data_vld_any),
        .ext_data_gate(voice_data_gate), .ext_data_ch(voice_data_ch),
        .ext_volume(ext_volume), .ext_expression(ext_expression),
        .ext_pan_gL(ext_pan_gL), .ext_pan_gR(ext_pan_gR),
        .ext_send_rev(ext_send_rev), .ext_send_cho(ext_send_cho),
        .ext_send_del(ext_send_del),
        //  EXT_FXPARAM=0 → 以下端口不被使用，喂确定值避免 X
        .ext_reverb_size(16'sd0), .ext_reverb_decay(16'sd0),
        .ext_reverb_damping(16'sd0), .ext_reverb_pre_delay(16'd0),
        .ext_reverb_return(16'sd0),
        .ext_chorus_rate(16'd0), .ext_chorus_depth(16'sd0),
        .ext_chorus_mix(16'sd0), .ext_chorus_return(16'sd0),
        .ext_delay_time(16'd0), .ext_delay_feedback(16'sd0),
        .ext_delay_mix(16'sd0), .ext_delay_return(16'sd0),
        .ext_master_vol(g_master_vol_w), .ext_mute(1'b0), .ext_test_mode(1'b0),

        .midi_rx    (midi_rx),
        .pll_hold   (~ms_ok),          // MS5351 配好前把 PLL 按住（详见 full_top.v 端口注释）
        .sample_stb_o(sample_stb),
        .rst_n_sync_o(rst_n_sync),
        .clk_sys_o  (clk_sys),         // ⚠ 外部三层统一用这根，不要用 clk50
        .dbg_sd     (dbg_sd),          // 1 位 SD 音频探针 → PMOD1_IO0
        .dbg_voice_aud(dbg_va_w),      // 泳道 0 的 VCA 输出 → 另一路 SD 探针
        .mon_l      (mon_l_w),         // 2026-10-23：可视化抽头（= sample_l）
        .mon_r      (mon_r_w)
    );

    // ========================================================================
    // 1.5 分级音频探针（2026-10-21）：把中间信号也调成 1 位 SD
    //
    //  ⚠ 只取 24 位采样右移 8 位（Q1.23 → Q1.15），因为 sd_out 的反馈满幅是 ±32767。
    //  ⚠ 这两路**不参与任何功能**，只驱动两个 PMOD 引脚；不接示波器时完全不影响声音。
    // ========================================================================
    assign dbg_wv_w = voice_dbg_wave[23:0];      // 泳道 0 的 DDS 输出

    sd_out u_sd_va (
        .clk   (clk_sys),
        .rst_n (rst_n_sync),
        .x     (dbg_va_w[23:8]),                 // 泳道 0 的 VCA 输出（22 位到 16 位）
        .sd    (dbg_sd_va)
    );

    sd_out u_sd_wv (
        .clk   (clk_sys),
        .rst_n (rst_n_sync),
        .x     (dbg_wv_w[23:8]),                 // 泳道 0 的 DDS 波表输出
        .sd    (dbg_sd_wv)
    );

    // ========================================================================
    // 1.6 800x480 LCD 波形可视化（2026-10-23 接入，sakiko 的 vis_top）
    //
    //  来源：board/myProjForMWhichVis（**已上板验证**的那一版，不是 alpha 旧版）
    //    · vis_audio 用"写端口自刷"代替 initial for 循环（旧版会 EX3934 降级成黑盒）
    //    · pll_pixel 显式接死 SSC/动态相移等 13 个配置口（消 28 条 EX2565）
    //
    //  时钟：像素域 35 MHz 由 vis_top 内部的 pll_pixel 从 clk50 生成（独立时钟域）。
    //  数据：sample_l 直连（mon_l_w），**不新增寄存器**，音频通路零影响。
    //  面板：800x480，H_FP=210 H_BP=182 V_FP=45 V_BP=8 → 1192x533 @ 55.09 Hz。
    // ========================================================================
    vis_top u_vis (
        .clk_sys   (clk_sys),
        .rst_sys_n (rst_n_sync),
        .sample_stb(sample_stb),
        .sample_l  (mon_l_w),
        .clk50     (clk50),
        .lcd_clk   (lcd_clk),
        .lcd_en    (lcd_en),
        .lcd_r     (lcd_r),
        .lcd_g     (lcd_g),
        .lcd_b     (lcd_b),
        .pll_lock_o(),            // 暂不引出
        .dbg_wp    (),            // 暂不引出
        .dbg_start ()
    );


    wire [1:0]      slot;
    wire            slot_vld;
    wire            pf_vld;
    wire [P*32-1:0] pf_phase_inc;
    wire [P*3-1:0]  pf_timbre;
    wire [P*7-1:0]  pf_note;
    wire [P*16-1:0] pf_vel_gain, pf_vca_gain;
    wire [P*4-1:0]  pf_ch;
    wire [P-1:0]    pf_gate, pf_fast_rel, pf_sust_pedal;

    //  有任意声部在响 → 首音到达即退出测试模式（32 谱线 → 正常合成）
    wire any_gate = |pf_gate;

    wire [P*32-1:0] rs_phase_acc;
    wire [P*16-1:0] rs_env_value;
    wire [P*3-1:0]  rs_env_state;
    wire [P*32-1:0] rs_filter_ic1, rs_filter_ic2;

    sched_subsystem #(
        .P(P), .G(G), .NCH(NCH), .STRIDE(STRIDE), .N(N)
    ) u_sched (
        .clk(clk_sys), .rst_n_sync(rst_n_sync),
        .frame_stb(sample_stb),
        .midi_rx(midi_rx),

        .slot(slot), .slot_vld(slot_vld),

        .ext_volume(ext_volume), .ext_expression(ext_expression),
        .ext_pan_gL(ext_pan_gL), .ext_pan_gR(ext_pan_gR),
        .ext_send_rev(ext_send_rev), .ext_send_cho(ext_send_cho),
        .ext_send_del(ext_send_del),
        .ext_attack_mod(ext_attack_mod), .ext_release_mod(ext_release_mod),
        .ext_reson_mod(ext_reson_mod),   .ext_cutoff_mod(ext_cutoff_mod),

        .pf_vld(pf_vld), .pf_phase_inc(pf_phase_inc), .pf_timbre(pf_timbre),
        .pf_note(pf_note), .pf_vel_gain(pf_vel_gain), .pf_vca_gain(pf_vca_gain),
        .pf_ch(pf_ch), .pf_gate(pf_gate), .pf_fast_rel(pf_fast_rel),
        .pf_sust_pedal(pf_sust_pedal),

        .rs_phase_acc(rs_phase_acc), .rs_env_value(rs_env_value),
        .rs_env_state(rs_env_state), .rs_filter_ic1(rs_filter_ic1),
        .rs_filter_ic2(rs_filter_ic2),
        .g_master_vol_o(g_master_vol_w)
    );

    // ========================================================================
    // 3. 单声部层 + 共享波表
    // ========================================================================
    wire [P*14-1:0] rom_addr_n, rom_addr_n1;
    wire [P*16-1:0] tab_n, tab_n1;
    wire            rom_rdy;

    //  共享波表取数：每时隙扫 2P 个地址，回填 P 组两点
    wave_fetch #(
        .P(P), .AW(14), .DW(16), .INIT_FILE(WAVE_INIT_FILE)
    ) u_wfetch (
        .clk(clk_sys), .rst_n_sync(rst_n_sync),
        .sample_en(slot_vld),                 // 时隙节拍
        .addr_n_flat(rom_addr_n), .addr_n1_flat(rom_addr_n1),
        .rdy(rom_rdy),
        .tab_n_flat(tab_n), .tab_n1_flat(tab_n1)
    );

    //  音色参数占位（等音色参数表到位后换成查表，接口不变）
    wire [15:0] def_f_coeff  = DEF_F_COEFF[15:0];
    wire [15:0] def_q_coeff  = DEF_Q_COEFF[15:0];
    wire [1:0]  def_ftype    = DEF_FILTER_TYPE[1:0];
    wire [1:0]  def_wsel     = DEF_WAVE_SEL[1:0];
    wire [1:0]  def_acurve   = DEF_ADSR_CURVE[1:0];
    wire [15:0] def_astep    = DEF_ATTACK_STEP[15:0];
    wire [15:0] def_dstep    = DEF_DECAY_STEP[15:0];
    wire [15:0] def_slevel   = DEF_SUSTAIN_LEVEL[15:0];
    wire [15:0] def_rstep    = DEF_RELEASE_STEP[15:0];

    //  ⚠ 2026-10-17 新增：通道级实时音色调制（CC71/72/73/74）
    //     语义：64 = 中心（等于上面的编译期默认值），<64 减小，>64 增大
    //     换算在每声部（generate 里）按自己的通道号取，见 g_voice 内
    wire [NCH*7-1:0] ext_attack_mod;
    wire [NCH*7-1:0] ext_release_mod;
    wire [NCH*7-1:0] ext_reson_mod;
    wire [NCH*7-1:0] ext_cutoff_mod;

    //========================================================================
    //  音色参数表（2026-10-19）
    //
    //  背景：原来 8 个音色**只有波表槽不同**，ADSR/滤波器/增益都是同一组常量，
    //        所以听起来"只有音高变了、性格一样"。这里给每个音色槽一份独立参数。
    //
    //  用法：按本泳道的 pf_timbre（3 位）查表得到基准值，
    //        再叠加 CC71/72/73/74 的通道级实时调制（见下面 cut_s/res_s/atk_s/rel_s）。
    //
    //  字段打包（100 位）：
    //    [99:84] f_coeff       截止基准（Q1.15，存 sin(pi*fc/fs)）
    //    [83:68] q_coeff       阻尼基准（Q1.15，**越小谐振越强**）
    //    [67:66] filter_type   0=低通 1=带通 2=高通
    //    [65:64] adsr_curve    0=线性 1=指数
    //    [63:48] attack_step   起音步长（越大起音越快）
    //    [47:32] decay_step    衰减步长
    //    [31:16] sustain_level 持续电平（Q1.15）
    //    [15:0]  release_step  释放步长（越大释放越快）
    //
    //  ⚠ 这些数值是按"波形特性 + 目标音色性格"推算的，**最终要上板听再调**。
    //    换算公式与设计依据见 documents/音色参数表.md。
    //========================================================================
    function [99:0] tp_of;
        input [2:0] s;
        begin
            case (s)
                //  槽 0  波表=钢琴（基频 85.7% + 4 次谐波 13.3%，2026-10-22 重建）→ LP 高截止、慢起 341 ms、长延音
                3'd0: tp_of = {16'd30000, 16'd22000, 2'd0, 2'd0, 16'd2,   16'd1,  16'd24000, 16'd1  };
                //  槽 1  波表=吉他（基频 97.3% + 2 次谐波 2.4%，2026-10-22 重建）→ LP 中截止、快起、有衰减尾巴
                3'd1: tp_of = {16'd16384, 16'd16384, 2'd0, 2'd0, 16'd341, 16'd3,  16'd8000,  16'd2  };
                //  槽 2  波表=管风琴（旧表，未重建）→ LP 低截止 q 高、极慢起 682 ms、柔和
                3'd2: tp_of = {16'd8480,  16'd22000, 2'd0, 2'd0, 16'd1,   16'd1,  16'd26000, 16'd1  };
                //  槽 3  波表=长笛（旧表，未重建）→ **带通** f=5340 q=12000、中速起：偏铜管/木管
                3'd3: tp_of = {16'd5340,  16'd12000, 2'd1, 2'd0, 16'd17,  16'd3,  16'd20000, 16'd2  };
                //  槽 4  波表=旧合成波（未重建）→ LP f=12540 q=20000、柔和木管感
                3'd4: tp_of = {16'd12540, 16'd20000, 2'd0, 2'd0, 16'd11,  16'd1,  16'd22000, 16'd2  };
                //  槽 5  方波   → 电子主音：快速、尖锐、带通 + 较强谐振
                3'd5: tp_of = {16'd16384, 16'd8000,  2'd1, 2'd0, 16'd137, 16'd7,  16'd20000, 16'd4  };
                //  槽 6  波表=旧合成波（未重建，基频强、谐波丰富）→ LP f=4277 **q=4000 强谐振**：锯齿扫频/弦乐感
                3'd6: tp_of = {16'd4277,  16'd4000,  2'd0, 2'd0, 16'd34,  16'd3,  16'd20000, 16'd2  };
                //  槽 7  波表=旧合成波（未重建）→ LP f=23170、极快起 682、无持续（sus=0）：拨弦/打击
                3'd7: tp_of = {16'd23170, 16'd16384, 2'd0, 2'd0, 16'd682, 16'd14, 16'd0,     16'd1  };
                default: tp_of = {16'd30000, 16'd16384, 2'd0, 2'd0, 16'd5, 16'd20, 16'd20000, 16'd8};
            endcase
        end
    endfunction

    genvar gi;
    generate
        for (gi = 0; gi < P; gi = gi + 1) begin : g_voice
            // ---- CC71/72/73/74 → voice_mono 参数（按本声部的通道号取）----
            //  64 = 中心 = 不调制（等于编译期默认值）。
            //  f_coeff / q_coeff 用 <<8 的偏移；attack/release 用 >>1 的偏移。
            wire [3:0]        vch   = voice_ch[gi*4 +: 4];
            wire [6:0]        m_cut = ext_cutoff_mod[vch*7 +: 7];
            wire [6:0]        m_res = ext_reson_mod [vch*7 +: 7];
            wire [6:0]        m_atk = ext_attack_mod[vch*7 +: 7];
            wire [6:0]        m_rel = ext_release_mod[vch*7 +: 7];

            // ---- 按本泳道当前音色查参数表 ----
            wire [99:0] tp        = tp_of(pf_timbre[gi*3 +: 3]);
            wire [15:0] t_f_coeff = tp[99:84];
            wire [15:0] t_q_coeff = tp[83:68];
            wire [1:0]  t_ftype   = tp[67:66];
            wire [1:0]  t_acurve  = tp[65:64];
            wire [15:0] t_astep   = tp[63:48];
            wire [15:0] t_dstep   = tp[47:32];
            wire [15:0] t_slevel  = tp[31:16];
            wire [15:0] t_rstep   = tp[15:0];

            //  ⚠⚠ 2026-10-19：**三个调制的方向原来是反的**，已改成减号。
            //     MIDI 规范：
            //       CC71 Resonance      值越大谐振越强 → q_coeff 必须**减小**
            //                           （SVF 里 q 是阻尼项：high = in − low − q·band）
            //       CC73 Attack  Time   值越大起音越慢 → attack_step 必须**减小**
            //       CC72 Release Time   值越大释放越慢 → release_step 必须**减小**
            //       CC74 Frequency Cutoff 值越大越亮 → f_coeff 增大（**这个方向本来就对**）
            //     之前一直没发现：上板声音是"炸"的，根本听不出滤波器松紧。
            //     安全性：m_res=127 → q_coeff = 16384−16128 = 256（>0，不会自激）；
            //             m_atk=127 → a_step = 5−31 → 被钳到 1（最长起音）。
            wire signed [17:0] cut_s = $signed({2'b0, t_f_coeff}) +
                                       (($signed({11'd0, m_cut}) - 18'sd64) <<< 8);
            wire signed [17:0] res_s = $signed({2'b0, t_q_coeff}) -
                                       (($signed({11'd0, m_res}) - 18'sd64) <<< 8);
            wire signed [17:0] atk_s = $signed({2'b0, t_astep}) -
                                       (($signed({11'd0, m_atk}) - 18'sd64) >>> 1);
            wire signed [17:0] rel_s = $signed({2'b0, t_rstep}) -
                                       (($signed({11'd0, m_rel}) - 18'sd64) >>> 1);

            wire [15:0] f_coeff_g = (cut_s > 18'sd32767) ? 16'h7FFF : ((cut_s < 18'sd0) ? 16'd0     : cut_s[15:0]);
            wire [15:0] q_coeff_g = (res_s > 18'sd32767) ? 16'h7FFF : ((res_s < 18'sd0) ? 16'd0     : res_s[15:0]);
            wire [15:0] a_step_g  = (atk_s > 18'sd32767) ? 16'h7FFF : ((atk_s < 18'sd1) ? 16'd1     : atk_s[15:0]);
            wire [15:0] r_step_g  = (rel_s > 18'sd32767) ? 16'h7FFF : ((rel_s < 18'sd1) ? 16'd1     : rel_s[15:0]);

            //  ⚠ 2026-10-18：**必须插一级寄存器**。
            //     上面这条链是"16 通道 × 7 位向量 → 变量位选择(16选1 mux) → 加减偏移 → 钳位"，
            //     如果直接喂给 voice_mono 的 f_coeff/q_coeff，就会串在 SVF 乘法器前面 ——
            //     实测 P&R 后最差 slack 从 −0.613 ns 恶化到 **−10.955 ns**，
            //     违例从 210 涨到 **1804**（超标 3 倍，位流不可用）。
            //     打一拍后这条链在寄存器处断开，SVF 前面的关键路径恢复原状。
            //     代价：参数晚 1 个采样（62.5 µs），听感无影响。
            reg [15:0] f_coeff_r, q_coeff_r, a_step_r, r_step_r;
            always @(posedge clk_sys or negedge rst_n_sync) begin
                if (!rst_n_sync) begin
                    f_coeff_r <= def_f_coeff;
                    q_coeff_r <= def_q_coeff;
                    a_step_r  <= def_astep;
                    r_step_r  <= def_rstep;
                end else begin
                    f_coeff_r <= f_coeff_g;
                    q_coeff_r <= q_coeff_g;
                    a_step_r  <= a_step_g;
                    r_step_r  <= r_step_g;
                end
            end
            voice_mono u_voice (
                .clk          (clk_sys),
                .rst_async_n  (rst_n_sync),      // 本层只有同步复位，直接当异步输入用（模块内自己同步释放）
                .sample_en    (slot_vld),        // 时隙节拍
                .slot         (slot),            // 2026-10-21：4 份状态（每声部每帧推进一次）

                // ---- DDS ----
                .phase_inc    (pf_phase_inc[gi*32 +: 32]),
                .wave_sel     (def_wsel),
                .timbre_slot  (pf_timbre[gi*3 +: 3]),

                // ---- SVF ----
                .f_coeff      (f_coeff_r),
                .q_coeff      (q_coeff_r),
                .filter_type  (t_ftype),

                // ---- ADSR / VCA ----
                .gate         (pf_gate[gi]),
                .sustain_pedal(pf_sust_pedal[gi]),
                .adsr_curve   (t_acurve),
                .attack_step  (a_step_r),
                .decay_step   (t_dstep),
                .sustain_level(t_slevel),
                .release_step (r_step_r),
                .velocity_gain(pf_vel_gain[gi*16 +: 16]),
                .vca_gain     (pf_vca_gain[gi*16 +: 16]),

                // ---- 共享波表取数 ----
                .tab_n        ($signed(tab_n [gi*16 +: 16])),
                .tab_n1       ($signed(tab_n1[gi*16 +: 16])),
                .samples_rdy  (rom_rdy),
                .rom_addr_n   (rom_addr_n [gi*14 +: 14]),
                .rom_addr_n1  (rom_addr_n1[gi*14 +: 14]),

                // ---- 输出 ----
                .voice_out    (voice_aud[gi*24 +: 24]),
                .dbg_wave     (voice_dbg_wave[gi*24 +: 24]),   // 仅调试探针用
                .data_vld     (voice_data_vld[gi]),
                .ch_in        (pf_ch[gi*4 +: 4]),
                .data_gate    (voice_data_gate[gi]),
                .data_ch      (voice_data_ch[gi*4 +: 4]),

                // ---- 状态写回（→ 调度层）----
                .phase_acc    (rs_phase_acc[gi*32 +: 32]),
                .env_value    (rs_env_value[gi*16 +: 16]),
                .env_state    (rs_env_state[gi*3 +: 3]),
                .filter_ic1   (rs_filter_ic1[gi*32 +: 32]),
                .filter_ic2   (rs_filter_ic2[gi*32 +: 32])
            );
        end
    endgenerate

    //  ⚠ 路由信号：按 §8.5.3「`ch_in` 与 `vld` 由声部取数器**直接旁路**给通道层」
    //     —— 即**不经** `voice_mono`，这里从调度层预取寄存器直接接到 full_top。
    assign voice_ch  = pf_ch;
    assign voice_vld = pf_gate;

    //  8 条泳道共用同一条波表流水（wave_fetch 的 rdy 是全局的），
    //  所以它们的 data_vld 完全相同，取或即可。
    assign voice_data_vld_any = |voice_data_vld;

    // ========================================================================
    // 调试 LED（2026-10-12 加，用于上板排查音色映射与测延迟）
    //
    //  dbg_led[2:0] ← 泳道 0 的 timbre_slot（即 pf_timbre[2:0]）
    //      发 `pc 0` ~ `pc 7`，这 3 个灯应出现 8 种不同组合。
    //      · 灯变、声音不变 → 映射正常，问题在波表/音频链
    //      · 灯完全不变     → 综合把它优化掉了，或映射没走到
    //
    //  dbg_led[3] ← 声部激活（pf_gate 任一为 1）的上升沿，展宽 40 ms
    //      接示波器可测"Note On → 音频输出"的延迟（基础 ≤10ms / 拓展 ≤5ms 那个指标）。
    //
    //  ⚠ 这三个音色位会随演奏闪烁，属正常现象；正式演示时可在 .cst 里注释掉。
    //
    //  ⚠ 极性：**板上 LED 低电平点亮**（依据 board/i2s_test/i2s_test.v 的注释与
    //     其它测试工程里 `assign led = ~cnt[...]` 的写法）。所以下面的输出都取反了。
    //     若将来换板子，先确认极性再改这里。
    // ========================================================================
    //  ⚠ 板上 LED 是**低电平点亮**（见 board/i2s_test/i2s_test.v 的注释），故取反。
    assign dbg_led[2:0] = ~pf_timbre[2:0];         // 泳道 0 的音色槽（低电平点亮 → 取反）

    reg  [21:0] dbg_evt_cnt;
    reg         dbg_gate_d;
    wire        dbg_gate_any = |pf_gate;
    wire        dbg_rise     = dbg_gate_any & ~dbg_gate_d;

    always @(posedge clk_sys or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            dbg_gate_d  <= 1'b0;
            dbg_evt_cnt <= 22'd0;
        end else begin
            dbg_gate_d <= dbg_gate_any;
            // 49.152 MHz × 40 ms ≈ 1.97e6，取 2e6（约 40.7 ms）
            if (dbg_rise)                  dbg_evt_cnt <= 22'd2_000_000;
            else if (dbg_evt_cnt != 22'd0) dbg_evt_cnt <= dbg_evt_cnt - 22'd1;
        end
    end

    assign dbg_led[3] = ~(dbg_evt_cnt != 22'd0);      // 同上，低电平点亮

    //  ========================================================================
    //  2026-10-25 加：延迟测量探针（只读，不影响音频通路）
    //    判据：当前有音符门控（|voice_data_gate）且 |mon_l_w| 超阈值 -> 拉高
    //    用途：示波器 CH1 接 MIDI 输入、CH2 接 B21，量『MIDI 字节 -> 出声』延迟
    //  ========================================================================
    wire signed [15:0] mon_abs = (mon_l_w[15]) ? -$signed(mon_l_w) : $signed(mon_l_w);
    reg                dbg_audio_on_r;
    reg  [15:0]        lat_frames;

    always @(posedge clk_sys or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            dbg_audio_on_r <= 1'b0;
            lat_frames     <= 16'd0;
        end else if (sample_stb) begin
            dbg_audio_on_r <= (|voice_data_gate) && (mon_abs >= 16'sd128);
            if (!(|voice_data_gate))
                lat_frames <= 16'd0;
            else if (lat_frames != 16'hFFFF)
                lat_frames <= lat_frames + 16'd1;
        end
    end
    assign dbg_audio_on = dbg_audio_on_r;

endmodule
`default_nettype wire
