//============================================================================
//  tb_fx_frame —— fx_top 的 frame_stb 不再中断处理（2026-10-06 修复的行为验证）
//
//  背景：原来 frame_stb（采样边界）会清 busy/cnt/pend/done。它若落在一次处理的
//  **中途**，那一次的 fx_vld 就永远不发 → 下游 main_mix 卡死。
//
//  验证：每个 bus_vld 恰好换来一次 fx_vld（frame_stb 打在中途也不丢、不重复）。
//  写法刻意最朴素（initial + # 延时 + task），避免工具链语法坑。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_fx_frame;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg  bus_vld = 0, frame_stb = 0;
    reg  signed [23:0] br_l = 0, br_r = 0, bc_l = 0, bc_r = 0, bd_l = 0, bd_r = 0;
    reg  [15:0] r_size = 16'd26000, r_decay = 16'd30000, r_damp = 16'd9000;
    reg  [15:0] r_predly = 16'd0, r_ret = 16'd32767;
    reg  [15:0] c_rate = 16'd0, c_depth = 16'd0, c_mix = 16'd32767, c_ret = 16'd32767;
    reg  [15:0] d_time = 16'd200, d_fb = 16'd0, d_mix = 16'd32767, d_ret = 16'd32767;
    wire        fx_vld;
    wire signed [23:0] fx_l, fx_r;

    fx_top dut (
        .clk(clk), .rst_n(rst_n), .frame_stb(frame_stb), .test_mode(1'b0), .bus_vld(bus_vld),
        .bus_rev_l(br_l), .bus_rev_r(br_r),
        .bus_cho_l(bc_l), .bus_cho_r(bc_r),
        .bus_del_l(bd_l), .bus_del_r(bd_r),
        .reverb_size(r_size), .reverb_decay(r_decay), .reverb_damping(r_damp),
        .reverb_pre_delay(r_predly), .reverb_return(r_ret),
        .chorus_rate(c_rate), .chorus_depth(c_depth), .chorus_mix(c_mix), .chorus_return(c_ret),
        .delay_time(d_time), .delay_feedback(d_fb), .delay_mix(d_mix), .delay_return(d_ret),
        .fx_vld(fx_vld), .fx_l(fx_l), .fx_r(fx_r));

    integer n_in = 0, n_out = 0;
    always @(posedge clk) begin
        if (bus_vld) n_in = n_in + 1;
        if (fx_vld)  n_out = n_out + 1;
    end

    integer errs = 0;
    integer exp1, exp2, exp3, exp4;

    task do_bus;
        begin
            @(negedge clk) bus_vld = 1;
            br_l = 24'sd1000; bc_l = 24'sd1000; bd_l = 24'sd1000;
            @(negedge clk) bus_vld = 0;
        end
    endtask

    task do_frame;
        input integer np;
        begin
            repeat (np) @(negedge clk);
            @(negedge clk) frame_stb = 1;
            @(negedge clk) frame_stb = 0;
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // ---- 1) 基线：三次 bus_vld，间隔 2000ns ----
        $display("=== 1) 基线（不打 frame_stb）===");
        do_bus(); #2000;
        do_bus(); #2000;
        do_bus(); #30000;
        $display("  bus_vld=%0d  fx_vld=%0d", n_in, n_out);
        if (n_out != 3) begin $display("  FAIL: 基线输出数不对"); errs = errs + 1; end

        // ---- 2) frame_stb 打在中途 ----
        $display("");
        $display("=== 2) frame_stb 打在中途 ===");

        exp1 = n_out + 1;
        fork do_bus(); do_frame(5); join
        #30000;
        $display("  bus 后 5 拍：fx_vld 累计 %0d（期望 %0d）", n_out, exp1);
        if (n_out != exp1) begin $display("  FAIL: 丢了"); errs = errs + 1; end

        exp2 = n_out + 1;
        fork do_bus(); do_frame(60); join
        #30000;
        $display("  bus 后 60 拍：fx_vld 累计 %0d（期望 %0d）", n_out, exp2);
        if (n_out != exp2) begin $display("  FAIL: 丢了"); errs = errs + 1; end

        exp3 = n_out + 1;
        fork do_bus(); do_frame(100); join
        #30000;
        $display("  bus 后 100 拍：fx_vld 累计 %0d（期望 %0d）", n_out, exp3);
        if (n_out != exp3) begin $display("  FAIL: 丢了"); errs = errs + 1; end

        // ---- 3) 连续 frame_stb ----
        exp4 = n_out + 1;
        fork
            do_bus();
            begin
                repeat (30) @(negedge clk);
                do_frame(0); do_frame(10); do_frame(10);
            end
        join
        #30000;
        $display("");
        $display("=== 3) 连续 frame_stb：fx_vld 累计 %0d（期望 %0d）===", n_out, exp4);
        if (n_out != exp4) begin $display("  FAIL: 丢失或重复"); errs = errs + 1; end

        $display("");
        $display("=== 4) 总计 ===");
        $display("  bus_vld=%0d  fx_vld=%0d", n_in, n_out);
        if (n_out != n_in) begin $display("  FAIL: 总数不匹配"); errs = errs + 1; end

        if (errs == 0) $display("\nPASS  tb_fx_frame: frame_stb 不再中断处理");
        else           $display("\nFAIL  tb_fx_frame: %0d 项", errs);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("FAIL  tb_fx_frame: 超时  n_in=%0d n_out=%0d", n_in, n_out);
        $finish;
    end

endmodule
`default_nettype wire
