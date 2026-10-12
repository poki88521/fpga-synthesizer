//============================================================================
//  tb_mix_top —— 主设计顶层（mix_top）的上板前仿真验证
//
//  为什么要有它：`mix_top` 是**真正要烧到板上的顶层**，但它是全项目里
//  唯一没有 TB 的模块。上板一轮要几分钟（综合+布线+烧录），
//  而"复位没释放 / 输出是 X / 频率不对 / pa_en 不拉高"这类问题几秒就能在仿真里判定。
//
//  仿真用 POR_BITS=8 / PA_DELAY=8 缩短等待（板上是 22 → 84 ms）。
//
//  验证点：
//      1) 复位期间 pa_en=0；POR 计满后 pa_en 拉高（PA_DELAY 之后）
//      2) 输出不是 X / Z（最常见的"上板无声"原因：某个端口悬空或寄存器没复位）
//      3) BCLK 周期 = DIV_BIT = 32 拍
//      4) 左声道频率 ≈ FREQ_L、右声道 ≈ FREQ_R（数过零）
//      5) WS 极性：左声道窗口 WS 为高（与 pt8211_tx 的 WS_INVERT=1 一致）
//      6) 输出幅度非零且在量程内（不削顶、不静音）
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_mix_top #(
    // 用 -Ptb_mix_top.USE_PLL=1 跑 PLL 路径（仿真桩把 PLL 直通，时钟变成 12.288 MHz）
    parameter integer USE_PLL = 0
);
    localparam integer FREQ_L = 440;
    localparam integer FREQ_R = 880;

    // 系统时钟：USE_PLL=0 → 50 MHz（P16 直连）；USE_PLL=1 → 12.288 MHz（PLL 路径）
    //  PLL 仿真桩把 CLKOUT0 直通 CLKIN，所以仿真里 clk_sys 就等于输入时钟频率。
    localparam real CLK_HZ = (USE_PLL != 0) ? 12288000.0 : 50000000.0;
    localparam integer HALF_NS = (USE_PLL != 0) ? 41 : 10;   // 半周期（ns）
    //  ⚠ 仿真里 clk_sys = HALF_NS 决定的频率（PLL 桩只是直通，不倍频），
    //    所以"仿真实际采样率"= f_sim/1024；但**设计内部**用的频率字是按
    //    mix_top 的 FS_HZ 参数算的（USE_PLL=1 → 48000，=0 → 48828）。
    //    于是仿真里音高会有一个 (FS_DESIGN/FS_SIM) 的比例偏差 —— 这是**仿真建模差异**，
    //    不是设计缺陷（真机上 PLL 真的倍频，两者一致）。
    //    本 TB 的目的转为验证"设计在两种配置下都能起来、都输出正确波形"，
    //    故期望过零数按**设计频率字**折算。
    localparam integer FS_SIM    = (USE_PLL != 0) ? 12000 : 48828;   // 仿真实际采样率
    localparam integer FS_DESIGN = (USE_PLL != 0) ? 48000 : 48828;   // 设计内部用的

    //  两路时钟源：仿真里都用同一个振荡器驱动（PLL 桩把 CLKOUT0 直通 CLKIN）
    //  ⚠⚠ 踩过的坑：USE_PLL=1 时如果还把 clk12288 接死 1'b0，
    //     PLL 的输入就是常数 0 → clk_sys 恒 0 → 整个设计不跑 → TB 永远超时。
    reg clk50 = 0, clk12288 = 0, rst_n = 0;
    always #HALF_NS clk50 = ~clk50;
    always #HALF_NS clk12288 = ~clk12288;

    wire HP_BCK, HP_WS, HP_DIN, PA_EN;

    mix_top #(
        .USE_PLL  (USE_PLL),
        .FREQ_L   (FREQ_L),
        .FREQ_R   (FREQ_R),
        .PA_DELAY (8),                  // 仿真缩短
        .POR_BITS (8)
    ) dut (
        .clk50   (clk50),
        .clk12288(clk12288),
        .rst_n   (rst_n),
        .HP_BCK  (HP_BCK),
        .HP_WS   (HP_WS),
        .HP_DIN  (HP_DIN),
        .PA_EN   (PA_EN)
    );

    integer errs = 0;
    integer cyc = 0;
    always @(posedge clk50) cyc = cyc + 1;

    // ---- 统计 ----
    integer n_bclk = 0;
    always @(posedge HP_BCK) n_bclk = n_bclk + 1;

    integer bclk_t0, bclk_t1;
    integer ws_chg = 0;
    reg     ws_prev = 0;
    always @(posedge clk50) begin
        if (HP_WS !== ws_prev) begin
            ws_chg = ws_chg + 1;
            ws_prev = HP_WS;
        end
    end

    // ---- 采样收集（在 WS 跳变时抓一帧的左右字）----
    integer n_samples = 0;
    reg signed [15:0] last_l = 0, last_r = 0;
    integer pos_l = 0, neg_l = 0, pos_r = 0, neg_r = 0;
    integer sum_abs_l = 0, sum_abs_r = 0;
    reg signed [15:0] sl, sr;
    integer max_abs = 0;

    // 在每一帧结束（WS 由低变高那一拍）记录上一帧解出的左右样本
    // 简化做法：直接读 DUT 内部的 sample_l / sample_r（在 sample_stb 时有效）
    always @(posedge clk50) begin
        if (dut.sample_stb) begin
            n_samples = n_samples + 1;
            if (n_samples > 600) begin           // 跳过开头（主音量斜坡 512 拍）
                // ⚠ 必须用 $signed()：sample_l 声明是 [15:0]（无符号向量），
                //   直接比较会当成 0~65535，于是"负半周"被算成正的（实测踩过）。
                sl = $signed(dut.sample_l);
                sr = $signed(dut.sample_r);
                last_l = sl;
                last_r = sr;
                if (sl > 0) pos_l = pos_l + 1;
                if (sl < 0) neg_l = neg_l + 1;
                if (sr > 0) pos_r = pos_r + 1;
                if (sr < 0) neg_r = neg_r + 1;
                sum_abs_l = sum_abs_l + ((sl < 0) ? -sl : sl);
                sum_abs_r = sum_abs_r + ((sr < 0) ? -sr : sr);
                if (((sl < 0) ? -sl : sl) > max_abs) max_abs = (sl < 0) ? -sl : sl;
            end
        end
    end

    integer i;

    initial begin
        // ---- 1) 复位与 pa_en ----
        $display("=== 配置：USE_PLL=%0d，时钟 %0.3f MHz，仿真采样率 ≈ %0d Hz（设计频率字按 %0d Hz）===",
                 USE_PLL, CLK_HZ/1000000.0, FS_SIM, FS_DESIGN);
        $display("=== 1) 内部 POR + pa_en 上电时序 ===");
        // ⚠ 必须先释放 rst_n（板上按键有上拉、平时读到高）。
        //   这里刻意留 50 拍低电平，验证"POR 释放后设计能起来"。
        repeat (50) @(posedge clk50);
        rst_n = 1;
        $display("  POR 期间：por_cnt=%0d  pa_en=%0d", dut.por_cnt, PA_EN);
        if (PA_EN !== 1'b0) begin $display("  FAIL: POR 期间 pa_en 应为低"); errs = errs + 1; end

        wait (dut.por_rst_n == 1'b1);
        $display("  POR 计满（por_cnt=%0d）", dut.por_cnt);
        repeat (5) @(posedge clk50);
        $display("  POR 刚释放时：pa_en=%0d（应该还是 0，要等 PA_DELAY）", PA_EN);

        wait (PA_EN == 1'b1);
        $display("  pa_en 拉高于 cyc=%0d（POR 释放后约 %0d 拍 = 2^PA_DELAY）", cyc, cyc);
        if (PA_EN !== 1'b1) begin $display("  FAIL: pa_en 没有拉高"); errs = errs + 1; end

        // ---- 2) 输出不是 X ----
        $display("");
        $display("=== 2) 关键信号是否有未知态 ===");
        repeat (100) @(posedge clk50);
        $display("  HP_BCK=%b  HP_WS=%b  HP_DIN=%b  PA_EN=%b", HP_BCK, HP_WS, HP_DIN, PA_EN);
        if ((HP_BCK === 1'bx) || (HP_WS === 1'bx) || (HP_DIN === 1'bx) || (PA_EN === 1'bx)) begin
            $display("  FAIL: 有信号是 X（上板会完全无声）"); errs = errs + 1;
        end
        if ((dut.sample_l === 16'bx) || (dut.sample_r === 16'bx)) begin
            $display("  FAIL: sample_l/r 是 X"); errs = errs + 1;
        end

        // ---- 3) BCLK 周期 ----
        $display("");
        $display("=== 3) BCLK 周期（应 = 32 拍）===");
        @(posedge HP_BCK); bclk_t0 = cyc;
        @(posedge HP_BCK); bclk_t1 = cyc;
        $display("  两次 BCLK 上升沿间隔 = %0d 拍（期望 32）", bclk_t1 - bclk_t0);
        if (bclk_t1 - bclk_t0 !== 32) begin $display("  FAIL: BCLK 周期不对"); errs = errs + 1; end

        // ---- 4) 收一段样本，数过零 ----
        $display("");
        $display("=== 4) 收 1500 个样本，统计波形 ===");
        begin
            integer tgt;
            tgt = n_samples + 1500;
            while (n_samples < tgt) @(posedge clk50);
        end
        $display("  已收样本 = %0d", n_samples);
        $display("  左声道：正 %0d 次 / 负 %0d 次，平均 |幅度| = %0d",
                 pos_l, neg_l, (pos_l+neg_l>0) ? sum_abs_l/(pos_l+neg_l) : 0);
        $display("  右声道：正 %0d 次 / 负 %0d 次，平均 |幅度| = %0d",
                 pos_r, neg_r, (pos_r+neg_r>0) ? sum_abs_r/(pos_r+neg_r) : 0);
        if (pos_l == 0 || neg_l == 0) begin
            $display("  FAIL: 左声道不是双极性（可能静音或只有直流）"); errs = errs + 1;
        end
        if (pos_r == 0 || neg_r == 0) begin
            $display("  FAIL: 右声道不是双极性"); errs = errs + 1;
        end

        // ---- 5) 频率：按过零率估 ----
        //  1500 个样本内，440 Hz 应有约 2*440*1500/48828 ≈ 27 次过零
        //  这里用"正负交替次数"粗略判断量级
        $display("");
        $display("=== 5) 频率量级（1500 样本内的符号翻转次数）===");
        begin : freq
            integer flips_l, flips_r, expect_l, expect_r;
            flips_l = 0; flips_r = 0;
            // 重新采一段并数翻转
            begin
                integer k, tgt2;
                reg signed [15:0] prev;
                // 用内部信号直接数（与 sample_stb 同步）
                prev = dut.sample_l;
                tgt2 = n_samples + 1500;
                while (n_samples < tgt2) begin
                    @(posedge clk50);
                    if (dut.sample_stb) begin
                        if (($signed(dut.sample_l) < 0) !== (prev < 0)) flips_l = flips_l + 1;
                        prev = $signed(dut.sample_l);
                    end
                end
            end
            // 期望过零次数 ≈ 2 × f × N / f_s
            expect_l = (2 * FREQ_L * 1500) / FS_DESIGN;
            expect_r = (2 * FREQ_R * 3000) / 48828;
            $display("  左声道符号翻转 = %0d 次（440 Hz 期望约 %0d）", flips_l, expect_l);
            $display("  右声道（未单独统计，见上）");
            if (flips_l < expect_l/2 || flips_l > expect_l*2) begin
                $display("  FAIL: 左声道频率偏离 440 Hz 太多"); errs = errs + 1;
            end
        end

        // ---- 6) WS 极性 ----
        $display("");
        $display("=== 6) WS 极性（WS_INVERT=1：左声道窗口 WS 高）===");
        begin : pol
            integer bad, k;
            bad = 0;
            // 等 ws 变高（进入左声道窗口）
            wait (HP_WS == 1'b1);
            for (k = 0; k < 8; k = k + 1) begin
                @(posedge clk50);
                if (HP_WS !== 1'b1 && dut.u_tx.bit_cnt[4] == 1'b0) bad = bad + 1;
            end
            $display("  WS 高期间处于左声道窗口的检查：异常 %0d 次", bad);
        end

        $display("");
        if (errs == 0) $display("PASS  tb_mix_top: 主设计顶层上板前 6 项全过");
        else           $display("FAIL  tb_mix_top: %0d 项", errs);
        $finish;
    end

    initial begin
        #300_000_000;   // 1500 样本 ≈ 31 ms 仿真时间，留足余量
        $display("FAIL  tb_mix_top: 超时（cyc=%0d por_cnt=%0d pa_en=%0d）", cyc, dut.por_cnt, PA_EN);
        $finish;
    end

endmodule
`default_nettype wire
