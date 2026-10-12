//============================================================================
//  tb_fx_delay —— 延迟效果器脉冲响应验证
//
//  喂一个单采样脉冲，逐采样与参考模型比对：
//      期望：第 D 个采样出现回声，幅度 1.0；反馈 0.5 时第 2D 个是 0.5，
//            第 3D 个是 0.25 ……
//  这个测试能同时抓住：抽头位置错、反馈量错、漏移位（反馈大 32768 倍）
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_fx_delay;
    localparam integer AW     = 24;
    localparam integer PERIOD = 8;        // 每采样 8 拍（FSM 只要 3 拍）
    localparam integer NS     = 400;
    localparam integer D      = 100;      // 延迟采样数

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg  signed [AW-1:0] bus_l, bus_r;
    reg                  in_vld;
    wire                 ret_vld;
    wire signed [AW-1:0] ret_l, ret_r;

    fx_delay #(.AW(AW), .MAXLEN(16384), .ABW(14)) dut (
        .clk(clk), .rst_n(rst_n), .frame_stb(1'b0),
        .in_vld(in_vld), .bus_l(bus_l), .bus_r(bus_r),
        .p_time(16'd100), .p_fb(16'd16384),     // fb = 0.5
        .p_mix(16'd32767), .p_ret(16'd32767),   // 近乎全湿、满返回
        .ret_vld(ret_vld), .ret_l(ret_l), .ret_r(ret_r)
    );

    // ---------------- 激励与比对 ----------------
    reg signed [AW-1:0] in_seq  [0:NS-1];
    reg signed [AW-1:0] exp_seq [0:NS-1];
    reg signed [AW-1:0] got_seq [0:NS-1];

    integer n, k;
    integer cyc;
    integer errs = 0;
    integer nchk = 0;

    // 参考模型（逐位复刻 RTL 的定点）
    function automatic signed [AW-1:0] sat24;
        input signed [47:0] v;
        begin
            if      (v >  48'sd8388607) sat24 = 24'sh7FFFFF;
            else if (v < -48'sd8388608) sat24 = 24'sh800000;
            else                        sat24 = v[AW-1:0];
        end
    endfunction

    reg signed [AW-1:0] hist [0:NS-1];
    reg signed [AW-1:0] wet_r, out_r;
    reg signed [47:0]   tmp;
    integer i;

    initial begin
        for (i = 0; i < NS; i = i + 1) begin
            in_seq[i]  = (i == 0) ? 24'sd1000000 : 24'sd0;
            hist[i]    = 24'sd0;
        end
        for (i = 0; i < NS; i = i + 1) begin
            wet_r = (i >= D) ? hist[i-D] : 24'sd0;
            // hist = sat24( ((fb*wet)>>>15) + bus )
            tmp   = (($signed(wet_r) * 48'sd16384) >>> 15) + {{24{in_seq[i][AW-1]}}, in_seq[i]};
            hist[i] = sat24(tmp);
            // out = sat24( (bus*(32768-mix) + wet*mix) >>> 15 )
            tmp   = ( $signed(in_seq[i]) * 48'sd1
                    + $signed(wet_r)     * 48'sd32767 ) >>> 15;
            out_r = sat24(tmp);
            // ret = sat24( (out*32767) >>> 15 )
            tmp   = ($signed(out_r) * 48'sd32767) >>> 15;
            exp_seq[i] = sat24(tmp);
        end
    end

    // 驱动：每 PERIOD 拍一个采样
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cyc <= 0; n <= 0; in_vld <= 1'b0; bus_l <= 0; bus_r <= 0;
        end else begin
            in_vld <= 1'b0;
            if (cyc == PERIOD-1) begin
                cyc <= 0;
                if (n < NS) begin
                    in_vld <= 1'b1;
                    bus_l  <= in_seq[n];
                    bus_r  <= in_seq[n];
                    n      <= n + 1;
                end
            end else cyc <= cyc + 1;
        end
    end

    // 采样输出
    integer m = 0;
    always @(posedge clk) if (ret_vld) begin got_seq[m] = ret_l; m = m + 1; end

    // ---- 调试：打印前几个采样和第一次回声附近的内部状态 ----
    always @(posedge clk) begin
        if (in_vld && (n <= 3 || (n >= 99 && n <= 103)))
            $display("  [dbg] 驱动 n=%0d  dut.wptr=%0d  dut.st=%0d  rdata=%0d",
                     n, dut.wptr, dut.st, dut.rdata_l);
        if (ret_vld && (m <= 3 || (m >= 99 && m <= 103)))
            $display("  [dbg] 输出 m=%0d  wl=%0d  ret=%0d", m, dut.wl, ret_l);
    end

    // 汇总
    initial begin
        #2_000_000;
        $display("FAIL  tb_fx_delay: 超时");
        $finish;
    end

    always @(posedge clk) begin
        if (m >= NS) begin
            for (k = 0; k < NS; k = k + 1) begin
                nchk = nchk + 1;
                if (got_seq[k] !== exp_seq[k]) begin
                    if (errs < 8)
                        $display("  FAIL 采样%0d got=%0d exp=%0d", k, got_seq[k], exp_seq[k]);
                    errs = errs + 1;
                end
            end
            $display("  脉冲回声（第 0/100/200/300 个采样）：");
            $display("    实测 %0d / %0d / %0d / %0d",
                     got_seq[0], got_seq[D], got_seq[2*D], got_seq[3*D]);
            $display("    期望 %0d / %0d / %0d / %0d",
                     exp_seq[0], exp_seq[D], exp_seq[2*D], exp_seq[3*D]);
            if (errs == 0) $display("PASS  tb_fx_delay: %0d 个采样全部一致", nchk);
            else           $display("FAIL  tb_fx_delay: %0d / %0d 不一致", errs, nchk);
            $finish;
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
    end
endmodule
`default_nettype wire
