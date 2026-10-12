//============================================================================
//  tb_fx_bypass —— 旁路组合验证（用 -P 覆盖本 TB 的参数）
//
//  跑法：
//      iverilog -g2012 -DSIMULATION -s tb_fx_bypass ... ;
//      vvp sim/out/tb_fx_bypass.vvp                      # 全开
//      vvp sim/out/tb_fx_bypass.vvp -Ptb_fx_bypass.REV_EN=0   # 旁路混响
//      ... CHO_EN=0 / DEL_EN=0 / 三个都 0
//
//  验证点：
//      1) 任何旁路组合下，fx_vld 次数 == bus_vld 次数（握手不丢样）
//      2) 三个全旁路时输出恒 0
//      3) 有启用效果时输出不恒 0
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_fx_bypass #(
    parameter integer REV_EN = 1,
    parameter integer CHO_EN = 1,
    parameter integer DEL_EN = 1
);
    localparam integer NS = 1800;   // 要超过混响最长延迟线 1760，三个效果才有输出

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg  bus_vld = 0;
    reg  signed [23:0] br_l, br_r, bc_l, bc_r, bd_l, bd_r;
    reg  [15:0] r_size, r_decay, r_damp, r_predly, r_ret;
    reg  [15:0] c_rate, c_depth, c_mix, c_ret;
    reg  [15:0] d_time, d_fb, d_mix, d_ret;

    wire        fx_vld;
    wire signed [23:0] fx_l, fx_r;

    fx_top #(.REV_EN(REV_EN), .CHO_EN(CHO_EN), .DEL_EN(DEL_EN)) dut (
        .clk(clk), .rst_n(rst_n), .frame_stb(1'b0), .test_mode(1'b0), .bus_vld(bus_vld),
        .bus_rev_l(br_l), .bus_rev_r(br_r), .bus_cho_l(bc_l), .bus_cho_r(bc_r),
        .bus_del_l(bd_l), .bus_del_r(bd_r),
        .reverb_size(r_size), .reverb_decay(r_decay), .reverb_damping(r_damp),
        .reverb_pre_delay(r_predly), .reverb_return(r_ret),
        .chorus_rate(c_rate), .chorus_depth(c_depth), .chorus_mix(c_mix), .chorus_return(c_ret),
        .delay_time(d_time), .delay_feedback(d_fb), .delay_mix(d_mix), .delay_return(d_ret),
        .fx_vld(fx_vld), .fx_l(fx_l), .fx_r(fx_r));

    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    integer n_in = 0, n_out = 0, nz = 0, peak = 0;

    always @(posedge clk) begin
        if (bus_vld) n_in = n_in + 1;
        if (fx_vld) begin
            n_out = n_out + 1;
            if (fx_l != 0 || fx_r != 0) nz = nz + 1;
            if (fx_l > peak) peak = fx_l;
            if (-fx_l > peak) peak = -fx_l;
        end
    end

    task drive_one;
        input integer v;
        begin
            @(negedge clk);
            bus_vld = 1; br_l = v; br_r = v; bc_l = v; bc_r = v; bd_l = v; bd_r = v;
            @(negedge clk);
            bus_vld = 0;
            repeat (200) @(negedge clk);   // > 固定延迟 130，一进一出不排队
        end
    endtask

    integer i, errs = 0;

    initial begin
        r_size = 16'd26000; r_decay = 16'd30000; r_damp = 16'd9000;
        r_predly = 16'd0;   r_ret   = 16'd32767;
        c_rate = 16'd0;     c_depth = 16'd0;     c_mix = 16'd32767; c_ret = 16'd32767;
        d_time = 16'd20;    d_fb    = 16'd0;     d_mix = 16'd32767; d_ret = 16'd32767;
        br_l = 0; br_r = 0; bc_l = 0; bc_r = 0; bd_l = 0; bd_r = 0;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        for (i = 0; i < NS; i = i + 1) drive_one(1000 + i);
        repeat (400) @(posedge clk);

        $display("=== REV_EN=%0d CHO_EN=%0d DEL_EN=%0d ===", REV_EN, CHO_EN, DEL_EN);
        $display("  bus_vld=%0d  fx_vld=%0d  %s", n_in, n_out,
                 (n_out == n_in) ? "一一对应 OK" : "不匹配！");
        if (n_out != n_in) begin
            $display("  FAIL: 输出次数与输入不一致（旁路导致丢样）");
            errs = errs + 1;
        end
        $display("  非零输出 = %0d / %0d，峰值 = %0d", nz, n_out, peak);
        if (REV_EN == 0 && CHO_EN == 0 && DEL_EN == 0) begin
            if (peak != 0) begin $display("  FAIL: 全旁路时输出应为 0"); errs = errs + 1; end
            else $display("  全旁路：输出恒 0 ✓");
        end else begin
            if (nz == 0) begin $display("  FAIL: 有启用效果但输出恒 0"); errs = errs + 1; end
        end

        if (errs == 0) $display("PASS  tb_fx_bypass");
        else           $display("FAIL  tb_fx_bypass: %0d 项", errs);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL  tb_fx_bypass: 超时");
        $finish;
    end

endmodule
`default_nettype wire
