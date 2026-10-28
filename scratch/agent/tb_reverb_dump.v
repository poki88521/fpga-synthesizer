//  tb_reverb_dump —— 单脉冲激励，逐样本 dump 混响内部（临时诊断）
//  目的：验证延迟线"读/写地址"语义（回声间隔是否等于 len）与反馈系数。
`timescale 1ns/1ps
`default_nettype none

module tb_reverb_dump;
    localparam integer PERIOD = 1024;
    localparam integer NS     = 3000;

    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_n = 0;
    reg in_vld = 0;
    reg signed [23:0] bus_l = 0, bus_r = 0;
    wire ret_vld;
    wire signed [23:0] ret_l, ret_r;

    fx_reverb #(.AW(24), .SBW(12), .SLOT(4096)) dut (
        .clk(clk), .rst_n(rst_n), .frame_stb(1'b0),
        .in_vld(in_vld), .bus_l(bus_l), .bus_r(bus_r),
        .p_decay(16'd31000), .p_damp(16'd24576),
        .p_size(16'd26000), .p_ret(16'd26000), .p_predly(16'd0),
        .ret_vld(ret_vld), .ret_l(ret_l), .ret_r(ret_r)
    );

    integer cyc = 0, n = 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cyc <= 0; n <= 0; in_vld <= 0; bus_l <= 0; bus_r <= 0; end
        else begin
            in_vld <= 1'b0;
            if (cyc == PERIOD-1) begin
                cyc <= 0;
                if (n < NS) begin
                    bus_l <= (n == 0) ? 24'sd1000 : 24'sd0;
                    bus_r <= (n == 0) ? 24'sd1000 : 24'sd0;
                    in_vld <= 1'b1;
                    n <= n + 1;
                end
            end else cyc <= cyc + 1;
        end
    end

    integer fd;
    integer fnum = 0;
    reg signed [23:0] m0_l0 = 0;
    reg signed [23:0] wd_l0 = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.st == 3'd3 && dut.li == 5'd0 && dut.ch == 1'b0) m0_l0 = dut.m0;
            if (dut.st == 3'd4 && dut.li == 5'd0 && dut.ch == 1'b0) wd_l0 = dut.wdata;
            if (ret_vld) begin
                $display("D %0d %0d %0d %0d %0d", fnum, $signed(m0_l0), $signed(wd_l0), $signed(ret_l), $signed(ret_r));
                fnum = fnum + 1;
            end
        end
    end

    initial begin
        fd = $fopen("D:/code/fpga-synthesizer/develop/scratch/agent/probe_reverb_m0.txt", "w");
        repeat (8) @(posedge clk);
        rst_n = 1;
        wait (n >= NS);
        repeat (PERIOD*3) @(posedge clk);
        $display("frames=%0d", fnum);
        $fclose(fd);
        $finish;
    end
endmodule
`default_nettype wire
