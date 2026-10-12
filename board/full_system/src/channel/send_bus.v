//============================================================================
//  send_bus —— 效果发送总线（设计文档 §1）
//
//  从通道处理层输出的 16 条通道立体声里，按各通道的发送量抽出湿信号，
//  分别汇成混响 / 合唱 / 延迟 3 条立体声总线，送给效果器运算。
//
//  数据流：
//      chan_layer 的串行通道流（16 拍，每拍一条通道的 L/R）
//          |  捕获进寄存器堆（16 x 48 bit）
//          v
//      TDM 乘法累加：48 拍（左右各一个乘法器）
//          |  每拍处理一个 (通道, 总线) 组合
//          v
//      3 条立体声总线（归一化 + 饱和到 24-bit）
//
//  周期预算（1024 拍/采样）：
//      捕获 16 拍 + 计算 48 拍 + 输出 1 拍 = 65 拍 = 6.3%
//
//  为什么用 2 个乘法器而不是 6 个：
//      3 条总线 x 左右两路 = 6 个累加器，需要 3 x 16 x 2 = 96 次乘法/采样。
//      用 2 个乘法器（左右各一）做 TDM，每个做 3 x 16 = 48 次。
//      效果器（混响/合唱/延迟）本身要吃掉大量 DSP，这里省一点是一点。
//      注意：**不是** 6 x 16 = 96 拍/声道 —— 左右两路已经分给两个乘法器了。
//
//  定点：
//      发送量 7-bit -> Q1.15：send_q = send << 8，范围 0 ~ 0x7F00（0.0 ~ 0.9922）
//      乘积：24 x 16 = 40-bit，符号扩展到 48-bit 累加
//      |Σ| <= 16 x 2^38 = 2^42，48-bit 装得下
//      输出：sat24( (acc + 2^14) >>> 15 )
//============================================================================

`default_nettype none

module send_bus #(
    parameter integer NCH = 16,
    parameter integer AW  = 24
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    frame_stb,

    // ---- 来自通道处理层的串行通道流 ----
    input  wire                    ch_vld,
    input  wire [3:0]              ch_addr,
    input  wire signed [AW-1:0]    ch_l,
    input  wire signed [AW-1:0]    ch_r,

    // ---- 来自通道状态表：每通道 7-bit 发送量 ----
    input  wire [NCH*7-1:0]        send_rev,
    input  wire [NCH*7-1:0]        send_cho,
    input  wire [NCH*7-1:0]        send_del,

    // ---- 3 条立体声总线 ----
    output reg                     bus_vld,
    output reg signed [AW-1:0]     bus_rev_l, bus_rev_r,
    output reg signed [AW-1:0]     bus_cho_l, bus_cho_r,
    output reg signed [AW-1:0]     bus_del_l, bus_del_r
);

    localparam integer AWX = 48;

    function automatic signed [AW-1:0] sat24;
        input signed [AWX-1:0] v;
        begin
            if      (v >  48'sd8388607) sat24 = 24'sh7FFFFF;
            else if (v < -48'sd8388608) sat24 = 24'sh800000;
            else                        sat24 = v[AW-1:0];
        end
    endfunction

    // ---------------- 捕获 ----------------
    reg signed [AW-1:0] cap_l [0:NCH-1];
    reg signed [AW-1:0] cap_r [0:NCH-1];

    // ---------------- TDM 扫描 ----------------
    reg [3:0]  cc;          // 通道 0 ~ 15
    reg [1:0]  cb;          // 总线 0 ~ 2
    reg [1:0]  st;

    localparam [1:0] ST_CAP = 2'd0, ST_CALC = 2'd1, ST_OUT = 2'd2;

    // 当前 (通道, 总线) 的发送系数
    wire [6:0] s7 = (cb == 2'd0) ? send_rev[cc*7 +: 7] :
                    (cb == 2'd1) ? send_cho[cc*7 +: 7] :
                                   send_del[cc*7 +: 7];
    wire signed [15:0] s_q = $signed({1'b0, s7}) <<< 8;

    wire signed [AW-1:0] cl = cap_l[cc];
    wire signed [AW-1:0] cr = cap_r[cc];

    wire signed [AW+15:0] pl = cl * s_q;      // 24 x 16 = 40
    wire signed [AW+15:0] pr = cr * s_q;

    reg signed [AWX-1:0] acc_l [0:2];
    reg signed [AWX-1:0] acc_r [0:2];

    wire signed [AWX-1:0] plx = {{(AWX-(AW+16)){pl[AW+15]}}, pl};
    wire signed [AWX-1:0] prx = {{(AWX-(AW+16)){pr[AW+15]}}, pr};

    wire signed [AWX-1:0] acc_l_n = acc_l[cb] + plx;
    wire signed [AWX-1:0] acc_r_n = acc_r[cb] + prx;

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st     <= ST_CAP;
            cc     <= 4'd0;
            cb     <= 2'd0;
            bus_vld<= 1'b0;
            bus_rev_l <= 24'sd0; bus_rev_r <= 24'sd0;
            bus_cho_l <= 24'sd0; bus_cho_r <= 24'sd0;
            bus_del_l <= 24'sd0; bus_del_r <= 24'sd0;
            for (i = 0; i < NCH; i = i + 1) begin
                cap_l[i] <= 24'sd0;
                cap_r[i] <= 24'sd0;
            end
            for (i = 0; i < 3; i = i + 1) begin
                acc_l[i] <= 48'sd0;
                acc_r[i] <= 48'sd0;
            end
        end else begin
            bus_vld <= 1'b0;

            case (st)
                // ---- 边收边存（16 拍） ----
                ST_CAP: begin
                    if (ch_vld) begin
                        cap_l[ch_addr] <= ch_l;
                        cap_r[ch_addr] <= ch_r;
                        if (ch_addr == NCH-1) begin
                            st <= ST_CALC;
                            cc <= 4'd0;
                            cb <= 2'd0;
                            for (i = 0; i < 3; i = i + 1) begin
                                acc_l[i] <= 48'sd0;
                                acc_r[i] <= 48'sd0;
                            end
                        end
                    end
                end

                // ---- TDM 乘加（3 总线 x 16 通道 = 48 拍） ----
                ST_CALC: begin
                    acc_l[cb] <= acc_l_n;
                    acc_r[cb] <= acc_r_n;
                    if (cb == 2'd2) begin
                        cb <= 2'd0;
                        if (cc == NCH-1) st <= ST_OUT;
                        else             cc <= cc + 4'd1;
                    end else begin
                        cb <= cb + 2'd1;
                    end
                end

                // ---- 归一化 + 饱和 + 输出，同时清累加器 ----
                ST_OUT: begin
                    bus_rev_l <= sat24((acc_l[0] + 48'sd16384) >>> 15);
                    bus_rev_r <= sat24((acc_r[0] + 48'sd16384) >>> 15);
                    bus_cho_l <= sat24((acc_l[1] + 48'sd16384) >>> 15);
                    bus_cho_r <= sat24((acc_r[1] + 48'sd16384) >>> 15);
                    bus_del_l <= sat24((acc_l[2] + 48'sd16384) >>> 15);
                    bus_del_r <= sat24((acc_r[2] + 48'sd16384) >>> 15);
                    bus_vld   <= 1'b1;
                    for (i = 0; i < 3; i = i + 1) begin
                        acc_l[i] <= 48'sd0;
                        acc_r[i] <= 48'sd0;
                    end
                    st <= ST_CAP;
                end

                default: st <= ST_CAP;
            endcase
        end
    end

endmodule

`default_nettype wire
