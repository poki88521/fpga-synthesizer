//============================================================================
//  voice_mono —— 单声部（单个泳道）：DDS → SVF → VCA
//
//  依据：documents/硬件实现.md §五.8「模块集成」、§五.5（各级接口）、§8.5.1（4）状态写回
//        documents/技术文档.md  §五.1.1「单声部链路」
//
//  数据流：波表 DDS 生成波形 → SVF 滤波塑形 → VCA 包络增益 → 通道混音总线
//
//  ⚠ 与 §五.8 顶层信号表的必要补充（已在汇报中说明）：
//    波表按 §五.4 是「全局仅 1 份 + 时隙内串行读」，样本不在本模块内部产生，
//    因此本模块多了与共享取数器 wave_fetch 的对接端口：
//      输入 samples_rdy / tab_n / tab_n1，输出 rom_addr_n / rom_addr_n1。
//
//  ⚠ 流水线与延迟对齐（对应测试清单 P7，文档列为待实测）：
//    DDS 的 wave_out 要等波表取数回来（samples_rdy）才有效，
//    因此 SVF / ADSR·VCA **不能与 DDS 共用同一拍使能**，否则会取到上一时隙的旧值。
//    本模块内部用 rdy 的两级延迟产生流水使能：
//        DDS  : sample_en（时隙节拍）
//        SVF  : rdy_d1（此时 wave_out 已有效）
//        ADSR : rdy_d2（此时 svf_out 已有效）
//        VCA  : rdy_d2（与 SVF 输出同拍）
//    由此带来一个**可量化的控制滞后**：VCA 乘法用的是"上一时隙"的 env_value。
//    对慢变包络（最短 10 ms）而言约 20.8 µs 的滞后可忽略；
//    若要求零滞后，需给 adsr_vca 增加一个独立的 VCA 使能端口（当前冻结接口只有
//    一个 sample_en，故未加）。
//
//  状态写回（§8.5.1（4））：phase_acc / env_value / env_state / filter_ic1 / filter_ic2
//  由本模块引出，交由取数器在采样边界统一写回声部状态表。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module voice_mono (
    input  wire        clk,
    input  wire        rst_async_n,        // 外部异步复位（内部自己同步释放）
    input  wire        sample_en,          // 时隙节拍（= slot_vld），每帧 G 个脉冲

    // ---- DDS ----
    input  wire [31:0] phase_inc,
    input  wire [1:0]  wave_sel,
    input  wire [2:0]  timbre_slot,

    // ---- SVF ----
    input  wire [15:0] f_coeff,
    input  wire [15:0] q_coeff,
    input  wire [1:0]  filter_type,

    // ---- ADSR / VCA ----
    input  wire        gate,
    input  wire        sustain_pedal,
    input  wire [1:0]  adsr_curve,
    input  wire [15:0] attack_step,
    input  wire [15:0] decay_step,
    input  wire [15:0] sustain_level,
    input  wire [15:0] release_step,
    input  wire [15:0] velocity_gain,
    input  wire [15:0] vca_gain,

    // ---- 与共享波表取数器 wave_fetch 的对接 ----
    input  wire signed [15:0] tab_n,       // 插值左点
    input  wire signed [15:0] tab_n1,      // 插值右点
    input  wire        samples_rdy,        // 两点到齐（单拍脉冲）
    output wire [13:0] rom_addr_n,         // 本泳道请求的两个地址
    output wire [13:0] rom_addr_n1,

    // ---- 输出 ----
    output wire signed [23:0] voice_out,   // 即通道层的 aud_in（Q1.23 单声道）
    output wire [31:0]        phase_acc,   // 以下 5 项为状态写回
    output wire [15:0]        env_value,
    output wire [2:0]         env_state,
    output wire signed [31:0] filter_ic1,
    output wire signed [31:0] filter_ic2
);

    //---------------- 复位同步 ----------------
    wire rst_n_sync;
    reset_sync u_rst (
        .clk         (clk),
        .rst_async_n (rst_async_n),
        .rst_n_sync  (rst_n_sync)
    );

    //---------------- 流水使能 ----------------
    reg rdy_d1, rdy_d2;
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            rdy_d1 <= 1'b0;
            rdy_d2 <= 1'b0;
        end else begin
            rdy_d1 <= samples_rdy;
            rdy_d2 <= rdy_d1;
        end
    end

    wire dds_en = sample_en;      // DDS：时隙节拍，锁存地址 / 小数并推进相位
    wire svf_en = rdy_d1;         // SVF：wave_out 此刻有效
    wire vca_en = rdy_d2;         // VCA：svf_out 此刻有效

    //---------------- 三级链路 ----------------
    wire signed [23:0] dds_out, svf_out;

    dds_voice u_dds (
        .clk         (clk),
        .rst_n_sync  (rst_n_sync),
        .sample_en   (dds_en),
        .phase_inc   (phase_inc),
        .wave_sel    (wave_sel),
        .timbre_slot (timbre_slot),
        .tab_n       (tab_n),
        .tab_n1      (tab_n1),
        .samples_rdy (samples_rdy),
        .phase_acc   (phase_acc),
        .wave_out    (dds_out),
        .rom_addr_n  (rom_addr_n),
        .rom_addr_n1 (rom_addr_n1)
    );

    svf_voice u_svf (
        .clk         (clk),
        .rst_n_sync  (rst_n_sync),
        .sample_en   (svf_en),
        .audio_in    (dds_out),
        .f_coeff     (f_coeff),
        .q_coeff     (q_coeff),
        .filter_type (filter_type),
        .audio_out   (svf_out),
        .filter_ic1  (filter_ic1),
        .filter_ic2  (filter_ic2)
    );

    adsr_vca u_adsr_vca (
        .clk            (clk),
        .rst_n_sync     (rst_n_sync),
        .sample_en      (vca_en),
        .audio_in       (svf_out),
        .gate           (gate),
        .sustain_pedal  (sustain_pedal),
        .adsr_curve     (adsr_curve),
        .attack_step    (attack_step),
        .decay_step     (decay_step),
        .sustain_level  (sustain_level),
        .release_step   (release_step),
        .velocity_gain  (velocity_gain),
        .vca_gain       (vca_gain),
        .audio_out      (voice_out),
        .env_value      (env_value),
        .env_state      (env_state)
    );

endmodule

`default_nettype wire
