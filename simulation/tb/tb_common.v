//============================================================================
//  tb_common —— reset_sync + sat24 的单元测试
//
//  reset_sync：异步断言立即生效、同步释放恰好延 2 拍
//  sat24     ：与 documents/硬件实现.md §四.2（1）的规格公式逐条对照（含饱和边界）
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_common;

    integer errors = 0;

    //========================= reset_sync =========================
    reg  clk = 0;
    always #10 clk = ~clk;               // 50 MHz，只为仿真方便

    reg  rst_async_n;
    wire rst_n_sync;

    reset_sync u_rst (
        .clk         (clk),
        .rst_async_n (rst_async_n),
        .rst_n_sync  (rst_n_sync)
    );

    integer release_cycle;
    integer cyc;

    task check_reset_sync;
        begin
            // --- 异步断言 ---
            rst_async_n  = 1'b1;
            repeat (4) @(posedge clk);
            if (rst_n_sync !== 1'b1) begin
                $display("FAIL reset_sync: 未复位时应为 1，实为 %b", rst_n_sync);
                errors = errors + 1;
            end

            // 在时钟沿之间（异步）拉低复位
            @(negedge clk);
            rst_async_n = 1'b0;
            #1;
            if (rst_n_sync !== 1'b0) begin
                $display("FAIL reset_sync: 断言未立即生效（异步断言），实为 %b", rst_n_sync);
                errors = errors + 1;
            end

            // --- 同步释放 ---
            @(negedge clk);
            rst_async_n = 1'b1;
            // 释放后第 1 个上升沿起数：应为 2 拍后拉高
            cyc = 0;
            release_cycle = -1;
            while (cyc < 6) begin
                @(posedge clk);
                #1;
                cyc = cyc + 1;
                if (rst_n_sync === 1'b1 && release_cycle < 0)
                    release_cycle = cyc;
            end
            if (release_cycle != 2) begin
                $display("FAIL reset_sync: 同步释放应在第 2 拍，实为第 %0d 拍", release_cycle);
                errors = errors + 1;
            end else
                $display("PASS reset_sync: 异步断言立即生效，同步释放在第 2 拍");
        end
    endtask

    //========================= sat24 =========================
    reg  signed [47:0] acc;
    wire signed [23:0] y;

    sat24 #(.ACCW(48), .OUTW(24), .SHIFT(15)) u_sat (
        .acc (acc),
        .y   (y)
    );

    // 规格参考模型（照 §四.2（1）的 5 步逐条写）
    function signed [23:0] ref_sat24;
        input signed [47:0] a;
        reg   signed [47:0] a_rnd, sh;
        reg          [28:0] v;
        reg                 ovf;
        begin
            a_rnd = a + 48'sd16384;
            sh    = a_rnd >>> 15;
            v     = sh[28:0];
            ovf   = (v[28:24] != {5{v[23]}});
            if (ovf) ref_sat24 = v[28] ? 24'sh800000 : 24'sh7FFFFF;
            else     ref_sat24 = v[23:0];
        end
    endfunction

    integer i;
    reg signed [47:0] a;
    reg signed [23:0] exp;

    task check_one;
        input signed [47:0] a_in;
        begin
            acc = a_in;
            #1;
            exp = ref_sat24(a_in);
            if (y !== exp) begin
                $display("FAIL sat24: acc=%0d 期望 %0d 实为 %0d", a_in, exp, y);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        rst_async_n = 1'b0;

        //---------- reset_sync ----------
        check_reset_sync();

        //---------- sat24 边界与随机 ----------
        // 0 → 0
        check_one(48'sd0);
        // 满量程正：Q1.23 的 1.0 = 2^23 = 8388608，对应 acc = 8388608 <<< 15
        check_one(48'sd8388608 <<< 15);
        // 略小于 1.0（Q1.23 最大值 8388607）
        check_one((48'sd8388607) <<< 15);
        // 正溢出：2.0
        check_one(48'sd16777216 <<< 15);
        // 负饱和：-1.0 = -8388608
        check_one(-(48'sd8388608) <<< 15);
        // 负溢出
        check_one(-(48'sd16777216) <<< 15);
        // 极小值（四舍五入含奇数）
        check_one(48'sd1);
        check_one(-48'sd1);

        // 随机 20000 组
        for (i = 0; i < 20000; i = i + 1) begin
            a = {$random, $random} % 48'sd140737488355328;   // 48 位范围
            check_one(a);
        end

        if (errors == 0) $display("PASS  tb_common （reset_sync + sat24，含 20000 组随机对比）");
        else             $display("FAIL  tb_common: %0d 处不符", errors);
        $finish;
    end

endmodule

`default_nettype wire
