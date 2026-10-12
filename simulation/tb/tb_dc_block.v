//============================================================================
//  tb_dc_block —— 验证隔直器
//
//  ⚠ 教训：这里**绝不能**用
//        en = 1; @(posedge clk); en = 0;
//     这种阻塞赋值驱动使能 —— 它和 DUT 的采样在同一时刻竞争，
//     会导致 DUT 只在随机几拍更新（第一版 TB 就栽在这上面）。
//     所有激励和采样都必须是时钟同步的（非阻塞）。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_dc_block;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;          // 50 MHz

    reg  signed [23:0] x = 24'sd0;
    wire signed [23:0] y;

    // en 恒为 1：每个时钟一个样本（fs = 50 MHz，截止频率 39.8 kHz，远低于 fs/2）
    dc_block u_dut (.clk(clk), .rst_n(rst_n), .en(1'b1), .x(x), .y(y));

    // ---------------- 全同步激励 ----------------
    reg        mode = 1'b0;         // 0 = 直流，1 = 方波
    reg        run  = 1'b0;         // 统计窗口
    reg [31:0] cyc  = 32'd0;

    wire signed [23:0] x_dc  = 24'sd1000000;                       // 恒定直流
    wire signed [23:0] x_sq  = cyc[0] ? 24'sd1000000 : -24'sd1000000;  // fs/2 方波

    always @(posedge clk) begin
        cyc <= cyc + 32'd1;
        x   <= (mode == 1'b0) ? x_dc : x_sq;
        if (cyc == 32'd2000)  run <= 1'b1;     // 跳过瞬态
        if (cyc == 32'd300000) run <= 1'b0;
    end

    // ---------------- 全同步采样 ----------------
    reg signed [23:0] ymax = -24'sd8388608;
    reg signed [23:0] ymin =  24'sd8388607;

    always @(posedge clk) begin
        if (run) begin
            if (y > ymax) ymax <= y;
            if (y < ymin) ymin <= y;
        end
    end

    integer errs = 0;

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ---- 用例 1：恒定直流，输出应收敛到 0 ----
        mode = 1'b0; run = 1'b0; cyc = 0;
        ymax = -24'sd8388608; ymin = 24'sd8388607;
        wait (cyc == 32'd100000);
        @(posedge clk);
        $display("  [DC ] 输入恒定 1000000 -> 输出 y=%0d（期望收敛到 0）", y);
        if ((y > 2000) || (y < -2000)) begin
            $display("  FAIL: 直流没有被吃掉"); errs = errs + 1;
        end

        // ---- 用例 2：fs/2 方波 ±1000000，输出应保持约 ±1002500 ----
        mode = 1'b1; run = 1'b0; cyc = 0;
        ymax = -24'sd8388608; ymin = 24'sd8388607;
        wait (cyc == 32'd400000);
        @(posedge clk);
        $display("  [SQ ] 方波 ±1000000 -> 输出范围 [%0d, %0d]（期望约 ±1002500）", ymin, ymax);
        if ((ymax < 24'sd900000) || (ymin > -24'sd900000)) begin
            $display("  FAIL: 交流被过度衰减"); errs = errs + 1;
        end
        if ((ymax > 24'sd1100000) || (ymin < -24'sd1100000)) begin
            $display("  FAIL: 交流被放大过头"); errs = errs + 1;
        end

        if (errs == 0) $display("PASS  tb_dc_block");
        else           $display("FAIL  tb_dc_block: %0d 个错误", errs);
        $finish;
    end

endmodule
`default_nettype wire
