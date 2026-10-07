//============================================================================
//  chan_param_shadow —— 通道参数影子寄存器（调度层 → full_top 的 ext_* 接口）
//
//  背景：sakiko 的 full_top 在 EXT_TABLE=1 时要求外部**一次性**给出全部 16 个
//        通道的扁平向量（ext_volume[NCH*7] …），而 chan_table 的读口是
//        「给一个通道号、取回该通道全部字段」。两者形态不同，需要这一层转换。
//
//  依据：scratch/交流用/集成接口说明_给poki.md §3.2/§3.3
//        · 红线①：通道表参数**只在 frame_stb 帧边界改**
//          —— 本模块的 ext_* 全部是寄存器，只在 frame_stb 那一刻从扫描缓冲
//             整体复制一次，帧内恒定，天然满足这条红线
//
//  工作方式：
//    · 扫描相位：rd_ch 自由运行（0→15 循环，每拍 +1），从 chan_table 的单读口
//                把 8 个字段 + sustain_pedal 存进扫描缓冲。读口是组合的，
//                所以 rd_ch 与 rd_volume… 同拍对应。
//    · 提交相位：frame_stb 那一拍，把扫描缓冲整体复制到 ext_* 输出寄存器。
//                扫描一轮只要 16 拍，所以 ext_* 最多滞后 16 拍（≈0.33 µs）。
//
//  附带产物 ch_sust_pedal[NCH]：voice_mono 需要按声部的通道号取 sustain_pedal，
//  这里已经在扫全部通道了，顺手引出来给 voice_fetch 预取用，避免再开一个读口。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module chan_param_shadow #(
    parameter NCH = 16
)(
    input  wire        clk,
    input  wire        rst_n_sync,
    input  wire        frame_stb,          // 帧边界 = 唯一提交时刻

    // ——— 接 chan_table 的单读口 ———
    output reg  [3:0]  rd_ch,
    input  wire [6:0]  rd_volume,
    input  wire [6:0]  rd_expression,
    input  wire [15:0] rd_pan_gL,
    input  wire [15:0] rd_pan_gR,
    input  wire [6:0]  rd_send_reverb,
    input  wire [6:0]  rd_send_chorus,
    input  wire [6:0]  rd_send_delay,
    input  wire        rd_sustain_pedal,

    // ——— 给 full_top 的 ext_*（帧内恒定）———
    output reg [NCH*7-1:0]  ext_volume,
    output reg [NCH*7-1:0]  ext_expression,
    output reg [NCH*16-1:0] ext_pan_gL,
    output reg [NCH*16-1:0] ext_pan_gR,
    output reg [NCH*7-1:0]  ext_send_rev,
    output reg [NCH*7-1:0]  ext_send_cho,
    output reg [NCH*7-1:0]  ext_send_del,

    // ——— 给 voice_fetch 预取 sustain_pedal ———
    output reg [NCH-1:0]    ch_sust_pedal
);
    //--------------------------------------------------------------- 扫描缓冲
    reg [6:0]  vol_s  [0:NCH-1];
    reg [6:0]  exp_s  [0:NCH-1];
    reg [15:0] panl_s [0:NCH-1];
    reg [15:0] panr_s [0:NCH-1];
    reg [6:0]  sre_s  [0:NCH-1];
    reg [6:0]  sch_s  [0:NCH-1];
    reg [6:0]  sde_s  [0:NCH-1];
    reg        sus_s  [0:NCH-1];

    reg [3:0]  scan_i;

    integer k;
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            scan_i <= 4'd0;
            rd_ch  <= 4'd0;
            for (k = 0; k < NCH; k = k + 1) begin
                vol_s [k] <= 7'd0;
                exp_s [k] <= 7'd0;
                panl_s[k] <= 16'd0;
                panr_s[k] <= 16'd0;
                sre_s [k] <= 7'd0;
                sch_s [k] <= 7'd0;
                sde_s [k] <= 7'd0;
                sus_s [k] <= 1'b0;
            end
        end else begin
            // 扫描指针自由运行（0→15 循环）
            scan_i <= scan_i + 4'd1;
            rd_ch  <= scan_i;

            // ⚠ 写缓冲要用**当前的 rd_ch**（它是上一拍设的），这样才和本拍组合读出的
            //   rd_volume… 对应同一个通道；用 scan_i 会错开一个通道。
            vol_s [rd_ch] <= rd_volume;
            exp_s [rd_ch] <= rd_expression;
            panl_s[rd_ch] <= rd_pan_gL;
            panr_s[rd_ch] <= rd_pan_gR;
            sre_s [rd_ch] <= rd_send_reverb;
            sch_s [rd_ch] <= rd_send_chorus;
            sde_s [rd_ch] <= rd_send_delay;
            sus_s [rd_ch] <= rd_sustain_pedal;
        end
    end

    //--------------------------------------------------------------- 帧边界提交
    // 用 generate 展开每个通道的独立位段寄存器（多个 always 驱动同一 reg 的
    // 不重叠位段，iverilog/Gowin 都接受；voice_fetch 的 pf_* 就是这么写的）。
    genvar gi;
    generate
        for (gi = 0; gi < NCH; gi = gi + 1) begin : g_sub
            always @(posedge clk or negedge rst_n_sync) begin
                if (!rst_n_sync) begin
                    ext_volume    [gi*7  +: 7 ] <= 7'd0;
                    ext_expression[gi*7  +: 7 ] <= 7'd0;
                    ext_send_rev  [gi*7  +: 7 ] <= 7'd0;
                    ext_send_cho  [gi*7  +: 7 ] <= 7'd0;
                    ext_send_del  [gi*7  +: 7 ] <= 7'd0;
                    ext_pan_gL    [gi*16 +: 16] <= 16'd0;
                    ext_pan_gR    [gi*16 +: 16] <= 16'd0;
                    ch_sust_pedal [gi]          <= 1'b0;
                end else if (frame_stb) begin
                    ext_volume    [gi*7  +: 7 ] <= vol_s [gi];
                    ext_expression[gi*7  +: 7 ] <= exp_s [gi];
                    ext_send_rev  [gi*7  +: 7 ] <= sre_s [gi];
                    ext_send_cho  [gi*7  +: 7 ] <= sch_s [gi];
                    ext_send_del  [gi*7  +: 7 ] <= sde_s [gi];
                    ext_pan_gL    [gi*16 +: 16] <= panl_s[gi];
                    ext_pan_gR    [gi*16 +: 16] <= panr_s[gi];
                    ch_sust_pedal [gi]          <= sus_s [gi];
                end
            end
        end
    endgenerate

endmodule
`default_nettype wire
