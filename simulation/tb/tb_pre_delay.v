//============================================================================
//  tb_pre_delay —— 混响预延迟线（设计文档 2.1）验证
//
//  文档要求：x_pre[n] = x[n - D_pre]，D_pre 取 10~100 ms（4800 点 @48k），纯延迟无乘法。
//  实测总延迟 = d + 1（读-写-前进 + 输出打一拍）。
//
//  验证点：
//      1) 冲激响应：延迟量精确等于 d + 1（实测值：读-写-前进 + 输出打一拍）
//      2) 多个 d 值（0 / 25 / 50 / 100 / 4799）都精确
//      3) 纯延迟：幅度不失真（无乘法）
//      4) 立体声两声道独立、不串音
//      5) 越界保护：d ≥ MAXLEN 时不出现未知态
//
//  注意：每次测量前必须复位（`do_reset`），否则上一次的冲激还留在延迟线里。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_pre_delay;
    localparam integer MAXLEN = 4800;

    reg clk = 0, rst_n = 0, en = 0;
    always #10 clk = ~clk;

    reg  signed [23:0] li = 0, ri = 0;
    reg  [15:0]        d  = 0;
    wire signed [23:0] lo, ro;

    pre_delay #(.MAXLEN(MAXLEN)) dut (
        .clk(clk), .rst_n(rst_n), .en(en),
        .l_in(li), .r_in(ri), .d(d),
        .l_out(lo), .r_out(ro));

    integer errs = 0;

    task tick;
        begin
            @(negedge clk) en = 1;
            @(negedge clk) en = 0;
        end
    endtask

    task do_reset;
        begin
            rst_n = 0; li = 0; ri = 0; en = 0;
            repeat (3) @(negedge clk);
            rst_n = 1;
            repeat (2) @(negedge clk);
        end
    endtask

    // 测一个 d 值：复位 → 打冲激 → 数多少拍后输出非零。结果放进全局变量。
    integer first_at, got_amp;

    task measure;
        input integer dly;
        input integer nrun;
        input signed [23:0] amp;
        integer k;
        begin
            do_reset();
            d  = dly[15:0];
            li = amp; ri = -amp;
            tick();                       // 写入冲激
            li = 0; ri = 0;
            first_at = -1; got_amp = 0;
            for (k = 1; k <= nrun; k = k + 1) begin
                tick();
                if ((first_at < 0) && ((lo !== 24'sd0) || (ro !== 24'sd0))) begin
                    first_at = k;
                    got_amp  = lo;
                end
            end
            li = 0; ri = 0;
        end
    endtask

    integer k, dv, expected;

    initial begin
        do_reset();

        // ---- 1) 冲激响应 ----
        $display("=== 1) 冲激响应：延迟应精确等于 d + 1 ===");
        measure(10, 40, 24'sd1000);
        expected = 11;   // d + 1
        $display("  d=10 → 首现于第 %0d 拍（期望 %0d），幅度 %0d", first_at, expected, got_amp);
        if (first_at !== expected) begin $display("  FAIL: 延迟量不对"); errs = errs + 1; end
        if (got_amp !== 24'sd1000) begin $display("  FAIL: 幅度不是纯延迟"); errs = errs + 1; end

        // ---- 2) 多个 d 值 ----
        $display("");
        $display("=== 2) 多个 d 值 ===");
        for (dv = 0; dv <= 100; dv = dv + 25) begin
            measure(dv, dv + 30, 24'sd2000);
            expected = dv + 1;
            $display("  d=%4d → 第 %0d 拍（期望 %0d）幅度 %0d %s",
                     dv, first_at, expected, got_amp,
                     (first_at === expected) ? "OK" : "**FAIL**");
            if (first_at !== expected) errs = errs + 1;
        end
        measure(MAXLEN - 1, MAXLEN + 60, 24'sd3000);
        expected = MAXLEN - 1 + 1;
        $display("  d=%4d → 第 %0d 拍（期望 %0d）%s", MAXLEN-1, first_at, expected,
                 (first_at === expected) ? "OK" : "**FAIL**");
        if (first_at !== expected) errs = errs + 1;

        // ---- 3) 立体声独立 ----
        $display("");
        $display("=== 3) 立体声独立：左打 +5000、右保持 0 ===");
        do_reset();
        d = 16'd20;
        li = 24'sd5000; ri = 24'sd0;
        tick();
        li = 0;
        begin : st
            integer kk, bad;
            bad = 0;
            for (kk = 1; kk <= 40; kk = kk + 1) begin
                tick();
                if (ro !== 24'sd0) bad = bad + 1;
            end
            $display("  40 拍内右声道非零次数 = %0d（应为 0）", bad);
            if (bad != 0) begin $display("  FAIL: 左右串音"); errs = errs + 1; end
        end

        // ---- 4) 越界保护 ----
        $display("");
        $display("=== 4) 越界保护：d = 65535（≥ MAXLEN）===");
        begin : ovf
            integer kk, badx;
            do_reset();
            d = 16'd65535;
            badx = 0;
            for (kk = 1; kk <= 60; kk = kk + 1) begin
                li = kk[23:0]; ri = -kk[23:0];
                tick();
                if ((lo === 24'sbx) || (ro === 24'sbx)) badx = badx + 1;
            end
            li = 0; ri = 0;
            $display("  60 拍内出现未知态次数 = %0d（应为 0）", badx);
            if (badx != 0) begin $display("  FAIL: 越界导致未知态"); errs = errs + 1; end
        end

        if (errs == 0) $display("\nPASS  tb_pre_delay: 预延迟 4 项全过");
        else           $display("\nFAIL  tb_pre_delay: %0d 项", errs);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL  tb_pre_delay: 超时");
        $finish;
    end

endmodule
`default_nettype wire
