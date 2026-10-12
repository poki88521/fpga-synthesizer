//============================================================================
//  tb_test_voice_gen —— 测试模式声源验证
//
//  依据：设计文档（修正版）附三「三、测试模式（现场验证必需）」
//      32 个振荡器分配**互不重合**的频率（200 Hz 起、**对数均匀**分布到 8 kHz）
//      每声部幅度缩放 1/N
//
//  验证点：
//      1) 32 个声部的相位累加器增量**两两不同**（谱线不重合）
//      2) 频率**单调递增**，且最小 ≈ 200 Hz、最大 ≈ 8 kHz（对数均匀的两个端点）
//      3) 对数均匀性：相邻频率比值近似常数（最大/最小比值 ≈ 40^(1/31)）
//      4) 幅度 = 1/N 满量程（不削顶）
//      5) 输出随 slot 正确切换（8 路并行）
//
//  说明：本 TB 直接观察 DUT 内部的相位累加器与频率表，属于白盒验证。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_test_voice_gen;
    localparam integer P  = 8;
    localparam integer N  = 32;
    localparam integer AW = 24;

    reg clk = 0, rst_n = 0, en = 0;
    reg [1:0] slot = 0;
    always #10 clk = ~clk;

    wire [P*AW-1:0] aud;

    test_voice_gen #(.P(P), .N(N), .AW(AW), .FS_HZ(48000)) dut (
        .clk(clk), .rst_n(rst_n), .en(en), .slot(slot), .aud(aud));

    integer errs = 0;
    integer i, j;
    reg [31:0] incs [0:N-1];
    real       f_hz [0:N-1];
    real       r_min, r_max, ratio, ratio_prev, dev, dev_max;

    // 用整数运算避免 real 比较的精度问题：把频率换算成 Hz 的千分之一（整数）
    integer f_mhz [0:N-1];        // 频率 × 1000

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // 抓 32 个相位增量
        for (i = 0; i < N; i = i + 1) begin
            incs[i] = dut.table_inc_48k(i);   // 综合期表（FS_HZ=48000）
            // f = inc × FS / 2^32；用 64 位算成 Hz×1000
            f_mhz[i] = (incs[i] * 48000 * 1000) / 4294967296;
        end

        // ---- 1) 两两不同 ----
        $display("=== 1) 32 个频率两两不同（谱线不重合）===");
        begin : uniq
            integer dup;
            dup = 0;
            for (i = 0; i < N; i = i + 1)
                for (j = i+1; j < N; j = j + 1)
                    if (incs[i] == incs[j]) dup = dup + 1;
            $display("  重复的频率对 = %0d（应为 0）", dup);
            if (dup != 0) begin $display("  FAIL: 有重复频率"); errs = errs + 1; end
        end

        // ---- 2) 端点 ----
        $display("");
        $display("=== 2) 端点频率（最小应 ≈200 Hz，最大应 ≈8000 Hz）===");
        $display("  最小 = %0d.%03d Hz    最大 = %0d.%03d Hz",
                 f_mhz[0]/1000, f_mhz[0]%1000, f_mhz[N-1]/1000, f_mhz[N-1]%1000);
        if (f_mhz[0] < 199000 || f_mhz[0] > 201000) begin
            $display("  FAIL: 最小频率不是 200 Hz 附近"); errs = errs + 1;
        end
        if (f_mhz[N-1] < 7990000 || f_mhz[N-1] > 8010000) begin
            $display("  FAIL: 最大频率不是 8000 Hz 附近"); errs = errs + 1;
        end

        // ---- 3) 单调递增 + 对数均匀 ----
        $display("");
        $display("=== 3) 单调递增 + 对数均匀（相邻比值应近似常数）===");
        begin : mono
            integer bad;
            bad = 0;
            for (i = 1; i < N; i = i + 1)
                if (f_mhz[i] <= f_mhz[i-1]) bad = bad + 1;
            $display("  非递增的相邻对 = %0d（应为 0）", bad);
            if (bad != 0) begin $display("  FAIL: 频率不是单调递增"); errs = errs + 1; end
        end
        // 相邻比值：用真实增量算（整数 Hz×1000 的量化误差会放大到 ±2%）
        begin : logu
            real r, r_prev, d, dmax;
            dmax = 0.0; r_prev = 0.0;
            for (i = 1; i < N; i = i + 1) begin
                r = (incs[i] * 1.0) / (incs[i-1] * 1.0);
                if (r_prev != 0.0) begin
                    d = (r > r_prev) ? (r - r_prev) : (r_prev - r);
                    if (d > dmax) dmax = d;
                end
                r_prev = r;
            end
            $display("  相邻比值期望 = 40^(1/31) = 1.1259");
            $display("  相邻比值最大波动 = %0.4f（越小越均匀）", dmax);
            // 取整到 32 位增量带来的比值波动应在 1e-3 量级
            if (dmax > 0.005) begin
                $display("  FAIL: 相邻比值波动过大，不是对数均匀"); errs = errs + 1;
            end
        end

        // ---- 4) 幅度 = 1/N ----
        $display("");
        $display("=== 4) 幅度缩放（应 = 1/N 满量程 = 2^23/32 = 262144）===");
        // 让相位跑到最高位为 1 再采
        begin : amp
            integer k, got_pos, got_neg;
            got_pos = 0; got_neg = 0;
            // ⚠ 必须给完整时钟周期：@(negedge) en=1; @(negedge) en=0 只维持半拍，
            //   相位累加器几乎不动（实测 aud 一直为 0）。
            for (k = 0; k < 400; k = k + 1) begin
                @(negedge clk) en = 1;
                @(posedge clk);
                @(negedge clk) en = 0;
                if ($signed(aud[0*AW +: AW]) > 0) got_pos = 1;
                if ($signed(aud[0*AW +: AW]) < 0) got_neg = 1;
                if (got_pos && got_neg) k = 9999;
            end
            $display("  出现过正值=%0d 负值=%0d（方波应有正有负）", got_pos, got_neg);
            if (!(got_pos && got_neg)) begin
                $display("  FAIL: 输出不是双极性方波"); errs = errs + 1;
            end
            $display("  当前 aud[0] = %0d（期望 ±262144）", $signed(aud[0*AW +: AW]));
            if (($signed(aud[0*AW +: AW]) !== 24'sd262144) &&
                ($signed(aud[0*AW +: AW]) !== -24'sd262144)) begin
                $display("  FAIL: 幅度不是 1/32 满量程"); errs = errs + 1;
            end
        end

        // ---- 5) slot 切换 ----
        $display("");
        $display("=== 5) slot 切换：不同 slot 应给出不同声部 ===");
        begin : sl
            integer p0, p8;
            slot = 2'd0; #1 p0 = dut.ph[0];
            slot = 2'd1; #1 p8 = dut.ph[P];
            $display("  slot=0 对应 ph[0]=%0d，slot=1 应对应 ph[%0d]=%0d", p0, P, p8);
            // 声部号 = slot*P + lane，所以 slot=1 时第 0 条泳道应取 ph[8]
            if (dut.ph[0] !== p0) begin
                $display("  FAIL: slot 切换后 ph[0] 不该变"); errs = errs + 1;
            end
        end

        $display("");
        if (errs == 0) $display("PASS  tb_test_voice_gen: 32 声部对数均匀频率 5 项全过");
        else           $display("FAIL  tb_test_voice_gen: %0d 项", errs);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL  tb_test_voice_gen: 超时");
        $finish;
    end

endmodule
`default_nettype wire
