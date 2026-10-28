//  tb_reverb_aptest —— 验证"全通链输入 ap_in[0] 是否真的是 16 条梳状之和"（临时诊断）
`timescale 1ns/1ps
`default_nettype none

module tb_reverb_aptest;
    localparam integer PERIOD = 1024;
    localparam integer NS     = 1400;   // 要跑过 1215 才看得到第一个回声

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
                    // 脉冲 100000（大一点，避免 >>1 之后丢成 0）
                    bus_l <= (n == 0) ? 24'sd100000 : 24'sd0;
                    bus_r <= (n == 0) ? 24'sd100000 : 24'sd0;
                    in_vld <= 1'b1;
                    n <= n + 1;
                end
            end else cyc <= cyc + 1;
        end
    end

    // li==15 的 ST_CM（算全和那一拍）：comb_sum_n>>>1 与 ap_in[0..3] 的当前值
    integer c0, c1, c2, c3, csum;
    always @(posedge clk) begin
        if (rst_n && dut.st == 3'd4 && dut.li == 5'd15 && dut.ch == 1'b0) begin
            csum = $signed(dut.comb_sum_n) >>> 1;
            c0 = $signed(dut.ap_in[0]);
            c1 = $signed(dut.ap_in[1]);
            c2 = $signed(dut.ap_in[2]);
            c3 = $signed(dut.ap_in[3]);
            if (csum != 0 || c0 != 0 || c1 != 0 || c2 != 0 || c3 != 0)
                $display("li15: comb_sum>>>1=%0d  ap_in0=%0d ap_in1=%0d ap_in2=%0d ap_in3=%0d",
                         csum, c0, c1, c2, c3);
        end
    end

    initial begin
        repeat (8) @(posedge clk);
        rst_n = 1;
        wait (n >= NS);
        repeat (PERIOD*2) @(posedge clk);
        $finish;
    end
endmodule
`default_nettype wire
