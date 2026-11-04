//============================================================================
//  chan_coef —— 通道系数预计算（通道处理层 第二步的系数部分）
//
//  把「通道音量 x 表情 x 声像」三级合成两个 16-bit Q1.15 系数 gL / gR。
//
//  为什么要合并：
//      文档原先写成「先乘音量得 40-bit，再乘声像」，40-bit x 16-bit = 56-bit，
//      已经超过 DSP 的 48-bit 累加器。合并到控制率之后：
//          g_ch = volume x expression      (16 x 16 -> 32)
//          gL   = g_ch x pan_gL            (16 x 16 -> 32)
//      每步都能压回 16-bit Q1.15，采样率那条路径永远是 24 x 16 = 40-bit。
//
//  定点（全程截断，不做四舍五入，保证与参考模型逐位一致）：
//      vol_q = volume << 8        (7-bit 0~127 -> Q1.15 0~32512)
//      exp_q = expression << 8
//      g_ch  = sat16( (vol_q * exp_q) >>> 15 )
//      gL    = sat16( (g_ch  * pan_gL) >>> 15 )
//      gR    = sat16( (g_ch  * pan_gR) >>> 15 )
//
//  结构：**自由运行**的 2 级流水线（1 通道/拍，3 个乘法器），
//        32 拍把 16 个通道全部刷新一遍，不需要启动/完成握手。
//        参数变化后最多 32 拍（约 0.65 us）就反映到系数上。
//============================================================================

`default_nettype none

module chan_coef #(
    parameter integer NCH = 16
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // 通道状态表（调度层给，稳定寄存器）
    input  wire [NCH*7-1:0]         volume,
    input  wire [NCH*7-1:0]         expression,
    input  wire signed [NCH*16-1:0] pan_gL,
    input  wire signed [NCH*16-1:0] pan_gR,

    // 算好的系数（打包成扁平向量，采样率路径直接切片取用）
    output reg signed [NCH*16-1:0]  gL_flat,
    output reg signed [NCH*16-1:0]  gR_flat
);

    // ---- 饱和到 16-bit 有符号 ----
    function automatic signed [15:0] sat16;
        input signed [31:0] v;
        begin
            if      (v >  32'sd32767) sat16 = 16'sh7FFF;
            else if (v < -32'sd32768) sat16 = 16'sh8000;
            else                      sat16 = v[15:0];
        end
    endfunction

    reg [4:0] pc;                       // 自由运行 0 ~ 31
    reg       p1_v, p2_v;
    reg [3:0] p1_c, p2_c;
    reg signed [15:0] p1_gch;
    //  2026-10-30：每通道增益一阶平滑（消除音量变化时的"噼啪"）
    //  访问速率 = 49.152 MHz / 16 = 3.072 MHz；每次访问走 diff/4096
    //  ⇒ 时间常数 = 4096 x 16 拍 / 49.152 MHz ≈ **1.33 ms**（听不出延迟，足以消除阶跃）
    reg signed [15:0] sm_gch [0:NCH-1];

    wire [3:0] ic = pc[3:0];
    wire       issue = (pc < NCH);

    wire signed [15:0] vol_q = $signed({1'b0, volume[ic*7 +: 7]})     <<< 8;
    wire signed [15:0] exp_q = $signed({1'b0, expression[ic*7 +: 7]}) <<< 8;
    wire signed [31:0] prod1 = vol_q * exp_q;
    wire signed [15:0] gch_c = sat16(prod1 >>> 15);

    wire signed [15:0] pgL = pan_gL[p1_c*16 +: 16];
    wire signed [15:0] pgR = pan_gR[p1_c*16 +: 16];

    integer k;

    //  ---- 一阶平滑：sm_nxt = sm + (target - sm)/4096（带四舍五入，差很小时直接到位）----
    wire signed [15:0] sm_cur = sm_gch[p1_c];
    wire signed [31:0] sm_d   = $signed(p1_gch) - $signed(sm_cur);
    wire signed [31:0] sm_abs = (sm_d < 0) ? -sm_d : sm_d;
    wire signed [31:0] sm_rnd = (sm_d < 0) ? (sm_d - 32'sd2048) : (sm_d + 32'sd2048);
    wire signed [31:0] sm_stp = (sm_abs > 32'sd2048) ? (sm_rnd >>> 12) : sm_d;
    //  ⚠ 2026-11-02 修正：**位选择 `sm_stp[15:0]` 在 Verilog 里永远是无符号**，
    //     直接参与 `sm_cur + sm_stp[15:0]` 会让整个表达式变无符号 ⇒ 负的步进被当成
    //     巨大的正数 ⇒ sat16 钳到 32767 ⇒ 平滑值永远停在"最大增益"，**任何音量/表情
    //     变化都被忽略**（现场现象：CC11 表情无效果、CC7 单通道音量无效果）。
    //     修法：先赋给 signed wire 保住符号性，再相加。
    wire signed [15:0] sm_stp16 = sm_stp[15:0];
    wire signed [15:0] sm_nxt   = sat16(sm_cur + sm_stp16);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc    <= 5'd0;
            p1_v  <= 1'b0;  p2_v  <= 1'b0;
            p1_c  <= 4'd0;  p2_c  <= 4'd0;
            p1_gch<= 16'sd0;
            for (k = 0; k < NCH; k = k + 1) begin
                gL_flat[k*16 +: 16] <= 16'sd32767;   // 默认系数 = 1.0
                gR_flat[k*16 +: 16] <= 16'sd32767;
                sm_gch[k]           <= 16'sd32768;   // 平滑器初值 = 1.0
            end
        end else begin
            pc <= pc + 5'd1;

            // 第 1 级：音量 x 表情
            p1_v   <= issue;
            p1_c   <= ic;
            p1_gch <= gch_c;

            // 第 2 级：x 声像 -> gL / gR（用**已平滑**的 sm_gch，p1_c 同源）
            p2_v <= p1_v;
            p2_c <= p1_c;
            if (p1_v) begin
                gL_flat[p1_c*16 +: 16] <= sat16((sm_cur * pgL) >>> 15);
                gR_flat[p1_c*16 +: 16] <= sat16((sm_cur * pgR) >>> 15);
                sm_gch [p1_c]           <= sm_nxt;
            end
        end
    end

endmodule

`default_nettype wire
