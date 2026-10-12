//============================================================================
//  norm_sat —— 归一化 + 饱和（模块三设计文档「设计前提 五」的通用单元）
//
//  用途：音频链路上任何 Q1.15 乘法之后的归一化都复用这个模块。
//
//  原理：
//      acc 是累加结果（Q6.38 量级，有符号）。
//      算术右移 SHIFT 位后，低 OUT_W 位是有效载荷，更高位是「保护位」。
//      只有保护位全部等于载荷符号位时才能原样输出，否则视为溢出并饱和。
//
//  例：IN_W=48, SHIFT=15, OUT_W=24
//      移位后 SH_W=33 位，保护位 GRD_W=9 位，即 sh[32:24]。
//      保护位必须等于 sh[23] 的 9 位复制。
//
//  注意：四舍五入在 IN_W 容器里做（不要先截断），否则接近满量程时会假溢出。
//============================================================================

`default_nettype none

module norm_sat #(
    parameter integer IN_W  = 48,   // 输入位宽
    parameter integer SHIFT = 15,   // 右移位数（Q1.15 归一化）
    parameter integer OUT_W = 24,   // 输出位宽
    parameter integer ROUND = 1     // 1 = 先加 2^(SHIFT-1) 再移位
)(
    input  wire signed [IN_W-1:0]  acc,
    output reg  signed [OUT_W-1:0] y
);

    localparam integer SH_W  = IN_W - SHIFT;   // 移位后的位宽
    localparam integer GRD_W = SH_W - OUT_W;   // 保护位个数

    // 四舍五入偏置：2^(SHIFT-1)，必须在 IN_W 容器里表示
    wire signed [IN_W-1:0] rnd = {{(IN_W-1){1'b0}}, 1'b1} <<< (SHIFT-1);

    wire signed [IN_W-1:0] acc_r = (ROUND != 0) ? (acc + rnd) : acc;
    wire signed [SH_W-1:0] sh    = acc_r >>> SHIFT;

    // 保护位与溢出判定
    wire [GRD_W-1:0] grd = sh[SH_W-1:OUT_W];
    wire             ovf = (grd != {GRD_W{sh[OUT_W-1]}});

    always @(*) begin
        if (!ovf) begin
            y = sh[OUT_W-1:0];
        end else begin
            // 正溢出 → 最大正值；负溢出 → 最小负值
            y = sh[SH_W-1] ? {1'b1, {(OUT_W-1){1'b0}}}
                           : {1'b0, {(OUT_W-1){1'b1}}};
        end
    end

endmodule

`default_nettype wire
