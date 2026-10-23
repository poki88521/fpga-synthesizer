//============================================================================
//  sd_out —— 1 位 sigma-delta 调制器（给示波器做"数字音频探针"）
//
//  用途
//      板子的音频出口是 PT8211 DAC → 功放 → 耳机口。如果怀疑"炸"来自
//      DAC/功放/模拟通路而不是 FPGA 内部，就需要一个**绕过模拟链路**的探针。
//      本模块把 16 位有符号采样实时调制成 1 位位流，接到 PMOD 引脚，
//      示波器用低通 / FFT 就能看到 FPGA 内部真正的音频。
//
//      判据：
//        PMOD 干净、耳机炸  → 问题在 DAC / 功放 / 模拟通路
//        PMOD 也炸          → 问题确实在 FPGA 内部
//
//  原理
//      一阶 sigma-delta：
//          integ ← integ + x − fb          （fb = ±32767，由量化输出决定）
//          sd    = (integ ≥ 0)
//      位流的**低频分量**就是 x。过采样率 = clk_sys / (2 × 20 kHz) ≈ 1200（49.152 MHz）
//      一阶的 SNR ≈ 6.02 + 30·log10(OSR) ≈ 90 dB，做频谱分析绰绰有余。
//
//  接法
//      clk    = clk_sys（49.152 MHz）
//      x      = sample_l（master_chain 的输出，PT8211 那一路）
//      sd     = PMOD1_IO0（J24 第 1 脚，C24）
//
//  ⚠ 示波器设置建议
//      · 直流耦合，1 V/div 左右（LVCMOS33）
//      · 采集到足够长的记录（至少 20 ms），再用 FFT
//      · 一阶 SD 的高频量化噪声很大是**正常的**，看 20 kHz 以下
//      · 如果要直接用示波器自带的 FFT，加一个 20 kHz 低通/带宽限制
//============================================================================

`timescale 1ns/1ps

module sd_out (
    input  wire                clk,       // clk_sys
    input  wire                rst_n,     // 同步复位（高有效解除）
    input  wire signed [15:0]  x,         // 16 位有符号采样
    output wire                sd         // 1 位位流
);

    //  积分器用 18 位：16 位输入 + 2 位余量，防止长时间累积溢出
    reg  signed [17:0] integ;

    wire signed [17:0] x18 = {{2{x[15]}}, x};          // 符号扩展到 18 位

    //  量化：符号位为 0 判为正。注意 integ 是 reg，读的是"上一拍的值"，
    //  所以 sd 与 fb 用的是同一份 integ，反馈不会自相矛盾。
    wire               sd_v = ~integ[17];
    wire signed [17:0] fb   = sd_v ? 18'sd32767 : -18'sd32767;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) integ <= 18'sd0;
        else        integ <= integ + x18 - fb;
    end

    assign sd = sd_v;

endmodule
