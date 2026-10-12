//============================================================================
//  tb_fx_param —— fx_top 的参数平滑验证（文档"效果器运算 第六步"）
//
//  文档要求："参数由控制模块经寄存器写入，在控制率更新，先经第六步平滑，
//            再写成 Q1.15 供音频域使用。"
//
//  验证点：
//      1) 复位时平滑值 == 参数目标值（上电不爬坡）——否则开机 20 ms 会听到参数由 0 涨上来
//      2) 参数阶跃后，平滑值**逐采样单调逼近**，不是一步跳到位
//      3) 若干采样后**精确到达**目标值（不能永远差一点）
//      4) 下降方向同样成立
//      5) 平滑期间每采样最大变化量 == 64（STEP）
//      注：reverb_pre_delay 故意**不**平滑（可变深度延迟线，平滑会产生多普勒音高扭曲）
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_fx_param;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg  bus_vld = 0, frame_stb = 0;
    reg  signed [23:0] br_l = 0, br_r = 0, bc_l = 0, bc_r = 0, bd_l = 0, bd_r = 0;
    reg  [15:0] r_size = 16'd1000, r_decay = 16'd2000, r_damp = 16'd3000;
    reg  [15:0] r_predly = 16'd0, r_ret = 16'd5000;
    reg  [15:0] c_rate = 16'd500, c_depth = 16'd1000, c_mix = 16'd20000, c_ret = 16'd3000;
    reg  [15:0] d_time = 16'd5000, d_fb = 16'd0, d_mix = 16'd32767, d_ret = 16'd1000;
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

    integer errs = 0;
    integer i, k;
    integer prev, d, maxd, nsteps;

    // 打一个采样节拍（frame_stb），等参数斜坡有机会走一步
    task one_sample;
        begin
            @(negedge clk) frame_stb = 1;
            @(negedge clk) frame_stb = 0;
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ---- 1) 复位后平滑值 == 目标值 ----
        $display("=== 1) 复位后平滑值应等于目标值（上电不爬坡）===");
        $display("  reverb_size : 目标=%0d 平滑=%0d", r_size, dut.rv_size_s);
        $display("  chorus_mix  : 目标=%0d 平滑=%0d", c_mix,  dut.ch_mix_s);
        $display("  delay_time  : 目标=%0d 平滑=%0d", d_time, dut.dl_time_s);
        if (dut.rv_size_s !== r_size) begin $display("  FAIL: reverb_size 未同步"); errs=errs+1; end
        if (dut.ch_mix_s  !== c_mix)  begin $display("  FAIL: chorus_mix 未同步");  errs=errs+1; end
        if (dut.dl_time_s !== d_time) begin $display("  FAIL: delay_time 未同步");  errs=errs+1; end

        // ---- 2) 参数阶跃后单调逼近 ----
        $display("");
        $display("=== 2) 阶跃：chorus_mix 从 20000 改到 3000（下降）===");
        c_mix = 16'd3000;
        prev = dut.ch_mix_s;
        maxd = 0; nsteps = 0;
        for (i = 0; i < 400; i = i + 1) begin
            one_sample();
            d = prev - dut.ch_mix_s;            // 下降方向：prev > cur
            if (d > 0) begin
                if (d > maxd) maxd = d;
                nsteps = nsteps + 1;
            end
            if (d < 0) begin
                $display("  FAIL: 平滑值出现反弹（第 %0d 步）", i);
                errs = errs + 1;
                i = 400;
            end
            prev = dut.ch_mix_s;
        end
        $display("  400 个采样内：下降步数=%0d，单步最大变化=%0d（应为 64）", nsteps, maxd);
        if (maxd > 64) begin $display("  FAIL: 单步变化超过 64（不是平滑而是跳变）"); errs=errs+1; end
        if (nsteps < 10) begin $display("  FAIL: 几乎是跳变，没有斜坡"); errs = errs + 1; end
        if (nsteps > 300) begin $display("  FAIL: 400 采样还没到（收敛太慢）"); errs = errs + 1; end

        // ---- 3) 精确到达目标 ----
        $display("");
        $display("=== 3) 逼近是否精确到目标 ===");
        for (i = 0; i < 300; i = i + 1) one_sample();
        $display("  再等 300 采样后：平滑=%0d 目标=%0d", dut.ch_mix_s, c_mix);
        if (dut.ch_mix_s !== c_mix) begin
            $display("  FAIL: 平滑值没有精确到达目标（永远差一点）"); errs = errs + 1;
        end

        // ---- 4) 上升方向 ----
        $display("");
        $display("=== 4) 上升：delay_time 从 5000 改到 20000 ===");
        d_time = 16'd20000;
        prev = dut.dl_time_s;
        maxd = 0; nsteps = 0;
        for (i = 0; i < 400; i = i + 1) begin
            one_sample();
            d = dut.dl_time_s - prev;
            if (d > 0) begin
                if (d > maxd) maxd = d;
                nsteps = nsteps + 1;
            end
            if (d < 0) begin
                $display("  FAIL: 上升过程中出现下降（第 %0d 步）", i);
                errs = errs + 1;
                i = 400;
            end
            prev = dut.dl_time_s;
        end
        $display("  400 个采样内：上升步数=%0d，单步最大变化=%0d（应为 64）", nsteps, maxd);
        if (maxd > 64) begin $display("  FAIL: 单步变化超过 64"); errs = errs + 1; end
        for (i = 0; i < 400; i = i + 1) one_sample();
        $display("  收敛后：平滑=%0d 目标=%0d", dut.dl_time_s, d_time);
        if (dut.dl_time_s !== d_time) begin $display("  FAIL: 上升后未精确到达"); errs = errs + 1; end

        // ---- 5) 所有 13 个参数都要收敛 ----
        $display("");
        $display("=== 5) 12 个可平滑参数全部改一遍（预延迟故意不平滑），各等 1200 采样后应全部精确到位 ===");
        r_size=16'd30000; r_decay=16'd100; r_damp=16'd20000; r_predly=16'd480;
        r_ret=16'd12345;  c_rate=16'd60000; c_depth=16'd30000; c_mix=16'd1;
        c_ret=16'd22222;  d_time=16'd16000; d_fb=16'd30000;   d_mix=16'd7;
        d_ret=16'd9999;
        for (i = 0; i < 1300; i = i + 1) one_sample();
        begin : chkall
            if (dut.rv_size_s!==r_size)  begin $display("  FAIL rv_size");  errs=errs+1; end
            if (dut.rv_decay_s!==r_decay)begin $display("  FAIL rv_decay"); errs=errs+1; end
            if (dut.rv_damp_s!==r_damp)  begin $display("  FAIL rv_damp");  errs=errs+1; end
            // rv_predly 故意不平滑（可变深度延迟线不能平滑），这里不做检查
            if (dut.rv_ret_s!==r_ret)    begin $display("  FAIL rv_ret");   errs=errs+1; end
            if (dut.ch_rate_s!==c_rate)  begin $display("  FAIL ch_rate");  errs=errs+1; end
            if (dut.ch_depth_s!==c_depth)begin $display("  FAIL ch_depth"); errs=errs+1; end
            if (dut.ch_mix_s!==c_mix)    begin $display("  FAIL ch_mix");   errs=errs+1; end
            if (dut.ch_ret_s!==c_ret)    begin $display("  FAIL ch_ret");   errs=errs+1; end
            if (dut.dl_time_s!==d_time)  begin $display("  FAIL dl_time");  errs=errs+1; end
            if (dut.dl_fb_s!==d_fb)      begin $display("  FAIL dl_fb");    errs=errs+1; end
            if (dut.dl_mix_s!==d_mix)    begin $display("  FAIL dl_mix");   errs=errs+1; end
            if (dut.dl_ret_s!==d_ret)    begin $display("  FAIL dl_ret");   errs=errs+1; end
        end
        $display("  12 个参数检查完毕（不打印 FAIL 就是全到位）");

        if (errs == 0) $display("\nPASS  tb_fx_param: 参数平滑 5 项全过");
        else           $display("\nFAIL  tb_fx_param: %0d 项", errs);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL  tb_fx_param: 超时");
        $finish;
    end

endmodule
`default_nettype wire
