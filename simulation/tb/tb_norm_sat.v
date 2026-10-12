//============================================================================
//  tb_norm_sat —— 随机化验证「归一化 + 饱和」单元
//
//  参考模型直接用 49-bit 有符号整数算，和 RTL 对比。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_norm_sat;

    localparam integer IN_W = 48, SHIFT = 15, OUT_W = 24;

    reg  signed [IN_W-1:0] acc;
    wire signed [OUT_W-1:0] y;

    norm_sat #(.IN_W(IN_W), .SHIFT(SHIFT), .OUT_W(OUT_W), .ROUND(1)) dut (
        .acc(acc), .y(y)
    );

    // ---- 参考模型 ----
    function signed [OUT_W-1:0] ref_sat;
        input signed [IN_W-1:0] a;
        reg signed [IN_W:0] tmp;
        reg signed [IN_W+1:0] sh;
        begin
            tmp = {{1{a[IN_W-1]}}, a} + ({{(IN_W){1'b0}}, 1'b1} << (SHIFT-1));
            sh  = tmp >>> SHIFT;
            if      (sh >  (1 <<< (OUT_W-1))-1) ref_sat = {1'b0, {(OUT_W-1){1'b1}}};
            else if (sh < -(1 <<< (OUT_W-1)))   ref_sat = {1'b1, {(OUT_W-1){1'b0}}};
            else                                ref_sat = sh[OUT_W-1:0];
        end
    endfunction

    integer i, errs;
    reg [63:0] lcg;
    reg signed [IN_W-1:0] v;
    reg signed [OUT_W-1:0] exp;

    initial begin
        errs = 0;
        lcg  = 64'h0123_4567_89AB_CDEF;

        // ---- 定向用例 ----
        acc = 48'sd0;                     #1; exp = ref_sat(48'sd0);
        if (y !== exp) begin $display("FAIL zero: y=%0d exp=%0d", y, exp); errs=errs+1; end

        acc = 48'sd16384;                 #1; exp = ref_sat(48'sd16384);
        if (y !== exp) begin $display("FAIL round-up: y=%0d exp=%0d", y, exp); errs=errs+1; end

        acc = 48'sd16383;                 #1; exp = ref_sat(48'sd16383);
        if (y !== exp) begin $display("FAIL round-down: y=%0d exp=%0d", y, exp); errs=errs+1; end

        // 最大正累加：32 路 x 2^38 = 2^43
        acc = (48'sd1 <<< 43);            #1;
        if (y !== 24'sh7FFFFF) begin $display("FAIL +ovf: y=%h", y); errs=errs+1; end

        acc = -(48'sd1 <<< 43);           #1;
        if (y !== 24'sh800000) begin $display("FAIL -ovf: y=%h", y); errs=errs+1; end

        // 刚好不溢出：+0x7FFFFF 对应的 acc = 0x7FFFFF * 2^15
        acc = 48'sd8388607 * 48'sd32768;  #1;
        if (y !== 24'sh7FFFFF) begin $display("FAIL edge+: y=%h", y); errs=errs+1; end

        // ---- 随机 2000 组 ----
        for (i = 0; i < 2000; i = i + 1) begin
            lcg = lcg * 64'd6364136223846793005 + 64'd1442695040888963407;
            v   = lcg[47:0];
            acc = v;  #1;
            exp = ref_sat(v);
            if ((y !== exp) && (errs <= 5)) begin
                $display("FAIL rand i=%0d acc=%0d y=%0d exp=%0d", i, acc, y, exp);
                errs = errs + 1;
            end
        end

        if (errs == 0) $display("PASS  tb_norm_sat: 所有用例通过（含 2000 组随机）");
        else           $display("FAIL  tb_norm_sat: %0d 个错误", errs);
        $finish;
    end

endmodule
`default_nettype wire
