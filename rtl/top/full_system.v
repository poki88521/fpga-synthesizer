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
    parameter integer STRIDE             = 8,      // ⚠ 必须与调度层一致
    parameter integer N                  = P*G,    // 声部数 = 32
    parameter integer PA_DELAY           = 22,
    parameter integer POR_BITS           = 22,
    parameter integer TEST_MODE_DEFAULT  = 0,      // 正式跑 0；上板自检可设 1（32 谱线）

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
    output wire         PA_EN
);

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
    wire         clk_sys;          // full_top 的系统时钟（USE_PLL=1 时 = PLL 的 49.152 MHz）
    wire [P*24-1:0] voice_aud;     // 单声部层 → 通道层
    wire [P*4-1:0]  voice_ch;
    wire [P-1:0]    voice_vld;

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
        .INTEG_CLAMP      (1)       // 结构保证：复位期间钳住 ext_*
    ) u_full_top (
        .clk50(clk50), .clk12288(clk12288),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),

        .ext_aud_in(voice_aud), .ext_ch_in(voice_ch), .ext_vld(voice_vld),
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
        .ext_master_vol(14'd16383), .ext_mute(1'b0), .ext_test_mode(1'b0),

        .midi_rx    (midi_rx),
        .pll_hold   (~ms_ok),          // MS5351 配好前把 PLL 按住（详见 full_top.v 端口注释）
        .sample_stb_o(sample_stb),
        .rst_n_sync_o(rst_n_sync),
        .clk_sys_o  (clk_sys)          // ⚠ 外部三层统一用这根，不要用 clk50
    );

    // ========================================================================
    // 2. 调度层：sched_subsystem（黑盒）
    // ========================================================================
    wire [1:0]      slot;
    wire            slot_vld;
    wire            pf_vld;
    wire [P*32-1:0] pf_phase_inc;
    wire [P*3-1:0]  pf_timbre;
    wire [P*7-1:0]  pf_note;
    wire [P*16-1:0] pf_vel_gain, pf_vca_gain;
    wire [P*4-1:0]  pf_ch;
    wire [P-1:0]    pf_gate, pf_fast_rel, pf_sust_pedal;

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

        .pf_vld(pf_vld), .pf_phase_inc(pf_phase_inc), .pf_timbre(pf_timbre),
        .pf_note(pf_note), .pf_vel_gain(pf_vel_gain), .pf_vca_gain(pf_vca_gain),
        .pf_ch(pf_ch), .pf_gate(pf_gate), .pf_fast_rel(pf_fast_rel),
        .pf_sust_pedal(pf_sust_pedal),

        .rs_phase_acc(rs_phase_acc), .rs_env_value(rs_env_value),
        .rs_env_state(rs_env_state), .rs_filter_ic1(rs_filter_ic1),
        .rs_filter_ic2(rs_filter_ic2)
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

    genvar gi;
    generate
        for (gi = 0; gi < P; gi = gi + 1) begin : g_voice
            voice_mono u_voice (
                .clk          (clk_sys),
                .rst_async_n  (rst_n_sync),      // 本层只有同步复位，直接当异步输入用（模块内自己同步释放）
                .sample_en    (slot_vld),        // 时隙节拍

                // ---- DDS ----
                .phase_inc    (pf_phase_inc[gi*32 +: 32]),
                .wave_sel     (def_wsel),
                .timbre_slot  (pf_timbre[gi*3 +: 3]),

                // ---- SVF ----
                .f_coeff      (def_f_coeff),
                .q_coeff      (def_q_coeff),
                .filter_type  (def_ftype),

                // ---- ADSR / VCA ----
                .gate         (pf_gate[gi]),
                .sustain_pedal(pf_sust_pedal[gi]),
                .adsr_curve   (def_acurve),
                .attack_step  (def_astep),
                .decay_step   (def_dstep),
                .sustain_level(def_slevel),
                .release_step (def_rstep),
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

endmodule
`default_nettype wire
