//  tb_spec_dbg —— 在 mst==11 那一刻把测量链完整转储，对着 Python 定点模型核对
//  场景：满刻度 60 Hz 正弦（专门查低频带 mag² 的三重积精度）
`timescale 1ns/1ps
module tb_spec_dbg;
    reg clk = 0, rst_n = 0, stb = 0;
    reg signed [15:0] aud = 0;
    wire [255:0] bars;
    wire bars_vld, bars_tgl;
    always #10.17 clk = ~clk;

    spec_band dut (
        .clk(clk), .rst_n(rst_n), .sample_stb(stb),
        .aud_in(aud), .bars(bars), .bars_vld(bars_vld), .bars_tgl(bars_tgl)
    );

    integer n;
    real ph, pi;
    localparam integer BAND = 0;
    localparam real FREQ = 60.0;
    localparam real AMP  = 32767.0;
    reg done = 0;

    initial begin
        #60000000;
        $display("!! WATCHDOG : st=%0d wcnt=%0d bcnt=%0d mbnd=%0d mst=%0d",
                 dut.st, dut.wcnt, dut.bcnt, dut.mbnd, dut.mst);
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n && !done && dut.st == 3'd4 && dut.mbnd == BAND && dut.mst == 4'd13) begin
            done = 1;
            $display("");
            $display("=== band %0d (%0.1f Hz, amp %0.0f) 测量链 ===", BAND, FREQ, AMP);
            $display("  ry1_00 = %0d", $signed(dut.ry1_00));
            $display("  ry2_00 = %0d", $signed(dut.ry2_00));
            $display("  msb_v=%0d  e_r=%0d  e_sh=%0d", dut.msb_v, dut.e_r, dut.e_sh);
            $display("  ys1=%0d  ys2=%0d", $signed(dut.ys1), $signed(dut.ys2));
            $display("  c_r=%0d  p12=%0d", $signed(dut.c_r), $signed(dut.p12));
            $display("  mult=%0d  p3_w=%0d", $signed(dut.mult), $signed(dut.p3_w));
            $display("  p1=%0d  p2=%0d  mag2=%0d", $signed(dut.p1), $signed(dut.p2), $signed(dut.mag2));
            $display("  pm=%0d  mant=%0d  lg_w=%0d", dut.pm, dut.mant, dut.lg_w);
            $display("  e192=%0d  e42=%0d  REF_Q5=%0d", $signed(dut.e192), $signed(dut.e42), $signed(dut.REF_Q5));
            $display("  lev_r=%0d  tt_r=%0d  tt25_r=%0d  px_r=%0d",
                     $signed(dut.lev_r), $signed(dut.tt_r), $signed(dut.tt25_r), dut.px_r);
            $finish;
        end
    end

    initial begin
        pi = 3.14159265358979; ph = 0.0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        for (n = 0; n < 1024 + 4; n = n + 1) begin
            ph = ph + 2.0*pi*FREQ/48000.0;
            if (ph > 2.0*pi) ph = ph - 2.0*pi;
            aud = $rtoi(AMP*$sin(ph));
            stb = 1'b1; @(posedge clk); stb = 1'b0;
            repeat (1023) @(posedge clk);
        end
        $display("!! 没抓到测量时刻");
        $finish;
    end
endmodule
