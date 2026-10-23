//============================================================================
//  dds_voice —— DDS 波表振荡器（单个泳道）
//
//  依据：documents/硬件实现.md §五.5.1（接口）、§五.4（波表并发读）
//        documents/技术文档.md  §五.1.3（DDS）、§五.1.4（频率换算）
//
//  口径（新文档为准，与旧稿 v2.2 的差异已对齐）：
//    · 音色槽数 8（timbre_slot 3 位），每槽 2048 点，波表总深度 16384
//    · 表内整数索引 = phase_acc[31:21]（11 位）
//    · 小数部分     = phase_acc[20:13]（8 位，代表 0~255/256）
//    · 波表地址     = {timbre_r[2:0], phase_acc[31:21]}（14 位）
//                     timbre_r = sample_en 沿锁存的 timbre_slot（见下方 2026-10-21 修）
//    · 插值相邻点在同一槽内 +1，**槽末回绕到本槽首点**（不是跳到下一槽）
//    · wave_out = (tab_n + (tab_n1 - tab_n) * frac / 256) 左移 8 位 → Q1.23
//
//  ⚠ 与旧稿的一处必要偏差（已在汇报中说明）：
//    波表按新文档是「全局仅 1 份 + 时隙内串行读」，ROM 不能放在 dds_voice 内部，
//    否则 P 条泳道会各带一份 ROM（正是 §五.4 否掉的方案）。
//    因此 dds_voice **不例化 ROM**，改为：
//      · 输出组合地址 rom_addr_n / rom_addr_n1 给共享取数器 wave_fetch；
//      · 从 wave_fetch 收回 tab_n / tab_n1，在 samples_rdy 那拍做插值。
//    其余接口与 §五.5.1 完全一致。
//
//  相位累加器**运行时不清零**（仅复位时归零），频率切换保持相位连续。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module dds_voice (
    input  wire        clk,
    input  wire        rst_n_sync,
    input  wire        sample_en,          // 时隙节拍（slot_vld），每帧 G 个脉冲
    input  wire [31:0] phase_inc,          // 频率控制字
    input  wire [1:0]  wave_sel,           // 波表索引预留，当前未用（见表内注释）
    input  wire [2:0]  timbre_slot,        // 音色槽 0~7
    input  wire signed [15:0] tab_n,       // 插值左点（来自 wave_fetch）
    input  wire signed [15:0] tab_n1,      // 插值右点（来自 wave_fetch）
    input  wire        samples_rdy,        // 两点都到齐，可以插值
    input  wire [1:0]  slot,               // 当前时隙号（4 份状态的选择子，2026-10-21）
    output wire [31:0] phase_acc,          // 写回声部状态表（= 本时隙声部的值）
    output reg  signed [23:0] wave_out,    // Q1.23，送往 SVF
    output wire [13:0] rom_addr_n,         // 给 wave_fetch
    output wire [13:0] rom_addr_n1
);

    // wave_sel 是冻结接口里的预留位。地址已由 timbre_slot 决定（8 槽口径），
    // 故此处不参与寻址；保留端口以便后续扩到「每槽多波形」。
    /* verilator lint_off UNUSED */
    wire [1:0] wave_sel_unused = wave_sel;
    /* verilator lint_on UNUSED */

    //---------------- 相位与地址 ----------------
    localparam [10:0] IDX_LAST = 11'h7FF;      // 每槽 2048 点，索引 0~2047

    //  4 份相位状态（2026-10-21，方案 A）：
    //    一条泳道要时分复用服务 4 个声部（vid = {slot, lane}），而本模块只有一套
    //    phase_acc → 4 个声部的相位会互相累积/覆盖。改成按 slot 索引的 4 份状态，
    //    每个声部每帧只在自己那个时隙被推进一次（= 48 kHz/声部）。
    //    资源：32 bit × 4 × 8 泳道 = 1024 个寄存器。
    reg [31:0] phase_r [0:3];
    integer i;
    assign phase_acc = phase_r[slot];

    wire [10:0] idx    = phase_acc[31:21];     // 表内整数索引（11 位）
    wire [10:0] idx_n1 = (idx == IDX_LAST) ? 11'd0 : (idx + 11'd1);  // 槽内回绕

    //  ⚠⚠ 2026-10-21 修：音色槽必须和相位/增量**属于同一个声部**。
    //
    //  原先地址直接拼端口 `timbre_slot`（= 调度层预取寄存器 pf_timbre 的**实时值**）。
    //  而 voice_fetch.v 的预取语义是「slot_vld 那一拍就把 pf_* 换成**下一时隙**的声部」：
    //      · phase_acc 在 slot_vld 沿用**沿前**的 pf_phase_inc 推进  → 属于声部 g
    //      · wave_fetch 在 start_d（沿后 1 拍）才锁存地址，读到的是**沿后**的 pf_timbre
    //                                                              → 属于声部 g+1
    //  结果：同一条 lane 内「相位/频率来自声部 g，波表槽来自声部 g+1」。
    //  症状：① 音色串到邻位声部（选了长笛却按邻位的槽发声）；
    //        ② 同一帧的 4 次 samples_rdy 拿到 4 个不同槽的数据，看起来像
    //           "前两次 dds_out 没稳定"（其实是 4 个声部的数据被 latching 到同一个
    //           wave_out 寄存器）。这就是交接文档里那个现象的真正来源。
    //
    //  修法：与 frac_r 同沿锁存 timbre_slot，地址用锁存值 → 二者都对应声部 g。
    //  注意：SVF/ADSR 的音色参数（f_coeff/q_coeff/attack_step…）目前在 full_system 的
    //  generate 里仍由**实时** pf_timbre 查表，属于同一类偏差、本次未改（改动点在
    //  full_system.v / voice_mono.v，需另行确认）。
    reg [2:0] timbre_r;

    // 组合地址：wave_fetch 在 sample_en 之后 2 拍才锁存，此时 timbre_r 与 phase_acc 均生效
    assign rom_addr_n  = {timbre_r, idx};
    assign rom_addr_n1 = {timbre_r, idx_n1};

    reg [7:0] frac_r;                          // 锁存的小数部分

    //---------------- 线性插值 ----------------
    // wave_out = ( tab_n + (tab_n1 - tab_n) * frac / 256 ) << 8
    wire signed [16:0] diff    = tab_n1 - tab_n;
    wire signed [24:0] prod    = diff * $signed({1'b0, frac_r});        // 17 x 8
    wire signed [16:0] interp  = tab_n + (prod >>> 8);                  // 17 位，仍在 16 位量程内
    wire signed [24:0] scaled  = interp * 25'sd256;                     // 左移 8 位 → Q1.23

    wire signed [23:0] wave_sat =
        (scaled >  25'sd8388607) ? 24'sh7FFFFF :
        (scaled < -25'sd8388608) ? 24'sh800000 :
        scaled[23:0];

    //---------------- 时序 ----------------
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            for (i = 0; i < 4; i = i + 1)
                phase_r[i] <= 32'd0;
            frac_r    <= 8'd0;
            timbre_r  <= 3'd0;             // 2026-10-21：复位默认槽 0
            wave_out  <= 24'sd0;
        end else begin
            if (sample_en) begin
                // 相位按自然回绕（2^32 模）累加，禁止饱和；只推进本时隙的那一份
                phase_r[slot] <= phase_r[slot] + phase_inc;
                frac_r    <= phase_acc[20:13];
                timbre_r  <= timbre_slot;      // 2026-10-21：与相位同沿锁存（见上）
            end
            if (samples_rdy)
                wave_out <= wave_sat;
        end
    end

endmodule

`default_nettype wire
