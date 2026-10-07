//============================================================================
//  tb_timbre_map —— 音色映射单元测试
//
//  覆盖（documents/硬件实现.md §三.五）：
//    ① 打一拍输出：req 之后 1 拍 vld 与 timbre_slot 同时有效
//    ② 本期恒等映射 timbre_slot = program[2:0]
//    ③ 连续查询可流水（每拍一次）
//    ④ 复位后 vld = 0
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_timbre_map;
    reg clk = 0;
    always #10 clk = ~clk;

    reg        rst_n = 0;
    reg        req = 0;
    reg [6:0]  bank_msb = 0;
    reg [6:0]  prog_num = 0;
    wire [2:0] timbre_slot;
    wire       vld;

    timbre_map dut (
        .clk(clk), .rst_n_sync(rst_n),
        .req(req), .bank_msb(bank_msb), .prog_num(prog_num),
        .timbre_slot(timbre_slot), .vld(vld)
    );

    integer errors = 0;

    // 监视器：捕获每次 vld 时的 timbre_slot（流水测试用；不要在几拍之后才去等单拍脉冲）
    reg [2:0] cap_slot [0:7];
    integer   cap_n = 0;
    always @(posedge clk) begin
        if (vld && cap_n < 8) begin
            cap_slot[cap_n] <= timbre_slot;
            cap_n           <= cap_n + 1;
        end
    end

    task chk(input cond, input [255:0] name);
        begin
            if (!cond) begin errors = errors + 1; $display("FAIL  %0s", name); end
            else $display("  ok  %0s", name);
        end
    endtask

    // 发一次查询，等返回并检查
    task query(input [6:0] prog, input [2:0] exp, input [255:0] name);
        integer g;
        begin
            @(negedge clk);
            prog_num = prog; req = 1'b1;
            @(negedge clk);
            req = 1'b0;
            // 应在下一拍出现 vld
            g = 0;
            while (!vld && g < 5) begin @(posedge clk); g = g + 1; end
            if (!vld) begin
                errors = errors + 1;
                $display("FAIL  %0s : no vld", name);
            end else if (timbre_slot !== exp) begin
                errors = errors + 1;
                $display("FAIL  %0s : slot=%0d exp=%0d", name, timbre_slot, exp);
            end else begin
                $display("  ok  %0s : prog=%0d -> slot=%0d", name, prog, timbre_slot);
            end
            repeat (3) @(posedge clk);
        end
    endtask

    integer i;
    initial begin
        $dumpfile("tb_timbre_map.vcd");
        $dumpvars(0, tb_timbre_map);

        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (5) @(posedge clk);

        $display("== 1. reset ==");
        chk(vld == 1'b0, "vld = 0 after reset");

        $display("== 2. identity mapping ==");
        query(7'd0,   3'd0, "program 0");
        query(7'd5,   3'd5, "program 5");
        query(7'd7,   3'd7, "program 7");
        query(7'd8,   3'd0, "program 8  -> 0 (program[2:0])");
        query(7'd15,  3'd7, "program 15 -> 7");
        query(7'd127, 3'd7, "program 127-> 7");

        $display("== 3. pipelined queries (one per cycle) ==");
        // 连续 4 拍各查一次；结果滞后 1 拍，用监视器收集（不能事后去等）
        cap_n = 0;
        @(negedge clk); prog_num = 7'd1; req = 1'b1;
        @(negedge clk); prog_num = 7'd2; req = 1'b1;
        @(negedge clk); prog_num = 7'd3; req = 1'b1;
        @(negedge clk); prog_num = 7'd4; req = 1'b1;
        @(negedge clk); req = 1'b0;
        repeat (8) @(posedge clk);
        chk(cap_n == 4, "pipeline : exactly 4 results");
        $display("       got cap_n=%0d slots=%0d,%0d,%0d,%0d", cap_n,
                 cap_slot[0], cap_slot[1], cap_slot[2], cap_slot[3]);
        chk(cap_slot[0] == 3'd1 && cap_slot[1] == 3'd2 &&
            cap_slot[2] == 3'd3 && cap_slot[3] == 3'd4, "pipeline : slots 1,2,3,4 in order");

        if (errors == 0) $display("PASS  tb_timbre_map");
        else             $display("FAIL  tb_timbre_map : %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
