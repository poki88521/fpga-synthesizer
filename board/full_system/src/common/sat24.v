//============================================================================
//  sat24 —— 通用「归一化 + 饱和」单元
//
//  依据：documents/硬件实现.md §四.2（1）
//
//  把 48-bit 累加结果（Q6.38 量级）压回 24-bit Q1.23：
//    1. 四舍五入        acc_rnd = acc + 2^(SHIFT-1)
//    2. 归一化          sh      = acc_rnd >>> SHIFT      （29-bit 有效，Q6.23）
//    3. 取低 29 位      v       = sh[28:0]
//    4. 溢出判断        ovf     = (v[28:24] != {5{v[23]}})
//    5. 输出            ovf=0 → v[23:0]；ovf=1 → v[28] 判正负，正给 0x7FFFFF、负给 0x800000
//
//  判据含义：24-bit 有符号要装得下，要求第 23 位以上全是符号位，
//           故比较 v[28:24] 是否等于 v[23] 的 5 位复制。
//
//  全模块复用：VCA 乘法后、通道总线累加读出、主混音求和都走这一个单元。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module sat24 #(
    parameter integer ACCW  = 48,        // 输入累加器位宽
    parameter integer OUTW  = 24,        // 输出位宽（Q1.23）
    parameter integer SHIFT = 15         // 归一化右移量
) (
    input  wire signed [ACCW-1:0] acc,
    output wire signed [OUTW-1:0] y
);

    localparam integer VW = OUTW + 5;    // 29 位有效容器（OUTW=24 时）
    // SHIFT=0 时不做归一化（调用方已自行右移，例如 VCA 的 >>>30），
    // 此时 sat24 退化为「纯 24 位饱和钳位」。用 RS 避免出现负移位量。
    localparam integer RS = (SHIFT > 0) ? (SHIFT - 1) : 0;

    // 1. 四舍五入：在宽容器里加，不要先截断
    // ⚠ 必须显式加括号：Verilog 里移位 <<< 的优先级低于加法 +，
    //   写成 acc + x <<< 14 会被解析成 (acc + x) <<< 14。
    wire signed [ACCW-1:0] rnd_const = (SHIFT > 0)
                                     ? ({{(ACCW-1){1'b0}}, 1'b1} <<< RS)
                                     : {ACCW{1'b0}};
    wire signed [ACCW-1:0] acc_rnd   = acc + rnd_const;

    // 2. 归一化
    wire signed [ACCW-1:0] sh = acc_rnd >>> SHIFT;

    // 3. 取低 VW 位
    wire signed [VW-1:0] v = sh[VW-1:0];

    // 4. 溢出判断
    wire ovf = (v[VW-1:OUTW] != {(VW-OUTW){v[OUTW-1]}});

    // 5. 输出
    assign y = ovf ? (v[VW-1] ? {1'b1, {(OUTW-1){1'b0}}}   // 负溢出 0x800000
                             : {1'b0, {(OUTW-1){1'b1}}})   // 正溢出 0x7FFFFF
                   : v[OUTW-1:0];

endmodule

`default_nettype wire
