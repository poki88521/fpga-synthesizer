//============================================================================
//  ch_lfo —— 每通道颤音 LFO（三角波）
//
//  设计要点（2026-10-17）：
//    · 16 通道各一个 32 位相位累加器，在 frame_stb（= 48 kHz 采样节拍）推进
//    · **三角波**而非正弦：省掉波形表与 BRAM，颤音听感几乎无差别
//      （很多经典模拟合成器的 vibrato 就是三角波）
//    · 输出 ch_vib_ratio 与 ch_bend_ratio 同形态（Q2.14，16384 = 不颤），
//      由 voice_fetch 预取时与弯音**先合成总倍率再乘表值**
//    · 深度映射：mod_wheel(0..127) × 4 → 0..508（Q2.14 下约 ±0.37 半音）
//      ⚠ mod_wheel 不走 chan_table（那个表已占满 182 位），
//        而是由 sched_subsystem 从事件流里截获 CC1 存进 16×7 寄存器组
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module ch_lfo #(
    parameter        NCH    = 16,
    parameter [31:0] PH_INC = 32'd492132        // 5.5 Hz @48 kHz：(5.5/48000)*2^32
)(
    input  wire                 clk,
    input  wire                 rst_n_sync,
    input  wire                 frame_stb,       // 48 kHz 采样节拍
    input  wire [NCH*7-1:0]     mod_wheel,       // 每通道调制轮 0..127
    output reg  [NCH*16-1:0]    ch_vib_ratio     // Q2.14，16384 = 不颤
);

    genvar gi;
    generate
        for (gi = 0; gi < NCH; gi = gi + 1) begin : g_lfo
            reg [31:0] phase;
            reg [15:0] depth;

            // 三角波：取相位高 8 位，折成 0..127..0，再居中到 ±64
            wire [7:0]        ph8   = phase[31:24];
            wire [7:0]        tri_u = ph8[7] ? (8'd255 - ph8) : ph8;
            wire signed [8:0] tri_c = $signed({1'b0, tri_u}) - 9'sd63;   // -63 .. +64

            //  ⚠ 2026-10-17 修：操作数也要显式扩宽，否则乘积在 16 位下求值
            //     （综合日志报 "Expression size 26 truncated to fit in target size 16"）。
            //     当前值域 ±64×508 = ±32512 恰好不溢出，但一旦调大深度就会出错。
            wire signed [16:0] tri17 = {{8{tri_c[8]}}, tri_c};      // 符号扩展到 17 位
            wire        [16:0] dep17 = {8'd0, depth[8:0]};          // depth ≤ 508
            wire signed [33:0] vib_p = tri17 * $signed(dep17);      // 34 位容器
            wire signed [15:0] vib_d = vib_p >>> 6;                 // ±depth

            always @(posedge clk or negedge rst_n_sync) begin
                if (!rst_n_sync) begin
                    phase                    <= 32'd0;
                    depth                    <= 16'd0;
                    ch_vib_ratio[gi*16 +: 16] <= 16'd16384;   // ⚠ 1.0，不能是 0（0 = 无声）
                end else begin
                    depth <= {7'd0, mod_wheel[gi*7 +: 7]} << 2;
                    if (frame_stb) begin
                        phase                     <= phase + PH_INC;
                        ch_vib_ratio[gi*16 +: 16] <= 16'd16384 + vib_d;
                    end
                end
            end
        end
    endgenerate

endmodule
`default_nettype wire