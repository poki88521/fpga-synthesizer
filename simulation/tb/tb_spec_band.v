//  tb_spec_band —— 32 频带频谱验收（交接文档第 4 步）
//
//  判据（交接文档原文）：
//    · 1 kHz 输入：最高柱应落在 band 14~18
//    · band 0~5 **不应饱和**（v3 就是在这里错的：1 kHz 时 23 根柱 > 25 px）
//  追加判据（本版）：
//    · C4 261.6 Hz：最高柱落在 band 6~11
//    · 满刻度 60 Hz：点亮 band 0~3
//    · 静音：原始柱高 pxraw 必须为 0（验证窗口切换时状态清零 ——
//      Goertzel 极点无阻尼，不清零的话声音停了柱子永远卡在满格）
//    · 峰值柱高应 ≈ Python 黄金参考（1 kHz/amp20000 时 band16 ≈ 79~80 px）
//
//  期望值来自 scratch/spec/spec_fixed.py（浮点 80 px / 定点 79 px）
`timescale 1ns/1ps
module tb_spec_band;
    reg clk = 0, rst_n = 0, stb = 0;
    reg signed [15:0] aud = 0;
    wire [255:0] bars;
    wire bars_vld, bars_tgl;
    always #10.17 clk = ~clk;          // 49.152 MHz

    spec_band #(.NB(32), .AW(16)) dut (
        .clk(clk), .rst_n(rst_n), .sample_stb(stb),
        .aud_in(aud), .bars(bars), .bars_vld(bars_vld), .bars_tgl(bars_tgl)
    );

    integer n, k, w, best_i, best_h, fails;
    integer sil_nz;            // 静音窗口内 pxraw != 0 的次数
    reg     sil_cnt_en;
    real ph, pi;

    //  一个窗口 = 1024 个采样 + 1 个测量槽
    task run_window;
        input real fr;
        input real am;
        begin
            for (n = 0; n < 1024; n = n + 1) begin
                ph = ph + 2.0*pi*fr/48000.0;
                if (ph > 2.0*pi) ph = ph - 2.0*pi;
                aud = $rtoi(am*$sin(ph));
                stb = 1'b1; @(posedge clk); stb = 1'b0;
                repeat (1023) @(posedge clk);
            end
        end
    endtask

    function [7:0] bar;
        input integer i;
        begin
            bar = bars[i*8 +: 8];
        end
    endfunction

    task report;
        input [255:0] name;
        begin
            best_i = 0; best_h = 0;
            for (k = 0; k < 32; k = k + 1) begin
                if (bar(k) > best_h) begin
                    best_h = bar(k);
                    best_i = k;
                end
            end
            $display("  %0s", name);
            $write("    px: ");
            for (k = 0; k < 32; k = k + 1) $write("%3d", bar(k));
            $write("\n");
            $display("    峰值 band %0d  高 %0d px", best_i, best_h);
        end
    endtask

    //  静音窗口里监视原始柱高（未平滑）
    always @(posedge clk) begin
        if (sil_cnt_en && dut.st == 3'd4 && dut.mst == 4'd13 && dut.px_r != 8'd0)
            sil_nz = sil_nz + 1;
    end

    initial begin
        pi = 3.14159265358979; ph = 0.0; fails = 0;
        sil_cnt_en = 0; sil_nz = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;

        $display("");
        $display("========================================================");
        $display(" spec_band 验收（N=1024, fs=48k, 49.152 MHz）");
        $display("========================================================");

        //------------------------------------------------------------------
        //  用例 1：1 kHz 单音
        //------------------------------------------------------------------
        for (w = 0; w < 3; w = w + 1) run_window(1000.0, 20000.0);
        report("1 kHz 单音 amp20000");
        if (best_i < 14 || best_i > 18) begin
            $display("    FAIL: 峰值应在 band 14~18");
            fails = fails + 1;
        end else $display("    OK: 峰值落在 band 14~18");
        for (k = 0; k < 6; k = k + 1) begin
            if (bar(k) > 50) begin
                $display("    FAIL: band %0d = %0d 饱和（v3 的老毛病）", k, bar(k));
                fails = fails + 1;
            end
        end
        if (bar(0) <= 50 && bar(5) <= 50) $display("    OK: band 0~5 未饱和（<=50）");
        if (best_h < 70 || best_h > 95) begin
            $display("    FAIL: 峰值 %0d px 偏离黄金参考 79~80 px", best_h);
            fails = fails + 1;
        end else $display("    OK: 峰值 %0d px，与 Python 黄金参考 79~80 px 一致", best_h);

        //------------------------------------------------------------------
        //  用例 2：C4 261.6 Hz
        //------------------------------------------------------------------
        for (w = 0; w < 2; w = w + 1) run_window(261.63, 20000.0);
        report("C4 261.6 Hz 单音 amp20000");
        if (best_i < 6 || best_i > 11) begin
            $display("    FAIL: 峰值应在 band 6~11");
            fails = fails + 1;
        end else $display("    OK: 峰值落在 band 6~11");

        //------------------------------------------------------------------
        //  用例 3：静音（窗口切换必须清零状态，否则柱子永远卡住）
        //------------------------------------------------------------------
        for (w = 0; w < 5; w = w + 1) run_window(1000.0, 0.0);
        sil_nz = 0; sil_cnt_en = 1;
        run_window(1000.0, 0.0);
        sil_cnt_en = 0;
        report("静音（6 窗口后）");
        if (sil_nz != 0) begin
            $display("    FAIL: 静音下仍有 %0d 次原始柱高非 0（状态没清零）", sil_nz);
            fails = fails + 1;
        end else $display("    OK: 静音下 32 个频带原始柱高全为 0（状态已清零）");
        if (best_h > 60) begin
            $display("    FAIL: 平滑后残留 %0d px（应在释放中）", best_h);
            fails = fails + 1;
        end else $display("    OK: 平滑后已衰减到 %0d px（释放时间常数约 8 窗口 ≈170 ms）", best_h);

        //------------------------------------------------------------------
        //  用例 4：满刻度 60 Hz（测状态位宽余量，不允许乱跳）
        //------------------------------------------------------------------
        for (w = 0; w < 2; w = w + 1) run_window(60.0, 32767.0);
        report("满刻度 60 Hz amp32767");
        if (best_i > 3) begin
            $display("    FAIL: 60 Hz 应点亮 band 0~3");
            fails = fails + 1;
        end else $display("    OK: 低频端正确点亮");

        $display("========================================================");
        if (fails == 0) $display(" 全部通过");
        else            $display(" 失败 %0d 项", fails);
        $display("========================================================");
        $finish;
    end

    //  看门狗
    initial begin
        #800000000;
        $display("!! WATCHDOG 超时");
        $finish;
    end
endmodule
