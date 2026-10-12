//============================================================================
//  master_volume —— 主输出处理 第一步：主音量 + 静音
//
//  文档：模块三设计文档 4.主输出处理 第一步
//
//  定点：
//      音频 MainL/MainR : 24-bit Q1.23 有符号
//      主音量 vol       : 14-bit（0 ~ 16383，来自 SysEx）
//      G_master         : 16-bit Q1.15。因为 G = V/16383 ≈ V/16384，
//                         所以 G_Q15 = V << 1（误差 < 0.006%）
//
//  静音/音量切换走 ±RAMP_STEP 的一阶斜坡（默认约 10 ms），避免咔哒声。
//      RAMP_STEP = 64 时：32768/64 = 512 个采样 ≈ 10.7 ms @48 kHz
//============================================================================

`default_nettype none

module master_volume #(
    parameter integer RAMP_STEP = 64,       // 每采样增益变化量（Q1.15 LSB）
    parameter integer OUT_W     = 24
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    en,          // 采样节拍
    input  wire signed [OUT_W-1:0] l_in,
    input  wire signed [OUT_W-1:0] r_in,
    input  wire        [13:0]      vol,         // 0 ~ 16383
    input  wire                    mute,        // 1 = 静音
    output wire signed [OUT_W-1:0] l_out,
    output wire signed [OUT_W-1:0] r_out
);

    // G_Q15 = vol << 1，范围 0 ~ 32766（正的，所以有符号 16-bit 也能表示）
    wire [15:0] g_tgt = mute ? 16'd0 : {vol, 1'b0};

    reg  [15:0] g;                              // 当前增益，Q1.15

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g <= 16'd0;
        end else if (en) begin
            if (g < g_tgt) begin
                g <= ((g_tgt - g) > RAMP_STEP) ? (g + RAMP_STEP[15:0]) : g_tgt;
            end else if (g > g_tgt) begin
                g <= ((g - g_tgt) > RAMP_STEP) ? (g - RAMP_STEP[15:0]) : g_tgt;
            end
        end
    end

    wire signed [15:0] g_s = g[15:0];

    // 24 x 16 = 40-bit，符号扩展到 48 位后走通用归一化单元
    wire signed [39:0] pl = l_in * g_s;
    wire signed [39:0] pr = r_in * g_s;

    norm_sat #(.IN_W(48), .SHIFT(15), .OUT_W(OUT_W)) u_vol_l (
        .acc({{8{pl[39]}}, pl}), .y(l_out)
    );
    norm_sat #(.IN_W(48), .SHIFT(15), .OUT_W(OUT_W)) u_vol_r (
        .acc({{8{pr[39]}}, pr}), .y(r_out)
    );

endmodule

`default_nettype wire
