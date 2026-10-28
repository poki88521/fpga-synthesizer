//  tb_reverb_diag —— 混响内部电平逐级诊断（2026-10-28，临时工具，不放 simulation/tb）
//  目的：定位"有音+开混响→炸"的结构性根因，量化每一级节点的峰值/削顶。
//  左/右声道分开统计（怀疑右声道延迟线区间互相重叠）。
`timescale 1ns/1ps
`default_nettype none

module tb_reverb_diag;
    localparam integer PERIOD = 1024;
    localparam integer NIN    = 3000;    // 前 NIN 帧有输入（0.60 FS 1 kHz 正弦）
    localparam real    FS_HZ  = 48828.125;

    localparam integer P_SIZE  = 26000;
    localparam integer P_DECAY = 31000;
    localparam integer P_DAMP  = 24576;   // full_top.v 现值（原 14000）
    localparam integer P_RET   = 26000;

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
        .p_decay(P_DECAY[15:0]), .p_damp(P_DAMP[15:0]),
        .p_size(P_SIZE[15:0]), .p_ret(P_RET[15:0]), .p_predly(16'd0),
        .ret_vld(ret_vld), .ret_l(ret_l), .ret_r(ret_r)
    );

    // ---------------- 激励 ----------------
    integer cyc = 0, n = 0;
    real    ang;
    integer v;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cyc <= 0; n <= 0; in_vld <= 1'b0; bus_l <= 24'sd0; bus_r <= 24'sd0;
        end else begin
            in_vld <= 1'b0;
            if (cyc == PERIOD-1) begin
                cyc <= 0;
                if (n < NIN) begin
                    ang = 2.0*3.14159265358979*1000.0*$itor(n)/FS_HZ;
                    v   = $rtoi(0.60*8388607.0*$sin(ang));
                    bus_l <= v[23:0];
                    bus_r <= v[23:0];
                    in_vld <= 1'b1;
                    n <= n + 1;
                end
            end else cyc <= cyc + 1;
        end
    end

    // ---------------- 统计 ----------------
    //  st 编码：0 IDLE 1 RD 2 ADS 3 WR 4 CM 5 WB
    integer inj    = 0;                  // 总线注入 bl 峰值
    integer m0_l   = 0, m0_r   = 0;      // 单条梳状延迟线读出峰值
    integer wd_l   = 0, wd_r   = 0;      // 梳状写回值（组合 comb_w）峰值
    integer cs_l   = 0, cs_r   = 0;      // 16 条梳状之和 comb_sum_n 峰值
    integer apx_l  = 0, apx_r  = 0;      // 全通链 ap_x 峰值
    integer apo_l  = 0, apo_r  = 0;      // 全通 ap_out 峰值
    integer retl   = 0, retr   = 0;      // 最终 ret 峰值
    integer cnt_cs_sat  = 0;             // comb_sum_n>>>1 被 sat24 钳位次数
    integer cnt_wd_sat  = 0;             // 梳状写回 sat24 钳位次数
    integer cnt_apo_wrap= 0;             // ap_out 25→24 位溢出截断次数
    integer t;

    always @(posedge clk) begin
        if (rst_n) begin
            t = $signed(dut.bl); if (t<0) t=-t; if (t>inj) inj=t;

            if (dut.st == 3'd3 && dut.li < 5'd16) begin          // ST_WR：m0 有效
                t = $signed(dut.m0); if (t<0) t=-t;
                if (dut.ch == 1'b0) begin if (t>m0_l) m0_l=t; end
                else                 begin if (t>m0_r) m0_r=t; end
            end

            if (dut.st == 3'd4 && dut.li < 5'd16) begin          // ST_CM：算写回
                t = $signed(dut.comb_w); if (t<0) t=-t;
                if (dut.ch == 1'b0) begin
                    if (t>wd_l) wd_l=t;
                    if (t > 8388607) cnt_wd_sat = cnt_wd_sat + 1;
                end else begin
                    if (t>wd_r) wd_r=t;
                end
            end

            if (dut.st == 3'd4 && dut.li == 5'd15) begin         // 最后一条梳状 → 全和
                t = $signed(dut.comb_sum_n); if (t<0) t=-t;
                if (dut.ch == 1'b0) begin
                    if (t>cs_l) cs_l=t;
                    if ((dut.comb_sum_n > 48'sd16777215) || (dut.comb_sum_n < -48'sd16777216))
                        cnt_cs_sat = cnt_cs_sat + 1;
                end else begin
                    if (t>cs_r) cs_r=t;
                end
            end

            if (dut.li >= 5'd16) begin
                t = $signed(dut.ap_x); if (t<0) t=-t;
                if (dut.ch == 1'b0) begin if (t>apx_l) apx_l=t; end
                else                 begin if (t>apx_r) apx_r=t; end
                t = $signed(dut.ap_out); if (t<0) t=-t;
                if (dut.ch == 1'b0) begin if (t>apo_l) apo_l=t; end
                else                 begin if (t>apo_r) apo_r=t; end
                if ((dut.ap_out_p > 25'sd8388607) || (dut.ap_out_p < -25'sd8388608))
                    cnt_apo_wrap = cnt_apo_wrap + 1;
            end

            t = $signed(ret_l); if (t<0) t=-t; if (t>retl) retl=t;
            t = $signed(ret_r); if (t<0) t=-t; if (t>retr) retr=t;
        end
    end

    // ---------------- 报告 ----------------
    initial begin
        repeat (8) @(posedge clk);
        rst_n = 1;
        wait (n >= NIN);
        repeat (PERIOD*30) @(posedge clk);
        $display("");
        $display("=== reverb diag: 0.60 FS 1 kHz 正弦, %0d 帧, size=%0d decay=%0d damp=%0d ret=%0d ===",
                 NIN, P_SIZE, P_DECAY, P_DAMP, P_RET);
        $display("  (1.0 FS = 8388608)");
        $display("  总线注入 bl 峰值       : %0d  (%.3f FS)", inj, inj/8388608.0);
        $display("  单梳状 m0 峰值    L/R  : %0d / %0d  (%.3f / %.3f FS)", m0_l, m0_r, m0_l/8388608.0, m0_r/8388608.0);
        $display("  单梳状写回峰值    L/R  : %0d / %0d  (%.3f / %.3f FS)", wd_l, wd_r, wd_l/8388608.0, wd_r/8388608.0);
        $display("  16 梳之和         L/R  : %0d / %0d  (%.3f / %.3f FS)", cs_l, cs_r, cs_l/8388608.0, cs_r/8388608.0);
        $display("  全通 ap_x 峰值    L/R  : %0d / %0d  (%.3f / %.3f FS)", apx_l, apx_r, apx_l/8388608.0, apx_r/8388608.0);
        $display("  全通 ap_out 峰值  L/R  : %0d / %0d  (%.3f / %.3f FS)", apo_l, apo_r, apo_l/8388608.0, apo_r/8388608.0);
        $display("  ret 峰值          L/R  : %0d / %0d  (%.3f / %.3f FS)", retl, retr, retl/8388608.0, retr/8388608.0);
        $display("  梳状写回 sat24 钳位    : %0d 次", cnt_wd_sat);
        $display("  comb_sum>>>1 钳位      : %0d 次", cnt_cs_sat);
        $display("  ap_out 溢出截断        : %0d 次", cnt_apo_wrap);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("FAIL 超时");
        $finish;
    end

endmodule
`default_nettype wire
