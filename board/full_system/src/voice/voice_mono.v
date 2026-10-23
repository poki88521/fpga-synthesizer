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
//        SVF  : rdy_d1（此时 wave_out 已有效，启动 4 级流水）
//        ADSR : rdy_d4（SVF 4 级流水走完，svf_out 此刻有效）
//        VCA  : rdy_d4（与 SVF 输出同拍）
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
    input  wire [1:0]  slot,               // 当前时隙号（2026-10-21：4 份状态的选择子）

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
    output wire signed [31:0] filter_ic2,

    //  ⚠ 2026-10-21 新增：DDS 波表输出引出（调试探针用，不参与功能）。
    //     用途：在示波器上直接看"波表 + 插值"的输出是否干净（1 周期、262 Hz），
    //     把"炸"定位到 SVF 之前还是之后。
    output wire signed [23:0] dbg_wave,

    //  ⚠ 2026-10-19 新增：本声部输出此刻有效（内部 vca_en）。
    //     上游 chan_buf 必须用这个脉冲采样，不能用 slot_vld —— 见 full_top 的注释。
    output wire               data_vld,

    //  ⚠⚠ 2026-10-19：音频必须"自带"它自己的门控与通道号。
    //     原因：voice_fetch 是**预取**结构 —— 在 slot_vld 那一拍把 pf_* 更新成
    //     **下一个时隙**的声部。而 voice_mono 在同一拍的上升沿采样 pf_*，
    //     拿到的是"更新前"的值（= 当前时隙的声部，音频正确）。
    //     于是 pf_gate / pf_ch 在时隙中段已经是**下一个**声部的了 ——
    //     下游 chan_buf 若直接用它们，门控/通道与音频就会差一个时隙，
    //     结果 vld=0 → 写入 0 → **整链静音**。
    //     解法：在 dds_en（与音频同拍）把 gate / ch_in 锁存下来一起送出去。
    input  wire [3:0]         ch_in,       // 本声部的 MIDI 通道号
    output wire               data_gate,   // 与 voice_out 同源同拍的门控
    output wire [3:0]         data_ch      // 与 voice_out 同源同拍的通道号
);

    //---------------- 复位同步 ----------------
    wire rst_n_sync;
    reset_sync u_rst (
        .clk         (clk),
        .rst_async_n (rst_async_n),
        .rst_n_sync  (rst_n_sync)
    );

    //---------------- 流水使能 ----------------
    reg rdy_d1, rdy_d2, rdy_d3, rdy_d4, rdy_d5;
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            rdy_d1 <= 1'b0;
            rdy_d2 <= 1'b0;
            rdy_d3 <= 1'b0;
            rdy_d4 <= 1'b0;
            rdy_d5 <= 1'b0;
        end else begin
            rdy_d1 <= samples_rdy;
            rdy_d2 <= rdy_d1;
            rdy_d3 <= rdy_d2;
            rdy_d4 <= rdy_d3;
            rdy_d5 <= rdy_d4;      // 2026-10-21：svf_out 实际在 rdy_d5 才稳定
        end
    end

    //  ⚠⚠ 2026-10-19：导出"数据有效"脉冲，供 chan_buf 在**音频真正就绪**的那一拍采样。
    //     原来的 chan_buf 用 slot_vld（时隙起点）采样，比音频就绪早了约 23 拍，
    //     存进去的是**上一个时隙**的音频 —— 声部与通道/门控全部错位。
    //
    //  ⚠⚠ 2026-10-21 再修（**这一版"没声音"的直接原因**）：
    //     `adsr_vca` 是在 `sample_en`（= vca_en）的**时钟沿**才把结果写进 `audio_out`，
    //     而 `data_vld` 原来与 `vca_en` 同拍 → `chan_buf` 在同一个沿采样，
    //     拿到的必然是**上一拍（= 上一个时隙）**的旧值。
    //     · 以前 4 个时隙共用一套状态时，旧值也是"这个音"的值，所以听不出来；
    //     · 现在每个时隙状态独立，旧值就是**别的声部的 0** → 整链静音
    //       （实测现象：正常模式全无声音、测试模式正常，因为测试模式不走声部层）。
    //     修法：把 `data_vld` 后移 1 拍，使它在 `audio_out` 更新**之后**才报有效。
    //     门控/通道号（`data_gate_r`/`data_ch_r`）在下一时隙的 dds_en 之前保持不变，
    //     所以晚 1 拍仍然与音频同属一个声部。
    reg data_vld_r;
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) data_vld_r <= 1'b0;
        else             data_vld_r <= vca_en;
    end
    assign data_vld = data_vld_r;

    //  与音频同拍锁存门控/通道号（见端口处注释）
    reg       data_gate_r;
    reg [3:0] data_ch_r;
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            data_gate_r <= 1'b0;
            data_ch_r   <= 4'd0;
        end else if (dds_en) begin
            data_gate_r <= gate;
            data_ch_r   <= ch_in;
        end
    end
    assign data_gate = data_gate_r;
    assign data_ch   = data_ch_r;

    wire dds_en = sample_en;      // DDS：时隙节拍，锁存地址 / 小数并推进相位
    wire svf_en = rdy_d1;         // SVF：wave_out 此刻有效
    //  ⚠⚠ 2026-10-21：VCA 必须用 rdy_d5，不是 rdy_d4。
    //    svf_voice 的 4 级流水在 rdy_d1 启动：phase0 锁存 → phase1 → phase2 → phase3 写回，
    //    它在 `rdy_d1 + 3` 的时钟沿才更新 `audio_out`，也就是**下一个时钟周期**才有效
    //    = rdy_d5。用 rdy_d4 会早一拍 → VCA 乘到的是**上一个时隙**的滤波输出。
    //    以前 4 个时隙共用一套状态时这点误差表现为"滞后一个样本"，听不出来；
    //    每时隙状态独立之后，它变成"乘到别的声部的 0" → 静音。
    wire vca_en = rdy_d5;

    //---------------- 时隙参数锁存（2026-10-21，S2 收尾） ----------------
    //  ⚠⚠ 为什么必须锁存：
    //    voice_fetch 的预取语义是「`slot_vld` 那一拍把 `pf_*` 换成**下一个时隙**的声部」。
    //    而本模块里 SVF 的使能是 `rdy_d1`、ADSR/VCA 的使能是 `rdy_d4`
    //    （波表扫描 17 拍 + 4 级流水，共十几拍之后）——若直接接端口，
    //    滤波器/包络参数与 `gate` 用的都是**下一个声部**的值：
    //        · 音色性格（f/q/filter_type/ADSR 步长）错位一个时隙
    //        · `gate` 错位一个时隙 → ADSR 可能在"别人"的时隙里被触发或松键
    //    `phase_inc` 由 dds_voice 在 `dds_en` 沿采样、`timbre_slot` 也在 `dds_en` 锁存，
    //    这里补齐其余字段，使 DDS / SVF / ADSR **基于同一份参数快照**（同一个声部）。
    //    代价：每个泳道 134 bit 寄存器（×8 = 1072 FF，资源充裕）。
    reg [15:0] l_f_coeff, l_q_coeff;
    reg [15:0] l_astep, l_dstep, l_slevel, l_rstep;
    reg [15:0] l_velgain, l_vcagain;
    reg [1:0]  l_ftype, l_acurve;
    reg        l_sust;

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            l_f_coeff <= 16'd0;
            l_q_coeff <= 16'd0;
            l_ftype   <= 2'd0;
            l_acurve  <= 2'd0;
            l_astep   <= 16'd1;
            l_dstep   <= 16'd1;
            l_slevel  <= 16'd0;
            l_rstep   <= 16'd1;
            l_velgain <= 16'd0;
            l_vcagain <= 16'd32768;     // 1.0
            l_sust    <= 1'b0;
        end else if (dds_en) begin
            l_f_coeff <= f_coeff;
            l_q_coeff <= q_coeff;
            l_ftype   <= filter_type;
            l_acurve  <= adsr_curve;
            l_astep   <= attack_step;
            l_dstep   <= decay_step;
            l_slevel  <= sustain_level;
            l_rstep   <= release_step;
            l_velgain <= velocity_gain;
            l_vcagain <= vca_gain;
            l_sust    <= sustain_pedal;
        end
    end

    //---------------- 三级链路 ----------------
    wire signed [23:0] dds_out, svf_out;

    assign dbg_wave = dds_out;      // 调试探针：DDS 输出（SVF 之前）

    dds_voice u_dds (
        .clk         (clk),
        .rst_n_sync  (rst_n_sync),
        .sample_en   (dds_en),
        .slot        (slot),              // 2026-10-21：4 份相位状态的选择子
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
        .slot        (slot),             // 2026-10-21：4 份滤波器状态的选择子
        .audio_in    (dds_out),
        .f_coeff     (l_f_coeff),        // 2026-10-21：改用 dds_en 锁存值
        .q_coeff     (l_q_coeff),
        .filter_type (l_ftype),
        .audio_out   (svf_out),
        .filter_ic1  (filter_ic1),
        .filter_ic2  (filter_ic2)
    );

    adsr_vca u_adsr_vca (
        .clk            (clk),
        .rst_n_sync     (rst_n_sync),
        .sample_en      (vca_en),
        .slot           (slot),          // 2026-10-21：4 份包络状态的选择子
        .audio_in       (svf_out),
        //  ⚠ 2026-10-21：门控必须用**本声部时隙沿**锁存的那一份。
        //     `data_gate_r` 已经是 dds_en 锁存的 pf_gate（与音频同拍），
        //     直接复用，不另开一份寄存器。
        .gate           (data_gate_r),
        .sustain_pedal  (l_sust),
        .adsr_curve     (l_acurve),
        .attack_step    (l_astep),
        .decay_step     (l_dstep),
        .sustain_level  (l_slevel),
        .release_step   (l_rstep),
        .velocity_gain  (l_velgain),
        .vca_gain       (l_vcagain),
        .audio_out      (voice_out),
        .env_value      (env_value),
        .env_state      (env_state)
    );

endmodule

`default_nettype wire
