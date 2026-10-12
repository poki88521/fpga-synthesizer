//============================================================================
//  sine_src.vh —— 理想正弦测试源（共享 include）
//
//  ⚠⚠ **必须用线性插值**，不能用"1024 点表 + 相位截断"直接查表！
//
//  实测数据（同一 FFT，相干采样）：
//      1024 点表 + 相位截断（无插值）  → SNR **55.03** dB   ← 源伪影主导
//      1024 点表 + 线性插值            → SNR **86.03** dB   ← 与理论值一致
//      $sin() 浮点基准                → SNR **86.03** dB
//  理论值（−12 dBFS、理想 16 bit 量化）= 86.05 dB
//
//  原因：取 `phase[31:22]` 做表索引相当于把相位截断到 10 位，
//        会产生 **2×基波间距的宽带杂散**（实测在 11.75/13.75 kHz 等位置），
//        把噪声底垫高约 31 dB，**看起来像设计有噪声，其实是测试源的锅**。
//  这和真实单声部层 DDS 的做法也一致（DDS 本来就是"查表 + 线性插值"）。
//
//  用法：
//      `include "sine_src.vh"
//      // 在模块里声明：
//      reg [31:0] phase;
//      wire signed [23:0] src;
//      sine_src #(.TAB_BITS(10), .AMP_HZ(2097152)) u_src (.phase(phase), .val(src));
//============================================================================

//  ⚠ **包含保护**：多个 TB 可能同时 `include` 本文件（各自例化 `sine_src`），
//    没有保护会报 `'sine_src' has already been declared`。
`ifndef SINE_SRC_VH
`define SINE_SRC_VH

//  正弦表：TAB_BITS 位地址，值域 ±AMP
module sine_src #(
    parameter integer TAB_BITS = 10,                 // 表地址位宽
    parameter integer AMP      = 2097152             // 幅度（24 位域）
)(
    input  wire [31:0]           phase,              // 32 位相位累加器
    output wire signed [23:0]    val
);
    localparam integer TAB = 1 << TAB_BITS;
    reg signed [23:0] tab [0:TAB-1];
    integer k;
    initial
        for (k = 0; k < TAB; k = k + 1)
            tab[k] = $rtoi($sin(2.0 * 3.141592653589793 * k / TAB) * AMP);

    //  整数部分取高 TAB_BITS 位；小数部分取紧跟其后的 TAB_BITS 位
    wire [TAB_BITS-1:0] i0 = phase[31 -: TAB_BITS];
    wire [TAB_BITS-1:0] i1 = i0 + 1'b1;                       // 自动回绕
    wire [TAB_BITS-1:0] fr = phase[31-TAB_BITS -: TAB_BITS];
    wire signed [23:0]  a  = tab[i0];
    wire signed [23:0]  b  = tab[i1];
    //  线性插值：a + (b−a)*fr / 2^TAB_BITS
    wire signed [47:0] dif = $signed(b) - $signed(a);
    assign val = a + (dif * $signed({1'b0, fr}) >>> TAB_BITS);
endmodule

`endif  // SINE_SRC_VH
