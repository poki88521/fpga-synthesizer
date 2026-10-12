//============================================================================
//  tb_pt8211_tx —— 验证 PT8211 LSBJ 帧格式
//
//  站在 DAC 的角度看：在 BCLK 上升沿采样 DIN，检查
//      1) BCLK 周期 = 32 个主时钟（÷32）
//      2) 每 16 个 BCLK 切换一次 WS
//      3) WS 低那 16 位 = 左字 MSB 先出、WS 高那 16 位 = 右字 MSB 先出
//      4) 首尾对齐：MSB 落在该声道第 1 个 BCLK、LSB 落在第 16 个
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_pt8211_tx;

    localparam [15:0] SEND_L = 16'hA55A;
    localparam [15:0] SEND_R = 16'h3CC3;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;                  // 50 MHz

    reg  [15:0] tx_l = 16'd0, tx_r = 16'd0;
    wire        sample_stb, bclk, ws, din;

    pt8211_tx #(.DIV_BIT(32), .WS_INVERT(1)) dut (   // 手册：WS 高 = 左
        .clk(clk), .rst_n(rst_n),
        .sample_l(tx_l), .sample_r(tx_r),
        .sample_stb(sample_stb),
        .bclk(bclk), .ws(ws), .din(din)
    );

    // ---- 发送端：全同步换数据 ----
    integer frame_cnt = 0;
    always @(posedge clk) begin
        if (sample_stb && rst_n) begin
            tx_l <= SEND_L;
            tx_r <= SEND_R;
            frame_cnt <= frame_cnt + 1;
        end
    end

    // ---- 接收端：像 DAC 一样在 BCLK 上升沿采样 ----
    reg [15:0] wl = 0, wr = 0;
    reg [3:0]  nl = 0, nr = 0;
    reg [15:0] rl = 0, rr = 0;
    integer    frames = 0;

    // ⚠ 判定约定按 PT8211 一手手册：WS **高** = 左声道
    wire ws_low = ws;       // 取名为 ws_low 但语义已是「本拍是左声道」

    always @(posedge bclk) begin
        if (ws_low) begin
            wl <= {wl[14:0], din};
            if (nl == 4'd15) begin rl <= {wl[14:0], din}; nl <= 4'd0; end
            else                   nl <= nl + 4'd1;
        end else begin
            wr <= {wr[14:0], din};
            if (nr == 4'd15) begin rr <= {wr[14:0], din}; nr <= 4'd0; frames <= frames + 1; end
            else                   nr <= nr + 4'd1;
        end
    end

    // ---- BCLK 周期（按主时钟数） ----
    reg prev_bclk = 0;
    integer bper = 0, bper_bad = 0;
    always @(posedge clk) begin
        prev_bclk <= bclk;
        if (bclk && !prev_bclk) begin
            if (bper != 0 && bper != 32) bper_bad = bper_bad + 1;
            bper <= 1;
        end else if (bper != 0) begin
            bper <= bper + 1;
        end
    end

    // ---- WS 半周期（按 BCLK 数） ----
    reg prev_ws = 0;
    integer wper = 0, wper_bad = 0;
    always @(posedge bclk) begin
        prev_ws <= ws;
        if (ws !== prev_ws) begin
            if (wper != 0 && wper != 16) wper_bad = wper_bad + 1;
            wper <= 1;
        end else if (wper != 0) begin
            wper <= wper + 1;
        end
    end

    integer errs = 0;

    // 看门狗：跑太久就报错退出，避免仿真挂死
    initial begin
        #(2000000);
        $display("FAIL  tb_pt8211_tx: 仿真超时（看门狗触发）");
        $finish;
    end

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;

        wait (frames >= 5);
        @(posedge clk);

        $display("  BCLK 周期偏差(应 32 主时钟): %0d 次异常", bper_bad);
        $display("  WS 半周期偏差(应 16 BCLK) : %0d 次异常", wper_bad);
        $display("  解码左字 = %h （发送 %h）", rl, SEND_L);
        $display("  解码右字 = %h （发送 %h）", rr, SEND_R);

        if (bper_bad != 0) begin $display("  FAIL: BCLK 不是 ÷32"); errs=errs+1; end
        if (wper_bad != 0) begin $display("  FAIL: WS 不是每 16 BCLK 翻转"); errs=errs+1; end
        if (rl !== SEND_L) begin $display("  FAIL: 左字不符"); errs=errs+1; end
        if (rr !== SEND_R) begin $display("  FAIL: 右字不符"); errs=errs+1; end

        if (errs == 0) $display("PASS  tb_pt8211_tx");
        else           $display("FAIL  tb_pt8211_tx: %0d 个错误", errs);
        $finish;
    end

endmodule
`default_nettype wire
