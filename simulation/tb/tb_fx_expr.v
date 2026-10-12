//============================================================================
//  tb_fx_expr —— 效果器定点表达式的位宽/符号"单元测试"
//
//  背景（2026-10-05 发现）：
//      fx_reverb / fx_delay / fx_chorus 里这类写法
//          ({{(48-(AW+16)){p[AW+15]}}, p} >>> 15) + {{24{x[AW-1]}}, x}
//      实测**并没有**得到期望的值：中间位整段丢失、正负不对称。
//      这就是 tb_fx_reverb "第 1705 个输出 = 8388351" 的根因。
//
//  本 TB 不跑 FSM，只把表达式孤立出来做数值对照：
//      现有写法  vs  显式符号扩展到 48 位再 >>>15
//  覆盖：正负满量程、正负小值、零、2^17。
//
//  注：iverilog 13 不支持带类型/范围的 task 端口，本仓库统一用 function。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_fx_expr;
    localparam integer AW = 24;
    integer errs = 0;

    reg signed [AW-1:0] m0, ax, xin, fsc, fsnew;

    // ---------------- 现有写法（逐字照抄 RTL）----------------
    wire signed [AW+15:0] ap_fb_p   = $signed(m0) * 16'sd16384;
    wire signed [47:0]    ap_w_now  = ({{(48-(AW+16)){ap_fb_p[AW+15]}}, ap_fb_p} >>> 15)
                                    + {{24{ax[AW-1]}}, ax};

    wire signed [AW+15:0] fs_new_p  = $signed(m0) * (16'sd32767 - 16'sd9000) + fsc * 16'sd9000;
    wire signed [AW+15:0] comb_w_p  = fsnew * 16'sd30000;
    wire signed [47:0]    comb_w_now= ({{(48-(AW+16)){comb_w_p[AW+15]}}, comb_w_p} >>> 15)
                                    + {{24{xin[AW-1]}}, xin};

    // ---------------- 候选修法 1：$signed() 到 48 位再 >>> ----------------
    wire signed [47:0] ap_pr1  = $signed(m0) * 48'sd16384;
    wire signed [47:0] ap_w_f1 = (ap_pr1 >>> 15) + $signed(ax);
    wire signed [47:0] cw_pr1  = $signed(fsnew) * 48'sd30000;
    wire signed [47:0] cw_f1   = (cw_pr1 >>> 15) + $signed(xin);

    // ---------------- 候选修法 2：显式复制符号位拼宽再 >>> ----------------
    wire signed [47:0] m0x    = {{24{m0[AW-1]}}, m0};
    wire signed [47:0] axx    = {{24{ax[AW-1]}}, ax};
    wire signed [47:0] fsnewx = {{24{fsnew[AW-1]}}, fsnew};
    wire signed [47:0] xinx   = {{24{xin[AW-1]}}, xin};
    wire signed [47:0] ap_pr2  = m0x * 48'sd16384;
    wire signed [47:0] ap_w_f2 = (ap_pr2 >>> 15) + axx;
    wire signed [47:0] cw_pr2  = fsnewx * 48'sd30000;
    wire signed [47:0] cw_f2   = (cw_pr2 >>> 15) + xinx;

    // ---------------- 金标准（与 RTL 同构的 sat24）----------------
    function signed [AW-1:0] sat24; input signed [47:0] v; begin
        if      (v >  48'sd8388607) sat24 = 24'sh7FFFFF;
        else if (v < -48'sd8388608) sat24 = 24'sh800000;
        else                        sat24 = v[AW-1:0];
    end endfunction

    function signed [47:0] gold_ap; input [AW-1:0] v; reg signed [47:0] vx; begin
        vx = {{24{v[AW-1]}}, v};
        gold_ap = (vx * 48'sd16384) >>> 15;
    end endfunction

    function signed [47:0] gold_cw; input [AW-1:0] v; reg signed [47:0] vx; begin
        vx = {{24{v[AW-1]}}, v};
        gold_cw = (vx * 48'sd30000) >>> 15;
    end endfunction

    // ---------------- 测试向量 ----------------
    reg signed [AW-1:0] vlist [0:9];
    integer k;
    reg signed [47:0] exp_ap;
    initial begin
        vlist[0] =  24'sd8388607;   // 正满量程
        vlist[1] =  24'sd8388606;
        vlist[2] =  24'sd1000;
        vlist[3] =  24'sd1;
        vlist[4] =  24'sd0;
        vlist[5] = -24'sd1;
        vlist[6] = -24'sd1000;
        vlist[7] = -24'sd8388606;
        vlist[8] = -24'sd8388608;   // 负满量程
        vlist[9] =  24'sd131072;    // 2^17
        fsc = 24'sd0; xin = 24'sd0;

        for (k = 0; k < 10; k = k + 1) begin
            // ---- 全通写回值 ap_w = (m0*0.5) + ap_x ----
            m0 = vlist[k]; ax = vlist[k]; #1;
            exp_ap = gold_ap(vlist[k]) + {{24{vlist[k][AW-1]}}, vlist[k]};
            if ((ap_w_f1 !== exp_ap) || (ap_w_f2 !== exp_ap)) begin
                $display("FAIL ap_w 修法: m0=%0d 修法1=%0d 修法2=%0d", vlist[k], ap_w_f1, ap_w_f2);
                errs = errs + 1;
            end else if (ap_w_now !== exp_ap) begin
                $display("  现有 ap_w 错: m0=%0d 现有=%0d 正确=%0d",
                         vlist[k], ap_w_now, exp_ap);
            end
            // ---- 梳状写回值 comb_w = (fs_new*decay) + xin ----
            fsnew = vlist[k]; #1;
            if ((cw_f1 !== gold_cw(vlist[k])) || (cw_f2 !== gold_cw(vlist[k]))) begin
                $display("FAIL comb_w 修法: fs_new=%0d 修法1=%0d 修法2=%0d", vlist[k], cw_f1, cw_f2);
                errs = errs + 1;
            end else if (comb_w_now !== gold_cw(vlist[k])) begin
                $display("  现有 comb_w 错: fs_new=%0d 现有=%0d 正确=%0d",
                         vlist[k], comb_w_now, gold_cw(vlist[k]));
            end
        end

        // ---- sat24 上下必须对称 ----
        if (sat24( 48'sd8388608) !==  24'sh7FFFFF) begin $display("FAIL sat24 上钳位"); errs = errs + 1; end
        if (sat24(-48'sd8388609) !==  24'sh800000) begin $display("FAIL sat24 下钳位"); errs = errs + 1; end
        if (sat24( 48'sd8388607) !==  24'sh7FFFFF) begin $display("FAIL sat24 边界+"); errs = errs + 1; end
        if (sat24(-48'sd8388608) !==  24'sh800000) begin $display("FAIL sat24 边界-"); errs = errs + 1; end

        $display("");
        $display("--- 现有写法对负数的偏差（混响 1705 爆炸的根因）---");
        m0 = -24'sd1000; ax = -24'sd1000; #1;
        $display("  m0=-1000     : ap_w   现有=%0d   正确=%0d", ap_w_now, ap_w_f1);
        fsnew = -24'sd1000; #1;
        $display("  fs_new=-1000 : comb_w 现有=%0d  正确=%0d", comb_w_now, cw_f1);

        if (errs == 0) $display("\nPASS  tb_fx_expr: 候选修法 20 组一致 + sat24 上下对称");
        else           $display("\nFAIL  tb_fx_expr: %0d 项", errs);
        $finish;
    end
endmodule
`default_nettype wire
