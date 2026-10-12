// 测量三个效果器各自的延迟拍数（in_vld → ret_vld），供 fx_top 定"固定完成时刻"
`timescale 1ns/1ps
`default_nettype none
module tb_fx_lat;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    reg in_vld = 0;
    reg [31:0] t0r, t0c, t0d;
    wire rv, cv, dv;

    fx_reverb u_rev (.clk(clk), .rst_n(rst_n), .frame_stb(1'b0), .in_vld(in_vld),
        .bus_l(24'sd1000), .bus_r(24'sd1000),
        .p_decay(16'd30000), .p_damp(16'd9000), .p_size(16'd26000),
        .p_ret(16'd32767), .p_predly(16'd0),
        .ret_vld(rv), .ret_l(), .ret_r());
    fx_chorus u_cho (.clk(clk), .rst_n(rst_n), .frame_stb(1'b0), .in_vld(in_vld),
        .bus_l(24'sd1000), .bus_r(24'sd1000),
        .p_rate(16'd0), .p_depth(16'd0), .p_mix(16'd32767), .p_ret(16'd32767),
        .ret_vld(cv), .ret_l(), .ret_r());
    fx_delay u_del (.clk(clk), .rst_n(rst_n), .frame_stb(1'b0), .in_vld(in_vld),
        .bus_l(24'sd1000), .bus_r(24'sd1000),
        .p_time(16'd100), .p_fb(16'd0), .p_mix(16'd32767), .p_ret(16'd32767),
        .ret_vld(dv), .ret_l(), .ret_r());

    integer got_r=0, got_c=0, got_d=0;
    always @(posedge clk) begin
        if (rv && !got_r) begin got_r=1; $display("  混响 ret_vld 延迟 = %0d 拍", cyc - t0r); end
        if (cv && !got_c) begin got_c=1; $display("  合唱 ret_vld 延迟 = %0d 拍", cyc - t0c); end
        if (dv && !got_d) begin got_d=1; $display("  延迟 ret_vld 延迟 = %0d 拍", cyc - t0d); end
    end

    initial begin
        repeat (4) @(posedge clk); rst_n = 1;
        repeat (4) @(posedge clk);
        t0r = cyc; t0c = cyc; t0d = cyc;
        in_vld = 1; @(posedge clk); in_vld = 0;
        #20000;
        if (!got_r) $display("  混响：没等到 ret_vld");
        if (!got_c) $display("  合唱：没等到 ret_vld");
        if (!got_d) $display("  延迟：没等到 ret_vld");
        $finish;
    end
endmodule
`default_nettype wire
