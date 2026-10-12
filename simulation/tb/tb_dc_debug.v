`timescale 1ns/1ps
`default_nettype none
module tb_dc_debug;
    reg clk = 0, rst_n = 0;
    reg signed [23:0] x;
    wire signed [23:0] y;
    always #10 clk = ~clk;

    dc_block u (.clk(clk), .rst_n(rst_n), .en(1'b1), .x(x), .y(y));

    integer n;
    initial begin
        $dumpfile("out/dc.vcd"); $dumpvars(0, tb_dc_debug);
        x = 0;
        repeat(3) @(posedge clk);
        rst_n = 1; @(posedge clk);

        $display(" n |        x    |      x_d    |     diff   |    diff_s     |      prod     |      acc      |      y");
        for (n = 1; n <= 12; n = n + 1) begin
            x = (n[0]) ? 24'sd1000000 : -24'sd1000000;
            @(posedge clk); #1;
            $display("%2d | %11d | %11d | %10d | %13d | %13d | %13d | %10d",
                     n, $signed(x), $signed(u.x_d), $signed(u.diff),
                     $signed(u.diff_s), $signed(u.prod), $signed(u.acc), $signed(y));
        end
        $finish;
    end
endmodule
`default_nettype wire
