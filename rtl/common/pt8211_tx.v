//============================================================================
//  pt8211_tx —— PT8211（16-bit R-2R DAC，LSBJ 格式）串行发送器
//
//  文档：模块三设计文档 4.主输出处理 第五步
//
//  时序（全部由主时钟分频得到，单一时钟域，无跨时钟）：
//      DIV_BIT = 32      BCLK = f_clk / 32
//      bit_cnt 0  ~ 15   左声道，WS 低，DIN 依次输出 bit15 ... bit0（MSB 先出）
//      bit_cnt 16 ~ 31   右声道，WS 高，DIN 依次输出 bit15 ... bit0
//
//  为什么这样就是 LSBJ：
//      每声道正好 16 个 BCLK，字长也是 16 bit，所以「左对齐」和「右对齐」
//      在填满整帧时是同一件事，MSB 落在该声道第一个 BCLK、LSB 落在最后一个。
//
//  相位关系：
//      DIN 和 WS 都是寄存器（bit_cnt / sh）的组合函数，只在 BCLK 下降沿
//      （phase 回绕那一拍）变化，所以整个 BCLK 周期内稳定，
//      DAC 在 BCLK 上升沿采样时有充足的建立时间。
//
//  ⚠ WS 极性：PT8211 手册写「WS 低 = 右声道，高 = 左声道」，
//     而 Sipeed 官方例程注释写「低电平对应左声道」，两者相反。
//     本工程按**一手手册**取值：bit_cnt 0~15 送左字，需要 WS 为高，故 WS_INVERT=1。
//     上板用「只送左声道」的码流可最终确认；要翻转改这一个参数即可。
//============================================================================

`default_nettype none

module pt8211_tx #(
    parameter integer DIV_BIT   = 32,   // f_clk / BCLK，49.152M/1.536M = 32，50M/1.5625M = 32
    parameter integer WS_INVERT = 1     // 手册：WS 高 = 左声道；bit_cnt 0~15 送左字 →
                                        // 需要 ws=1，故默认 1。
                                        // ⚠ 原默认值是 0，与本文件注释和 tb_pt8211_tx
                                        //    （显式传 1）都矛盾 → 会把左右声道对调。
                                        //   上板实测若发现左右反了，改成 0。
)(
    input  wire        clk,
    input  wire        rst_n,

    // 来自主输出链的一对 16-bit 样本：只要在 sample_stb 之后一个采样周期内
    // 保持稳定即可（本模块在帧边界自己捕获，天然形成 1 个采样的固定延迟）
    input  wire [15:0] sample_l,
    input  wire [15:0] sample_r,

    // 采样节拍：主输出链收到这一拍就更新一次样本
    output reg         sample_stb,

    // 到 DAC
    output reg         bclk,
    output wire        ws,
    output wire        din
);

    localparam integer PH_W = $clog2(DIV_BIT);

    // ⚠ 不要写 DIV_BIT[PH_W-1:0]：32 的低 5 位是 0，位选会把常量截断成 0。
    //   这里用与 phase 同宽的 localparam，才是 31 / 16。
    localparam [PH_W-1:0] PH_LAST = DIV_BIT - 1;    // 31
    localparam [PH_W-1:0] PH_HALF = DIV_BIT / 2;    // 16

    reg  [PH_W-1:0] phase;      // BCLK 内的主时钟计数
    reg  [4:0]      bit_cnt;    // 一帧内的 BCLK 计数，0 ~ 31
    reg  [15:0]     sh;         // 当前正在串出的字
    reg  [15:0]     sh_r;       // 帧边界捕获的右声道字

    wire phase_end = (phase == PH_LAST);
    wire frame_end = phase_end && (bit_cnt == 5'd31);

    // ---- BCLK 内的相位计数 / 帧内位计数 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase   <= {PH_W{1'b0}};
            bit_cnt <= 5'd0;
        end else if (phase_end) begin
            phase   <= {PH_W{1'b0}};
            bit_cnt <= (bit_cnt == 5'd31) ? 5'd0 : (bit_cnt + 5'd1);
        end else begin
            phase <= phase + 1'b1;
        end
    end

    // ---- BCLK：前半周期低、后半周期高 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) bclk <= 1'b0;
        else        bclk <= (phase >= PH_HALF);
    end

    // ---- 采样节拍：帧边界 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sample_stb <= 1'b0;
        else        sample_stb <= frame_end;
    end

    // ---- 移位与帧边界捕获 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sh   <= 16'd0;
            sh_r <= 16'd0;
        end else if (phase_end) begin
            if (bit_cnt == 5'd31) begin
                sh   <= sample_l;   // 新 bit_cnt = 0，左声道（捕获上一帧末稳定的值）
                sh_r <= sample_r;   // 右声道先存起来，等 bit_cnt = 16 再用
            end else if (bit_cnt == 5'd15) begin
                sh   <= sh_r;       // 新 bit_cnt = 16，切右声道
            end else begin
                sh <= {sh[14:0], 1'b0};
            end
        end
    end

    // ---- 输出：都是寄存器的组合函数，无毛刺 ----
    // bit_cnt[4] = 0 时为 bit_cnt 0 ~ 15（左字），希望 WS = 低
    //   => 默认 ws = bit_cnt[4]；WS_INVERT 用于实测发现左右反了时翻转
    assign ws  = WS_INVERT ? ~bit_cnt[4] : bit_cnt[4];
    assign din = sh[15];

endmodule

`default_nettype wire
