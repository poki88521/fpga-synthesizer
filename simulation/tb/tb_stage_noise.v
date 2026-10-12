//============================================================================
//  tb_stage_noise —— 主输出链**逐级噪声隔离**（v2：加斜坡预热段）
//
//  ⚠ v1 的教训：主音量有 **±64/采样的斜坡**，从 0 爬到 1.0 需要
//     **512 个样本**。v1 直接从头采集，测量窗口里混进了过渡段，
//     导致 SNR 看起来只有 25.8 dB（真值应约 82 dB）——**是测量方法的错，不是设计问题**。
//     v2 改为：先跑 1024 个样本的**预热段**（让斜坡走完），再采集测量段。
//
//  **两段都用相干采样**（整数个周期落在窗内）：
//    · 预热段：窗 1024 样本 → 16 个周期      → f = 16×48000/1024     = 750 Hz
//    · 测量段：窗 65536 样本 → 1361 个周期   → f = 1361×48000/65536  = 996.8262 Hz
//  这样各段自己的 FFT 都无泄漏。
//
//  逐级采集：① 直通（理想截断，无抖动）② +主音量 ③ +限幅 ④ +隔直 ⑤ 完整链
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_stage_noise;
    localparam integer HALF_NS = 10;
    localparam integer N_WARM  = 1024;      // 预热样本数（≥512 斜坡）
    localparam integer N_SAMP  = 65536;     // 测量样本数
    localparam integer C_WARM  = 16;        // 预热段周期数（相干）
    localparam integer C_MEAS  = 1361;      // 测量段周期数（相干）

    reg clk = 0, rst_n = 0;
    always #HALF_NS clk = ~clk;

    // ---------------- 两段式相干正弦源 ----------------
    localparam [31:0] INC_WARM = (C_WARM * 4294967296.0) / N_WARM;
    localparam [31:0] INC_MEAS = (C_MEAS * 4294967296.0) / N_SAMP;

    reg [31:0] phase = 0;
    reg        warm  = 1'b1;                 // 1 = 预热段
    wire [31:0] inc  = warm ? INC_WARM : INC_MEAS;

    //  ⚠ 用共享正弦源（**带线性插值**）—— 直接查表会把相位截断到 10 位，
    //    产生 2×基波间距的杂散，把 SNR 从 86 dB 垫高到 55 dB（源伪影，非设计问题）
    `include "sine_src.vh"
    wire signed [23:0] src;
    sine_src #(.TAB_BITS(10), .AMP(2097152)) u_src (.phase(phase), .val(src));

    reg en = 0;

    // ------------- ② master_volume -------------
    wire signed [23:0] v_l, v_r;
    master_volume u_vol (
        .clk(clk), .rst_n(rst_n), .en(en),
        .vol(14'd16383), .mute(1'b0),
        .l_in(src), .r_in(src),
        .l_out(v_l), .r_out(v_r)
    );

    // ------------- ③ + soft_limiter -------------
    wire signed [23:0] lim_l, lim_r;
    wire [15:0] lim_g;
    soft_limiter u_lim (
        .clk(clk), .rst_n(rst_n), .en(en),
        .test_mode(1'b1),                    // 固定增益，排除动态压缩
        .l_in(v_l), .r_in(v_r),
        .l_out(lim_l), .r_out(lim_r),
        .g_out(lim_g)
    );

    // ------------- ④ + dc_block（单声道 ×2）-------------
    wire signed [23:0] dc_l, dc_r;
    dc_block u_dc_l (.clk(clk), .rst_n(rst_n), .en(en), .x(lim_l), .y(dc_l));
    dc_block u_dc_r (.clk(clk), .rst_n(rst_n), .en(en), .x(lim_r), .y(dc_r));

    // ------------- ⑤ + dither16 -------------
    wire [15:0] d_l, d_r;
    dither16 u_dit (
        .clk(clk), .rst_n(rst_n), .en(en),
        .l_in(dc_l), .r_in(dc_r),
        .l_out(d_l), .r_out(d_r)
    );

    // ------------- 完整 master_chain（交叉验证）-------------
    wire [15:0] m_l, m_r;
    master_chain #(.DC_ENABLE(1), .LIM_ENABLE(1)) u_chain (
        .clk(clk), .rst_n(rst_n), .en(en),
        .l_in(src), .r_in(src),
        .vol(14'd16383), .mute(1'b0), .test_mode(1'b1),
        .sample_l(m_l), .sample_r(m_r)
    );

    // ---------------- 采集 ----------------
    integer cyc = 0, nw = 0, n = 0;
    integer f0, f1, f2, f3, f4;

    always @(posedge clk) cyc <= cyc + 1;

    initial begin
        f0 = $fopen("out/stage0_raw.csv",   "w");
        f1 = $fopen("out/stage1_vol.csv",   "w");
        f2 = $fopen("out/stage2_lim.csv",   "w");
        f3 = $fopen("out/stage3_dc.csv",    "w");
        f4 = $fopen("out/stage4_chain.csv", "w");
        if (f0 == 0 || f1 == 0 || f2 == 0 || f3 == 0 || f4 == 0) begin
            $display("FAIL: 打不开输出文件（先 mkdir out）");
            $finish;
        end
    end

    always @(posedge clk) begin
        en <= ((cyc % 100) == 99);
        if (en) begin
            phase <= (warm && (nw + 1 >= N_WARM)) ? 32'd0 : phase + inc;
            if (rst_n) begin
                if (warm) begin
                    // 预热段：只推进相位与斜坡，不写文件
                    if (nw + 1 >= N_WARM) begin
                        warm <= 1'b0;
                        $display("  预热完成（%0d 样本），开始测量段", nw + 1);
                    end
                    nw <= nw + 1;
                end else if (n < N_SAMP) begin
                    $fwrite(f0, "%0d\n", $signed(src)   >>> 8);   // 理想 24→16 截断
                    $fwrite(f1, "%0d\n", $signed(v_l)   >>> 8);
                    $fwrite(f2, "%0d\n", $signed(lim_l) >>> 8);
                    $fwrite(f3, "%0d\n", $signed(dc_l)  >>> 8);
                    $fwrite(f4, "%0d\n", $signed(m_l));
                    n <= n + 1;
                end
            end
        end
    end

    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1;
        $display("=== tb_stage_noise v2：预热 %0d + 测量 %0d 样本 ===", N_WARM, N_SAMP);
        $display("  预热段 %0d Hz / 测量段 %.4f Hz（两段均相干）",
                 C_WARM * 48000 / N_WARM, C_MEAS * 48000.0 / N_SAMP);
        wait (n >= N_SAMP);
        repeat (10) @(posedge clk);
        $fclose(f0); $fclose(f1); $fclose(f2); $fclose(f3); $fclose(f4);
        $display("PASS  tb_stage_noise: 逐级数据已写入 out/（预热 %0d + 测量 %0d）", N_WARM, n);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("FAIL  tb_stage_noise: 超时（n=%0d nw=%0d）", n, nw);
        $finish;
    end
endmodule
`default_nettype wire
