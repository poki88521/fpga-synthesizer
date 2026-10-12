//============================================================================
//  tb_full_top —— 模块三**完整链路**顶层验证
//
//  与 `tb_mix_top`（最小闭环）的区别：这里验证的是
//      voice_slot_seq + test_voice_gen → chan_layer → send_bus → fx_top
//                                        → main_mix → master_chain → pt8211_tx
//  整条链路接通后**确实有音频输出、且时序正常**。
//
//  仿真用 POR_BITS=8 / PA_DELAY=8 / TEST_MODE_DEFAULT=0 缩短等待并关掉测试模式，
//  以便观察真实音频通路（测试模式会把效果全旁路）。
//
//  验证点：
//      1) 内部 POR 释放后 pa_en 拉高（且**保持**，不是单拍脉冲）
//      2) 关键信号无未知态（BCLK / WS / DIN / PA_EN）
//      3) BCLK 周期 = 32 拍
//      4) 一帧 = 32 个 BCLK + 2 次 WS 跳变
//      5) 输出样本**双极性、非静音**（证明通道层→效果→主混音→主输出整条链在传数据）
//      6) 输出**不削顶**（|sample| 不到满量程）
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_full_top #(
    // 用 -Ptb_full_top.USE_PLL=1 跑 PLL 路径（PLL 仿真桩直通 CLKIN，时钟变 12.288 MHz）
    parameter integer USE_PLL = 0
);
    // 系统时钟：USE_PLL=0 → 50 MHz（P16 直连）；USE_PLL=1 → 12.288 MHz（PLL 路径）
    //  PLL 桩把 CLKOUT0 直通 CLKIN，所以仿真里 clk_sys 就等于输入时钟频率。
    localparam integer HALF_NS = (USE_PLL != 0) ? 41 : 10;

    reg clk50 = 0, clk12288 = 0;
    always #HALF_NS clk50   = ~clk50;
    always #HALF_NS clk12288 = ~clk12288;

    wire HP_BCK, HP_WS, HP_DIN, PA_EN;

    full_top #(
        .USE_PLL   (USE_PLL),
        .TEST_MODE_DEFAULT (0),          // 关掉测试模式，验真实音频通路
        .PA_DELAY  (8),
        .POR_BITS  (8)
    ) dut (
        .clk50(clk50), .clk12288(clk12288),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN)
    );

    integer errs = 0;
    integer cyc  = 0;
    always @(posedge clk50) cyc = cyc + 1;

    // ---- BCLK 统计 ----
    integer n_bclk = 0;
    always @(posedge HP_BCK) n_bclk = n_bclk + 1;

    integer ws_chg = 0;
    reg     ws_prev = 0;
    always @(posedge clk50) begin
        if (HP_WS !== ws_prev) begin
            ws_chg = ws_chg + 1;
            ws_prev = HP_WS;
        end
    end

    // ---- 样本统计 ----
    integer n_sample = 0;
    integer pos_l = 0, neg_l = 0, pos_r = 0, neg_r = 0;
    integer max_abs = 0;
    reg signed [15:0] sl, sr;

    always @(posedge clk50) begin
        if (dut.sample_stb) begin
            n_sample = n_sample + 1;
            if (n_sample > 700) begin          // 跳过主音量上电斜坡（512 拍）
                sl = $signed(dut.sample_l);
                sr = $signed(dut.sample_r);
                if (sl > 0) pos_l = pos_l + 1;
                if (sl < 0) neg_l = neg_l + 1;
                if (sr > 0) pos_r = pos_r + 1;
                if (sr < 0) neg_r = neg_r + 1;
                if (((sl < 0) ? -sl : sl) > max_abs) max_abs = (sl < 0) ? -sl : sl;
                if (((sr < 0) ? -sr : sr) > max_abs) max_abs = (sr < 0) ? -sr : sr;
            end
        end
    end

    integer b0, b1;

    initial begin
        $display("=== 1) 内部 POR 与 pa_en（必须锁存保持）===");
        repeat (40) @(posedge clk50);
        if (PA_EN !== 1'b0) begin $display("  FAIL: POR 期间 pa_en 应为低"); errs = errs + 1; end
        wait (dut.por_rst_n == 1'b1);
        wait (PA_EN == 1'b1);
        $display("  pa_en 拉高于 cyc=%0d", cyc);
        // 保持性检查：等 2000 拍后仍应为 1（旧实现是单拍脉冲，这里会抓到）
        repeat (2000) @(posedge clk50);
        $display("  2000 拍后 pa_en = %0d（应为 1，**保持**而不是单拍脉冲）", PA_EN);
        if (PA_EN !== 1'b1) begin $display("  FAIL: pa_en 没有保持（单拍脉冲 bug）"); errs = errs + 1; end

        $display("");
        $display("=== 2) 关键信号无未知态 ===");
        $display("  HP_BCK=%b HP_WS=%b HP_DIN=%b PA_EN=%b", HP_BCK, HP_WS, HP_DIN, PA_EN);
        if ((HP_BCK === 1'bx) || (HP_WS === 1'bx) || (HP_DIN === 1'bx) || (PA_EN === 1'bx)) begin
            $display("  FAIL: 有信号是 X"); errs = errs + 1;
        end
        if ((dut.sample_l === 16'bx) || (dut.sample_r === 16'bx)) begin
            $display("  FAIL: sample_l/r 是 X"); errs = errs + 1;
        end

        $display("");
        $display("=== 3) BCLK 周期 ===");
        @(posedge HP_BCK); b0 = cyc;
        @(posedge HP_BCK); b1 = cyc;
        $display("  两次 BCLK 上升沿间隔 = %0d 拍（期望 32）", b1 - b0);
        if (b1 - b0 !== 32) begin $display("  FAIL: BCLK 周期不对"); errs = errs + 1; end

        $display("");
        $display("=== 4) 一帧结构（32 BCLK / 2 次 WS 跳变）===");
        begin : frame
            integer r0, r1, w0, w1, k;
            while (dut.u_tx.bit_cnt != 5'd0) @(posedge clk50);
            r0 = n_bclk; w0 = ws_chg;
            for (k = 0; k < 32*32; k = k + 1) @(posedge clk50);
            r1 = n_bclk; w1 = ws_chg;
            $display("  1024 拍内 BCLK 上升沿 = %0d（期望 32）", r1 - r0);
            $display("  1024 拍内 WS 跳变    = %0d（期望 2）", w1 - w0);
            if (r1 - r0 !== 32) begin $display("  FAIL: BCLK 数不对"); errs = errs + 1; end
            if (w1 - w0 !== 2)  begin $display("  FAIL: WS 跳变数不对"); errs = errs + 1; end
        end

        $display("");
        $display("=== 5) 收 1500 个样本，统计输出波形 ===");
        begin
            integer tgt;
            tgt = n_sample + 1500;
            while (n_sample < tgt) @(posedge clk50);
        end
        $display("  左声道：正 %0d / 负 %0d", pos_l, neg_l);
        $display("  右声道：正 %0d / 负 %0d", pos_r, neg_r);
        $display("  峰值（|16bit|）= %0d / 32767", max_abs);
        if (pos_l == 0 || neg_l == 0) begin
            $display("  FAIL: 左声道不是双极性（链路可能没在传数据）"); errs = errs + 1;
        end
        if (pos_r == 0 || neg_r == 0) begin
            $display("  FAIL: 右声道不是双极性"); errs = errs + 1;
        end

        $display("");
        $display("=== 6) 不削顶 ===");
        if (max_abs >= 32767) begin
            $display("  FAIL: 输出削顶（顶到满量程）"); errs = errs + 1;
        end else begin
            $display("  峰值 %0d < 32767 → 不削顶 ✓", max_abs);
        end

        $display("");
        if (errs == 0) $display("PASS  tb_full_top: 完整链路 6 项全过");
        else           $display("FAIL  tb_full_top: %0d 项", errs);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("FAIL  tb_full_top: 超时（cyc=%0d por_cnt=%0d pa_en=%0d n_sample=%0d）",
                 cyc, dut.por_cnt, PA_EN, n_sample);
        $finish;
    end

endmodule
`default_nettype wire
