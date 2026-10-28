//  tb_reverb_diag2 —— 混响电平/包络诊断（支持 +FREQ= +NIN= +NFRAMES= +DUT=）
//  2026-10-28 临时工具。统计每一级峰值 + 每 1000 帧打印一次湿声包络（dBFS）。
`timescale 1ns/1ps
`default_nettype none

module tb_reverb_diag2;
    localparam integer PERIOD = 1024;
    localparam real    FS_HZ  = 48828.125;

    parameter integer P_SIZE  = 26000;
    parameter integer P_DECAY = 31000;
    parameter integer P_DAMP  = 24576;
    parameter integer P_RET   = 26000;

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

    integer FREQ = 1000;
    integer NIN  = 20000;
    integer NFR  = 40000;
    real    AMP  = 0.60;

    integer cyc = 0, n = 0;
    real ang;
    integer v;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cyc <= 0; n <= 0; in_vld <= 1'b0; bus_l <= 24'sd0; bus_r <= 24'sd0;
        end else begin
            in_vld <= 1'b0;
            if (cyc == PERIOD-1) begin
                cyc <= 0;
                if (n < NFR) begin
                    if (n < NIN) begin
                        ang = 2.0*3.14159265358979*$itor(FREQ)*$itor(n)/FS_HZ;
                        v   = $rtoi(AMP*8388607.0*$sin(ang));
                        bus_l <= v[23:0];
                        bus_r <= v[23:0];
                    end else begin
                        bus_l <= 24'sd0;
                        bus_r <= 24'sd0;
                    end
                    in_vld <= 1'b1;
                    n <= n + 1;
                end
            end else cyc <= cyc + 1;
        end
    end

    // ---------------- 统计 ----------------
    integer inj=0, m0_l=0, m0_r=0, wd_l=0, wd_r=0, cs_l=0, cs_r=0;
    integer apx_l=0, apx_r=0, apo_l=0, apo_r=0, retl=0, retr=0;
    integer cnt_wd_sat=0, cnt_cs_sat=0, cnt_apo_wrap=0;
    integer t;

    always @(posedge clk) begin
        if (rst_n) begin
            t = $signed(dut.bl); if (t<0) t=-t; if (t>inj) inj=t;
            if (dut.st == 3'd3 && dut.li < 5'd16) begin
                t = $signed(dut.m0); if (t<0) t=-t;
                if (dut.ch == 1'b0) begin if (t>m0_l) m0_l=t; end
                else                 begin if (t>m0_r) m0_r=t; end
            end
            if (dut.st == 3'd4 && dut.li < 5'd16) begin
                t = $signed(dut.comb_w); if (t<0) t=-t;
                if (dut.ch == 1'b0) begin if (t>wd_l) wd_l=t; end
                else                 begin if (t>wd_r) wd_r=t; end
                if (t > 8388607 && dut.ch == 1'b0) cnt_wd_sat = cnt_wd_sat + 1;
            end
            if (dut.st == 3'd4 && dut.li == 5'd15) begin
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
                t = $signed(dut.ap_in_c); if (t<0) t=-t;
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

    // 每 1000 帧的湿声极值（dBFS），看建立与衰减
    integer fcnt = 0, segl = 0, segr = 0, seg = 0;
    always @(posedge clk) begin
        if (rst_n && ret_vld) begin
            fcnt = fcnt + 1;
            t = $signed(ret_l); if (t<0) t=-t; if (t>segl) segl=t;
            t = $signed(ret_r); if (t<0) t=-t; if (t>segr) segr=t;
            if (fcnt % 2000 == 0) begin
                $display("ENV f=%0d  |retL|=%0d (%.1f dBFS)  |retR|=%0d (%.1f dBFS)",
                         fcnt, segl, (segl>0)?(20.0*$log10(segl/8388608.0)):-999.0,
                         segr, (segr>0)?(20.0*$log10(segr/8388608.0)):-999.0);
                segl = 0; segr = 0;
            end
        end
    end

    initial begin
        if ($value$plusargs("FREQ=%d", FREQ)) ;
        if ($value$plusargs("NIN=%d",  NIN))  ;
        if ($value$plusargs("NFR=%d",  NFR))  ;
        repeat (8) @(posedge clk);
        rst_n = 1;
        wait (n >= NFR);
        repeat (PERIOD*3) @(posedge clk);
        $display("");
        $display("=== 频率 %0d Hz, 输入 %0d 帧, 总 %0d 帧, size=%0d decay=%0d damp=%0d ret=%0d ===",
                 FREQ, NIN, NFR, P_SIZE, P_DECAY, P_DAMP, P_RET);
        $display("  注入 bl 峰值        : %0d  (%.4f FS)", inj, inj/8388608.0);
        $display("  单梳 m0 峰值   L/R  : %0d / %0d  (%.4f / %.4f FS)", m0_l, m0_r, m0_l/8388608.0, m0_r/8388608.0);
        $display("  单梳写回峰值   L/R  : %0d / %0d  (%.4f / %.4f FS)", wd_l, wd_r, wd_l/8388608.0, wd_r/8388608.0);
        $display("  16 梳之和      L/R  : %0d / %0d  (%.4f / %.4f FS)", cs_l, cs_r, cs_l/8388608.0, cs_r/8388608.0);
        $display("  全通 ap_x      L/R  : %0d / %0d  (%.4f / %.4f FS)", apx_l, apx_r, apx_l/8388608.0, apx_r/8388608.0);
        $display("  全通 ap_out    L/R  : %0d / %0d  (%.4f / %.4f FS)", apo_l, apo_r, apo_l/8388608.0, apo_r/8388608.0);
        $display("  ret 峰值       L/R  : %0d / %0d  (%.4f / %.4f FS)", retl, retr, retl/8388608.0, retr/8388608.0);
        $display("  写回饱和 / 求和钳位 / ap_out 溢出 : %0d / %0d / %0d",
                 cnt_wd_sat, cnt_cs_sat, cnt_apo_wrap);
        $finish;
    end

endmodule
`default_nettype wire
