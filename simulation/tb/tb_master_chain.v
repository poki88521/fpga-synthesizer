//============================================================================
//  tb_master_chain —— 端到端：自检音 -> 主输出链 -> PT8211 帧 -> 解码回音频
//
//  复刻 mix_top 的 USE_PLL=0 通路（50 MHz 直连，fs = 50M/1024 = 48828.125 Hz）。
//  把串行流解码成左右声道样本，用零交叉测频率，验证整条链真的产生了 440/880 Hz。
//  这是最有价值的一个测试：它同时验证了定点链路 + 声道对齐 + DAC 帧格式。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_master_chain;

    localparam integer CLK_HZ = 50_000_000;
    localparam integer FS_HZ  = 48828;      // = 50e6 / 1024

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;                  // 50 MHz

    wire        sample_stb, bclk, ws, din;
    wire [15:0] s_l, s_r;

    pt8211_tx #(.DIV_BIT(32), .WS_INVERT(1)) u_tx (   // 手册：WS 高 = 左
        .clk(clk), .rst_n(rst_n),
        .sample_l(s_l), .sample_r(s_r),
        .sample_stb(sample_stb),
        .bclk(bclk), .ws(ws), .din(din)
    );

    wire signed [23:0] tone_l, tone_r;
    test_tone #(.FS_HZ(FS_HZ), .FREQ_L(440), .FREQ_R(880)) u_tone (
        .clk(clk), .rst_n(rst_n), .en(sample_stb),
        .l(tone_l), .r(tone_r)
    );

    master_chain u_chain (
        .clk(clk), .rst_n(rst_n), .en(sample_stb),
        .l_in(tone_l), .r_in(tone_r),
        .vol(14'd16383), .mute(1'b0), .test_mode(1'b0),
        .sample_l(s_l), .sample_r(s_r)
    );

    // ---- 解码串行流 ----
    reg [15:0] wl = 0, wr = 0;
    reg [3:0]  nl = 0, nr = 0;
    integer    nl_cross = 0, nr_cross = 0;      // 上升零交叉次数
    integer    nl_first = 0, nr_first = 0;      // 第一次交叉的样本序号
    integer    nl_last  = 0, nr_last  = 0;      // 第 41 次交叉的样本序号
    integer    nsamp = 0;
    integer    dbg_cnt = 0;
    reg signed [15:0] prev_l = 0, prev_r = 0;
    reg        started = 0;

    // ⚠ 必须用「拼好的新字」比较：wl 是移位前的旧值，只有 15 位
    wire [15:0] wl_new = {wl[14:0], din};
    wire [15:0] wr_new = {wr[14:0], din};

    always @(posedge bclk) begin
        if (ws) begin          // 手册：WS 高 = 左
            wl <= wl_new;
            if (nl == 4'd15) begin
                nl <= 4'd0;
                if (started) begin
                    if (prev_l < 0 && $signed(wl_new) >= 0) begin
                        if (nl_cross == 0)  nl_first = nsamp;
                        if (nl_cross == 40) nl_last  = nsamp;   // 各声道自己记终点
                        nl_cross <= nl_cross + 1;
                    end
                end
                prev_l <= $signed(wl_new);
                if (dbg_cnt < 6) begin
                    $display("    [dbg] 第 %0d 个左字 = %h (%0d)", nsamp, wl_new, $signed(wl_new));
                    dbg_cnt <= dbg_cnt + 1;
                end
            end else nl <= nl + 4'd1;
        end else begin
            wr <= wr_new;
            if (nr == 4'd15) begin
                nr <= 4'd0;
                if (started) begin
                    if (prev_r < 0 && $signed(wr_new) >= 0) begin
                        if (nr_cross == 0)  nr_first = nsamp;
                        if (nr_cross == 40) nr_last  = nsamp;
                        nr_cross <= nr_cross + 1;
                    end
                end
                prev_r <= $signed(wr_new);
                nsamp  <= nsamp + 1;
                if (nsamp == 2000) started <= 1'b1;
            end else nr <= nr + 4'd1;
        end
    end

    integer errs = 0;
    real    f_l, f_r;

    initial begin
        $display("  频率字自检: INC_L=%0d (期望 38702809)  INC_R=%0d (期望 77405619)",
                 u_tone.INC_L, u_tone.INC_R);
        repeat (4) @(posedge clk);
        rst_n = 1;

        wait (nl_cross >= 41 && nr_cross >= 41);
        @(posedge bclk);

        // 40 个周期跨越的样本数 -> 频率
        f_l = 40.0 * FS_HZ / (nl_last - nl_first);
        f_r = 40.0 * FS_HZ / (nr_last - nr_first);

        $display("  左声道解码频率 = %0.1f Hz  （期望 440）", f_l);
        $display("  右声道解码频率 = %0.1f Hz  （期望 880）", f_r);

        if (f_l < 418.0 || f_l > 462.0) begin
            $display("  FAIL: 左声道频率不对"); errs = errs + 1;
        end
        if (f_r < 836.0 || f_r > 924.0) begin
            $display("  FAIL: 右声道频率不对"); errs = errs + 1;
        end
        // 右/左 比值应接近 2（说明两个声道没有串）
        if ((f_r / f_l) < 1.9 || (f_r / f_l) > 2.1) begin
            $display("  FAIL: 左右声道比值不对（可能串道）"); errs = errs + 1;
        end

        if (errs == 0) $display("PASS  tb_master_chain");
        else           $display("FAIL  tb_master_chain: %0d 个错误", errs);
        $finish;
    end

endmodule
`default_nettype wire
