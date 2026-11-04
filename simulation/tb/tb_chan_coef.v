//  tb_chan_coef —— 验证 volume/expression → gL/gR（含一阶平滑收敛）
`timescale 1ns/1ps
module tb_chan_coef;
    localparam integer NCH = 16;
    reg clk = 0, rst_n = 0;
    reg [NCH*7-1:0]  volume = 0, expression = 0;
    reg signed [NCH*16-1:0] panL = 0, panR = 0;
    wire signed [NCH*16-1:0] gL, gR;
    always #10.17 clk = ~clk;

    chan_coef #(.NCH(NCH)) dut (
        .clk(clk), .rst_n(rst_n), .volume(volume), .expression(expression),
        .pan_gL(panL), .pan_gR(panR), .gL_flat(gL), .gR_flat(gR));

    integer k;
    integer gl0, gl_mid, gl_end, gl_exp;
    task wait_settle; begin repeat (1200000) @(posedge clk); end endtask

    initial begin
        for (k = 0; k < NCH; k = k + 1) begin
            volume[k*7 +: 7]     = 7'd100;
            expression[k*7 +: 7] = 7'd127;
            panL[k*16 +: 16]     = 16'sd23170;
            panR[k*16 +: 16]     = 16'sd23170;
        end
        repeat (10) @(posedge clk); rst_n = 1;
        wait_settle;
        gl0 = $signed(gL[15:0]);
        $display("");
        $display("gL[0] 收敛 = %0d   预期 %0d", gl0, (((100<<8)*(127<<8))>>15)*23170>>15);

        for (k = 0; k < NCH; k = k + 1) expression[k*7 +: 7] = 7'd32;
        wait_settle;
        gl_mid = $signed(gL[15:0]);
        gl_exp = (((100<<8)*(32<<8))>>15)*23170>>15;
        $display("表情 127->32 : gL[0] %0d -> %0d   预期 %0d", gl0, gl_mid, gl_exp);
        if (gl_mid === gl0)        $display("  FAIL 表情完全无效果");
        else if (gl_mid > gl0)     $display("  FAIL 方向反了");
        else if (gl_mid > gl_exp*12/10 || gl_mid < gl_exp*8/10) $display("  FAIL 数值不对");
        else                       $display("  PASS 表情生效且数值正确");

        for (k = 0; k < NCH; k = k + 1) begin
            volume[k*7 +: 7]     = 7'd100;
            expression[k*7 +: 7] = 7'd127;
        end
        wait_settle;
        gl0 = $signed(gL[3*16 +: 16]);
        volume[3*7 +: 7] = 7'd40;
        wait_settle;
        gl_end = $signed(gL[3*16 +: 16]);
        $display("仅 ch3 volume 100->40 : gL[3] %0d -> %0d  (预期 %0d)", gl0, gl_end,
                 (((40<<8)*(127<<8))>>15)*23170>>15);
        if (gl_end === gl0) $display("  FAIL 单通道音量无效");
        else $display("  PASS 单通道音量生效");
        $finish;
    end
endmodule
