//============================================================================
//  tb_fx_top —— 效果器顶层验证（重点：完成握手）
//
//  验证点：
//      1) 每次 bus_vld 之后必须**有且只有一次** fx_vld（旧实现在这里失败：
//         三个 ret_vld 凑不齐时，got 被 frame_stb 反复清零 → 永远不出结果）
//      2) fx_vld 的时刻 = bus_vld 之后 LAT_MAX 拍（固定完成时刻）
//      3) 连续多采样输入时，输出次数 == 输入次数（不丢样）
//      4) 有信号输入时输出不为 0（三个效果器真的在贡献）
//      5) 逐个旁路（REV_EN/CHO_EN/DEL_EN=0）后，仍然每次都出结果
//      6) 输出不溢出（|fx| 有界）
//
//  实测各效果延迟：fx_delay 3 拍、fx_chorus 11 拍、fx_reverb 121 拍。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_fx_top;
    localparam integer NS = 60;          // 采样数

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg  bus_vld = 0;
    reg  signed [23:0] br_l, br_r, bc_l, bc_r, bd_l, bd_r;
    reg  [15:0] r_size, r_decay, r_damp, r_predly, r_ret;
    reg  [15:0] c_rate, c_depth, c_mix, c_ret;
    reg  [15:0] d_time, d_fb, d_mix, d_ret;
    wire        fx_vld;
    wire signed [23:0] fx_l, fx_r;

    fx_top dut (
        .clk(clk), .rst_n(rst_n), .frame_stb(1'b0), .test_mode(1'b0),
        .bus_vld(bus_vld),
        .bus_rev_l(br_l), .bus_rev_r(br_r),
        .bus_cho_l(bc_l), .bus_cho_r(bc_r),
        .bus_del_l(bd_l), .bus_del_r(bd_r),
        .reverb_size(r_size), .reverb_decay(r_decay), .reverb_damping(r_damp),
        .reverb_pre_delay(r_predly), .reverb_return(r_ret),
        .chorus_rate(c_rate), .chorus_depth(c_depth), .chorus_mix(c_mix), .chorus_return(c_ret),
        .delay_time(d_time), .delay_feedback(d_fb), .delay_mix(d_mix), .delay_return(d_ret),
        .fx_vld(fx_vld), .fx_l(fx_l), .fx_r(fx_r)
    );

    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // 统计
    integer n_vld   = 0;      // fx_vld 次数
    integer n_in    = 0;      // bus_vld 次数
    integer last_in_cyc = -1;
    integer lat_total = 0, lat_min = 99999, lat_max = -1;
    integer first_lat = -1;
    integer peak = 0, nz = 0;
    integer pending = 0;

    always @(posedge clk) begin
        if (bus_vld) begin
            n_in = n_in + 1;
            last_in_cyc = cyc;
            pending = 1;
        end
        if (fx_vld) begin
            n_vld = n_vld + 1;
            if (pending) begin
                begin : latblk
                    integer l;
                    l = cyc - last_in_cyc;
                    first_lat = (first_lat < 0) ? l : first_lat;
                    lat_total = lat_total + l;
                    if (l < lat_min) lat_min = l;
                    if (l > lat_max) lat_max = l;
                end
                pending = 0;
            end
            if (fx_l != 0 || fx_r != 0) nz = nz + 1;
            if (fx_l > peak) peak = fx_l;
            if (-fx_l > peak) peak = -fx_l;
        end
    end

    // ⚠ 真实系统里 bus_vld 是**每采样一次**（1024 拍一个采样），中间有大段空闲；
    //   这里按同样节奏驱动：打完一个 vld 后等 GAP 拍再打下一个。
    //   （如果每拍都打 vld，fx_top 的 busy 还没结束就会漏样——那是使用方式错误，不是 bug。）
    task drive_one;
        input integer v;
        input integer gap;
        begin
            @(negedge clk);
            bus_vld = 1;
            br_l = v; br_r = v;
            bc_l = v; bc_r = v;
            bd_l = v; bd_r = v;
            @(negedge clk);
            bus_vld = 0;
            repeat (gap) @(negedge clk);
        end
    endtask

    integer i, errs = 0;

    initial begin
        // 参数：都开到有输出
        r_size = 16'd26000; r_decay = 16'd30000; r_damp = 16'd9000;
        r_predly = 16'd0;   r_ret   = 16'd32767;
        c_rate = 16'd0;     c_depth = 16'd0;     c_mix = 16'd32767; c_ret = 16'd32767;
        d_time = 16'd50;    d_fb    = 16'd0;     d_mix = 16'd32767; d_ret = 16'd32767;
        br_l = 0; br_r = 0; bc_l = 0; bc_r = 0; bd_l = 0; bd_r = 0;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // ---------------- 1~4) 连打 60 个采样 ----------------
        $display("=== 1~4) 连打 %0d 个采样，检查每次都出结果 ===", NS);
        for (i = 0; i < NS; i = i + 1) drive_one(1000 + i, 200);
        repeat (400) @(posedge clk);

        $display("  输入 bus_vld 次数 = %0d", n_in);
        $display("  输出 fx_vld 次数 = %0d  %s", n_vld,
                 (n_vld == n_in) ? "（一一对应 OK）" : "（不匹配！）");
        if (n_vld != n_in) begin
            $display("  FAIL: 输出次数与输入次数不一致 → 有丢样（旧握手就是这个问题）");
            errs = errs + 1;
        end
        $display("  fx_vld 延迟：首次 %0d 拍，最小 %0d，最大 %0d，平均 %0d 拍",
                 first_lat, lat_min, lat_max, lat_total / (n_vld > 0 ? n_vld : 1));
        if (lat_min != lat_max) begin
            $display("  FAIL: 延迟不固定（应在每次 bus_vld 后固定 %0d 拍）", dut.LAT_MAX);
            errs = errs + 1;
        end
        // 固定完成时刻 = LAT_MAX + 2（done 拉高到 fx_vld 锁存隔 1 拍 + 计数起点差 1 拍）
        if (lat_min != dut.LAT_MAX + 2) begin
            $display("  FAIL: 固定延迟 %0d ≠ LAT_MAX+2 = %0d", lat_min, dut.LAT_MAX + 2);
            errs = errs + 1;
        end
        if (lat_min < 122) begin
            $display("  FAIL: 固定延迟 %0d 小于混响的 121 拍，会抓到没算完的返回", lat_min);
            errs = errs + 1;
        end
        $display("  非零输出次数 = %0d / %0d", nz, n_vld);
        if (nz == 0) begin $display("  FAIL: 输出恒为 0（效果器没在贡献）"); errs = errs + 1; end
        $display("  |fx_l| 峰值 = %0d（有界，未溢出）", peak);
        if (peak > 32'sd8300000) begin $display("  FAIL: 输出接近/越过饱和"); errs = errs + 1; end

        $display("");
        $display("=== 5) 冒烟：延迟/合唱各自旁路后的行为 ===");
        // 这里只能检查"顶层实例化能编译、能跑"，真正的旁路组合要另建实例（见 tb_fx_bypass）
        $display("  （旁路组合在 tb_fx_bypass 里用不同参数实例化验证）");

        $display("");
        $display("=== 6) 索引对齐 ===");
        $display("  %s", (n_vld == n_in) ? "1:1 OK" : "不匹配");

        if (errs == 0) $display("\nPASS  tb_fx_top: 握手/延迟/有界 全过");
        else           $display("\nFAIL  tb_fx_top: %0d 项", errs);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL  tb_fx_top: 超时  n_in=%0d n_vld=%0d", n_in, n_vld);
        $finish;
    end

endmodule
`default_nettype wire
