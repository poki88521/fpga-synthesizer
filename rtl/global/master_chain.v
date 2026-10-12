//============================================================================
//  master_chain —— 主输出处理（除 PT8211 串行化之外的整条链）
//
//  文档：模块三设计文档 4.主输出处理
//
//      第一步 主音量 + 静音        master_volume
//      第二步 软限幅               soft_limiter（2026-10-06 补上，THRESH=-2.5dBFS）
//      第三步 直流去除（可选）      dc_block
//      第四步 抖动 + 24→16-bit     dither16
//
//  输出 sample_l / sample_r 交给 pt8211_tx。
//  本模块对干路只增加 1 个采样的固定延迟。
//============================================================================

`default_nettype none

module master_chain #(
    parameter integer DC_ENABLE  = 1,
    parameter integer LIM_ENABLE = 1
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire                en,              // 采样节拍（来自 pt8211_tx）
    input  wire signed [23:0]  l_in,
    input  wire signed [23:0]  r_in,
    input  wire        [13:0]  vol,             // SysEx 主音量 0 ~ 16383
    input  wire                mute,
    input  wire                test_mode,       // 1 = 测试模式：限幅固定增益（不做动态压缩）
    output reg         [15:0]  sample_l,
    output reg         [15:0]  sample_r
);

    // ---- 第一步：主音量 + 静音 ----
    wire signed [23:0] l_vol, r_vol;
    master_volume u_vol (
        .clk(clk), .rst_n(rst_n), .en(en),
        .l_in(l_in), .r_in(r_in),
        .vol(vol), .mute(mute),
        .l_out(l_vol), .r_out(r_vol)
    );

    // ---- 第二步：软限幅（文档 4.第二步；防硬截断爆音） ----
    //   Env = max(|L|,|R|)；Env ≤ THRESH 时增益 1.0，否则 THRESH/Env；
    //   Attack 立即、Release 一阶；g 复位初值 1.0。
    wire signed [23:0] l_lim, r_lim;
    generate
        if (LIM_ENABLE != 0) begin : g_lim
            // 测试模式：THRESH 拉到满量程（env 永不超阈值）→ 增益恒为 1.0，
            // 符合附三"关闭软限幅的动态增益（Threshold 设为 1.0，即固定增益）"。
            soft_limiter u_lim (
                .clk(clk), .rst_n(rst_n), .en(en),
                .test_mode(test_mode),
                .l_in(l_vol), .r_in(r_vol),
                .l_out(l_lim), .r_out(r_lim),
                .g_out()                       // 增益仅供观测，这里不引出
            );
        end else begin : g_nolim
            assign l_lim = l_vol;
            assign r_lim = r_vol;
        end
    endgenerate

    // ---- 第三步：直流去除（可选） ----
    wire signed [23:0] l_dc, r_dc;
    generate
        if (DC_ENABLE != 0) begin : g_dc
            dc_block u_dc_l (.clk(clk), .rst_n(rst_n), .en(en), .x(l_lim), .y(l_dc));
            dc_block u_dc_r (.clk(clk), .rst_n(rst_n), .en(en), .x(r_lim), .y(r_dc));
        end else begin : g_nodc
            assign l_dc = l_lim;
            assign r_dc = r_lim;
        end
    endgenerate

    // ---- 第四步：抖动 + 24→16 ----
    wire signed [15:0] l16, r16;
    dither16 u_dith (
        .clk(clk), .rst_n(rst_n), .en(en),
        .l_in(l_dc), .r_in(r_dc),
        .l_out(l16), .r_out(r16)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_l <= 16'd0;
            sample_r <= 16'd0;
        end else if (en) begin
            sample_l <= l16;
            sample_r <= r16;
        end
    end

endmodule

`default_nettype wire
