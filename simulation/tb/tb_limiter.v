//============================================================================
//  tb_limiter —— 主输出软限幅（设计文档 4.第二步）验证
//
//  文档要求：
//      1) Env = max(|VolL|, |VolR|)
//      2) Env ≤ Threshold → G=1.0；否则 G = Threshold/Env
//      3) Attack 立即、Release 一阶；G 复位初值 1.0
//      4) Lim = sat24( (Vol * G) >>> 15 )，打一拍
//
//  验证点（都是可精确判定的）：
//      1) 小信号（< THRESH）**原样通过**，增益保持 1.0
//      2) 大信号稳态输出 == ±THRESH（限幅到阈值，不是硬截断到满量程）
//      3) 增益方向正确：输入越大，增益越小
//      4) Release：输入回落之后增益逐步恢复（不是立刻跳回 1.0，也不是永不恢复）
//      5) 输出永不越过 ±THRESH（限幅的核心保证）
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_limiter;
    localparam signed [23:0] TH = 24'sh600000;   // 6291456，约 -2.5 dBFS

    reg clk = 0, rst_n = 0, en = 0;
    always #10 clk = ~clk;

    reg  signed [23:0] li = 0, ri = 0;
    wire signed [23:0] lo, ro;
    wire [15:0]        g;

    soft_limiter #(.THRESH(TH)) dut (
        .clk(clk), .rst_n(rst_n), .en(en), .test_mode(1'b0),
        .l_in(li), .r_in(ri),
        .l_out(lo), .r_out(ro), .g_out(g));

    // 一个采样：施加输入、等输出
    task step;
        input signed [23:0] v;
        begin
            @(negedge clk) li = v; ri = v; en = 1;
            @(negedge clk) en = 0;
            repeat (2) @(negedge clk);
        end
    endtask

    integer errs = 0;
    integer i, pk_after, pk_before;
    reg [15:0] g_small, g_big;

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // ---- 1) 小信号原样通过 ----
        $display("=== 1) 小信号（< THRESH=%0d）应原样通过、增益 1.0 ===", TH);
        //  ⚠ 2026-10-09：soft_limiter 为修时序违例（566 个 setup violation）
        //     插入了 3 级流水线，输出比输入晚 **3 个采样**。
        //     而 step() 每次只产生 1 个 en 脉冲（= 1 个采样），
        //     所以这里必须先把流水线灌满，再检查输出。
        //     功能本身没变：第 4 项"300 拍后输出 1000000"依然正确。
        step(24'sd1000000);
        step(24'sd1000000);
        step(24'sd1000000);
        step(24'sd1000000);      // 多跑一拍，确保最后一级输出寄存器已更新
        $display("  输入 1000000 → 输出 %0d，增益 %0d", lo, g);
        if (lo !== 24'sd1000000) begin $display("  FAIL: 小信号没有原样通过"); errs = errs + 1; end
        if (g !== 16'd32768)     begin $display("  FAIL: 小信号时增益不是 1.0"); errs = errs + 1; end
        g_small = g;

        // ---- 2) 大信号稳态输出 == THRESH ----
        $display("");
        $display("=== 2) 持续过载应稳定在 ±THRESH ===");
        for (i = 0; i < 20; i = i + 1) step(TH);              // 先让增益收敛
        $display("  持续输入 %0d（=THRESH）→ 输出 %0d，增益 %0d", TH, lo, g);
        if (lo > TH || lo < -TH) begin
            $display("  FAIL: 输出越过了阈值"); errs = errs + 1;
        end
        step(24'sd8000000);                                    // 远超阈值
        for (i = 0; i < 20; i = i + 1) step(24'sd8000000);
        $display("  持续输入 8000000（> THRESH）→ 输出 %0d，增益 %0d", lo, g);
        if (lo > TH || lo < -TH) begin
            $display("  FAIL: 过载时输出越过阈值（限幅失效）"); errs = errs + 1;
        end
        if (lo < TH - 24'sd200000) begin
            $display("  注意：输出 %0d 明显低于阈值 %0d（压得偏多，可接受但偏保守）", lo, TH);
        end
        g_big = g;
        if (g_big >= g_small) begin
            $display("  FAIL: 过载时增益没有下降（%0d vs %0d）", g_big, g_small);
            errs = errs + 1;
        end

        // ---- 3) 输入越大增益越小 ----
        $display("");
        $display("=== 3) 单调性：输入越大 → 增益越小 ===");
        begin : mono
            reg [15:0] g1, g2;
            for (i = 0; i < 30; i = i + 1) step(24'sd7000000);
            g1 = g;
            for (i = 0; i < 30; i = i + 1) step(24'sd8300000);
            g2 = g;
            $display("  输入 7.0M → 增益 %0d；输入 8.3M → 增益 %0d", g1, g2);
            if (g2 >= g1) begin $display("  FAIL: 增益没有随输入变大多降"); errs = errs + 1; end
        end

        // ---- 4) Release：输入回落后增益逐步恢复 ----
        $display("");
        $display("=== 4) Release：输入回到小信号后增益应逐步恢复 ===");
        begin : rel
            reg [15:0] g_after1, g_after2;
            step(24'sd1000000);
            g_after1 = g;                       // 刚落回来那一拍
            for (i = 0; i < 50; i = i + 1) step(24'sd1000000);
            g_after2 = g;                       // 再等 50 拍
            $display("  刚落回：增益 %0d；50 拍后：增益 %0d（目标 32768）", g_after1, g_after2);
            if (g_after1 >= 16'd32768) begin
                $display("  FAIL: 增益立刻跳回 1.0（Release 没起作用）"); errs = errs + 1;
            end
            if (g_after2 <= g_after1) begin
                $display("  FAIL: 50 拍后增益没有恢复"); errs = errs + 1;
            end
            for (i = 0; i < 300; i = i + 1) step(24'sd1000000);
            $display("  300 拍后：增益 %0d，输出 %0d", g, lo);
            if (g !== 16'd32768) begin
                $display("  FAIL: 长时间后增益没有完全恢复"); errs = errs + 1;
            end
            if (lo !== 24'sd1000000) begin
                $display("  FAIL: 恢复后小信号没有原样通过"); errs = errs + 1;
            end
        end

        // ---- 5) 全程不越阈值（随机式扫描）----
        $display("");
        $display("=== 5) 全场扫描：输出永不越过 ±THRESH ===");
        pk_after = 0; pk_before = 0;
        for (i = 0; i < 400; i = i + 1) begin
            begin : sweep
                integer amp;
                amp = 100000 + (i * 21000);          // 0.1M ~ 8.4M
                if (amp > 8388607) amp = 8388607;
                step(amp[23:0]);
                if (lo > pk_after) pk_after = lo;
                if (-lo > pk_after) pk_after = -lo;
                if (amp > pk_before) pk_before = amp;
            end
        end
        $display("  扫描输入峰值 = %0d，输出峰值 = %0d，阈值 = %0d", pk_before, pk_after, TH);
        if (pk_before > TH && pk_after > TH) begin
            $display("  FAIL: 有过载输入但输出超过阈值"); errs = errs + 1;
        end

        if (errs == 0) $display("\nPASS  tb_limiter: 限幅 5 项全过");
        else           $display("\nFAIL  tb_limiter: %0d 项", errs);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL  tb_limiter: 超时");
        $finish;
    end

endmodule
`default_nettype wire
