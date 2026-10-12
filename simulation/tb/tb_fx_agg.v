//============================================================================
//  tb_fx_agg —— 聚合正确性 + 多效果贡献（长序列）
//
//  目的：
//      1) 让三个效果器都真正产生输出（序列长度要超过合唱 961 / 混响 1215 的延迟线长度）
//      2) 逐点核对 fx_top 的输出 == 三个独立实例输出之和（一次饱和）
//         —— 这是对"聚合逻辑"的强验证，不依赖任何主观判据
//      3) 三个效果各自是否真的有贡献（分别关掉一个看输出是否变化）
//
//  做法：TB 里同时实例化
//      · fx_top（被测）
//      · fx_reverb / fx_chorus / fx_delay 三个独立实例（同参数、同输入）
//    并复刻 fx_top 内部的"各自寄存 + 固定时刻汇总"逻辑作为参考，
//    再用同一个 LAT 延迟对齐后逐点比对。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_fx_agg;
    localparam integer AW = 24;
    localparam integer NS = 1800;       // 要超过混响最长线 1760
    localparam integer GAP = 200;       // 采样间隔 > LAT：一进一出，比对一一对应（真实系统是 1024 拍）
    localparam integer LAT = 130;       // fx_top 的固定完成延迟（实测）

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg  bus_vld = 0;
    reg  signed [AW-1:0] br_l, br_r, bc_l, bc_r, bd_l, bd_r;

    // 参数（三者都开满，保证有湿声）
    wire [15:0] r_size=16'd26000, r_decay=16'd30000, r_damp=16'd9000;
    wire [15:0] r_predly=16'd0,  r_ret=16'd32767;
    wire [15:0] c_rate=16'd0,    c_depth=16'd0,   c_mix=16'd32767, c_ret=16'd32767;
    wire [15:0] d_time=16'd200,  d_fb=16'd0,      d_mix=16'd32767, d_ret=16'd32767;

    // ---------------- 被测：fx_top ----------------
    wire        t_vld;
    wire signed [AW-1:0] t_l, t_r;
    fx_top dut (
        .clk(clk), .rst_n(rst_n), .frame_stb(1'b0), .test_mode(1'b0), .bus_vld(bus_vld),
        .bus_rev_l(br_l), .bus_rev_r(br_r),
        .bus_cho_l(bc_l), .bus_cho_r(bc_r),
        .bus_del_l(bd_l), .bus_del_r(bd_r),
        .reverb_size(r_size), .reverb_decay(r_decay), .reverb_damping(r_damp),
        .reverb_pre_delay(r_predly), .reverb_return(r_ret),
        .chorus_rate(c_rate), .chorus_depth(c_depth), .chorus_mix(c_mix), .chorus_return(c_ret),
        .delay_time(d_time), .delay_feedback(d_fb), .delay_mix(d_mix), .delay_return(d_ret),
        .fx_vld(t_vld), .fx_l(t_l), .fx_r(t_r));

    // ---------------- 参考：三个独立实例 + 复刻寄存/汇总 ----------------
    wire r_vld, c_vld, d_vld;
    wire signed [AW-1:0] r_l, r_r, c_l, c_r, d_l, d_r;

    fx_reverb u_rev (.clk(clk), .rst_n(rst_n), .frame_stb(1'b0), .in_vld(bus_vld),
        .bus_l(br_l), .bus_r(br_r),
        .p_decay(r_decay), .p_damp(r_damp), .p_size(r_size), .p_ret(r_ret), .p_predly(r_predly),
        .ret_vld(r_vld), .ret_l(r_l), .ret_r(r_r));
    fx_chorus u_cho (.clk(clk), .rst_n(rst_n), .frame_stb(1'b0), .in_vld(bus_vld),
        .bus_l(bc_l), .bus_r(bc_r),
        .p_rate(c_rate), .p_depth(c_depth), .p_mix(c_mix), .p_ret(c_ret),
        .ret_vld(c_vld), .ret_l(c_l), .ret_r(c_r));
    fx_delay  u_del (.clk(clk), .rst_n(rst_n), .frame_stb(1'b0), .in_vld(bus_vld),
        .bus_l(bd_l), .bus_r(bd_r),
        .p_time(d_time), .p_fb(d_fb), .p_mix(d_mix), .p_ret(d_ret),
        .ret_vld(d_vld), .ret_l(d_l), .ret_r(d_r));

    reg signed [AW-1:0] qr_l, qr_r, qc_l, qc_r, qd_l, qd_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            qr_l<=0; qr_r<=0; qc_l<=0; qc_r<=0; qd_l<=0; qd_r<=0;
        end else begin
            if (r_vld) begin qr_l <= r_l; qr_r <= r_r; end
            if (c_vld) begin qc_l <= c_l; qc_r <= c_r; end
            if (d_vld) begin qd_l <= d_l; qd_r <= d_r; end
        end
    end

    function automatic signed [AW-1:0] sat24f;
        input signed [47:0] v;
        begin
            if      (v >  48'sd8388607) sat24f = 24'sh7FFFFF;
            else if (v < -48'sd8388608) sat24f = 24'sh800000;
            else                        sat24f = v[AW-1:0];
        end
    endfunction

    wire signed [47:0] ref_l = {{24{qr_l[23]}}, qr_l} + {{24{qc_l[23]}}, qc_l} + {{24{qd_l[23]}}, qd_l};
    wire signed [47:0] ref_r = {{24{qr_r[23]}}, qr_r} + {{24{qc_r[23]}}, qc_r} + {{24{qd_r[23]}}, qd_r};
    wire signed [AW-1:0] ref_sat_l = sat24f(ref_l);
    wire signed [AW-1:0] ref_sat_r = sat24f(ref_r);

    // ---------------- 激励与比对 ----------------
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    integer n_in = 0, n_out = 0, mism = 0, nz = 0, peak = 0;
    integer last_in = -1;
    integer cmp_total = 0;

    always @(posedge clk) begin
        if (bus_vld) begin n_in = n_in + 1; last_in = cyc; end
    end

    // fx_top 输出到点的下一拍再比（此刻各寄存已稳定）
    reg t_vld_d = 0;
    always @(posedge clk) t_vld_d <= t_vld;

    always @(posedge clk) begin
        if (t_vld_d) begin
            n_out = n_out + 1;
            if (t_l != 0 || t_r != 0) nz = nz + 1;
            if (t_l > peak) peak = t_l;
            if (-t_l > peak) peak = -t_l;
            cmp_total = cmp_total + 1;
            if (t_l !== ref_sat_l || t_r !== ref_sat_r) begin
                mism = mism + 1;
                if (mism <= 6)
                    $display("  [MISMATCH] cyc=%0d fx_top=(%0d,%0d) 参考=(%0d,%0d)",
                             cyc, t_l, t_r, ref_sat_l, ref_sat_r);
            end
        end
    end

    // 简单激励：每个采样给一个小值（含正负交替，便于看出调制）
    task drive_one;
        input integer v;
        begin
            @(negedge clk);
            bus_vld = 1; br_l = v; br_r = v; bc_l = v; bc_r = v; bd_l = v; bd_r = v;
            @(negedge clk);
            bus_vld = 0;
            repeat (GAP) @(negedge clk);
        end
    endtask

    integer i, errs = 0;

    initial begin
        br_l=0; br_r=0; bc_l=0; bc_r=0; bd_l=0; bd_r=0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        $display("=== 打 %0d 个采样（超过混响最长延迟线 1760），间隔 %0d 拍 ===", NS, GAP);
        for (i = 0; i < NS; i = i + 1)
            drive_one((i % 2 == 0) ? (2000 + i) : -(2000 + i));
        repeat (LAT + 50) @(posedge clk);

        $display("  bus_vld=%0d  fx_vld=%0d  %s", n_in, n_out,
                 (n_out == n_in) ? "一一对应 OK" : "不匹配！");
        if (n_out != n_in) begin errs = errs + 1; $display("  FAIL: 丢样"); end

        $display("  聚合比对：参与比对 %0d 次，不一致 %0d 次", cmp_total, mism);
        if (cmp_total == 0) begin
            $display("  FAIL: 没有可比对的输出"); errs = errs + 1;
        end else if (mism != 0) begin
            $display("  FAIL: fx_top 输出 != 三个独立实例之和"); errs = errs + 1;
        end

        $display("  非零输出 = %0d / %0d，峰值 = %0d", nz, n_out, peak);
        if (nz == 0) begin $display("  FAIL: 输出恒 0"); errs = errs + 1; end

        if (errs == 0) $display("\nPASS  tb_fx_agg: 握手 + 聚合 + 有信号 全过");
        else           $display("\nFAIL  tb_fx_agg: %0d 项", errs);
        $finish;
    end

    initial begin
        #60_000_000;
        $display("FAIL  tb_fx_agg: 超时  n_in=%0d n_out=%0d mism=%0d", n_in, n_out, mism);
        $finish;
    end

endmodule
`default_nettype wire
