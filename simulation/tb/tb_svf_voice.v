//============================================================================
//  tb_svf_voice —— Chamberlin SVF 单元测试
//
//  验证点（documents/技术文档.md §五.1.5、硬件实现.md §五.5.2 / §四.2）：
//    1. 参考模型逐样本位精确比对（LP / BP / HP 三种输出各一轮）
//    2. 低通 DC 增益 → 1（阶跃输入最终收敛到输入值）
//    3. 低通频率选择：远低于截止的通过、远高于截止的衰减
//    4. 稳定性：高 Q + f 较大时，长时间冲激响应不得发散/顶到饱和
//    5. 复位后 filter_ic1 / filter_ic2 归零
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_svf_voice;

    localparam real FS = 48000.0;
    integer errors = 0;

    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_async_n = 0;
    wire rst_n_sync;
    reset_sync u_rst (.clk(clk), .rst_async_n(rst_async_n), .rst_n_sync(rst_n_sync));

    reg [3:0] ph = 4'd0;
    always @(posedge clk) ph <= ph + 4'd1;
    wire sample_en = (ph == 4'd0);

    reg  signed [23:0] audio_in;
    reg  [15:0] f_coeff, q_coeff;
    reg  [1:0]  filter_type;

    wire signed [23:0] audio_out;
    wire signed [31:0] filter_ic1, filter_ic2;

    svf_voice u_svf (
        .clk (clk), .rst_n_sync (rst_n_sync), .sample_en (sample_en),
        .slot (2'd0),
        .audio_in (audio_in), .f_coeff (f_coeff), .q_coeff (q_coeff),
        .filter_type (filter_type), .audio_out (audio_out),
        .filter_ic1 (filter_ic1), .filter_ic2 (filter_ic2)
    );

    //---------------- 参考模型（独立重写差分方程） ----------------
    reg signed [31:0] r_low, r_band, r_high;
    reg signed [23:0] r_out;

    function signed [31:0] rsat32;
        input signed [63:0] v;
        begin
            if      (v >  64'sd2147483647) rsat32 = 32'sh7FFFFFFF;
            else if (v < -64'sd2147483648) rsat32 = 32'sh80000000;
            else                           rsat32 = v[31:0];
        end
    endfunction

    task ref_step;
        input signed [23:0] din;
        reg signed [63:0] fe, qe, ie, l64, b64, fb, qb, ln64, hn64, fh, bn64;
        reg signed [63:0] lne, hne;
        reg signed [31:0] ln, hn;
        begin
            fe  = {{48{f_coeff[15]}}, f_coeff};
            qe  = {{48{q_coeff[15]}}, q_coeff};
            ie  = {{40{din[23]}}, din} <<< 8;         // Q1.23 → Q1.31（与 DUT 一致）
            l64 = {{32{r_low[31]}},  r_low};
            b64 = {{32{r_band[31]}}, r_band};

            fb   = (fe * b64) >>> 15;                 // f × band（旧）
            qb   = (qe * b64) >>> 15;                 // q × band（旧）
            ln64 = l64 + fb;
            ln   = rsat32(ln64);                      // low 更新
            lne  = {{32{ln[31]}}, ln};
            hn64 = ie - lne - qb;
            hn   = rsat32(hn64);                      // high 用更新后的 low
            // ⚠ 拼接是无符号的：必须先落到 wire/reg signed 中间量，
            //   否则 >>> 会退化成逻辑右移（DUT 侧也踩过这个坑）
            hne  = {{32{hn[31]}}, hn};
            fh   = (fe * hne) >>> 15;
            bn64 = b64 + fh;
            r_low  = ln;
            r_high = hn;
            r_band = rsat32(bn64);

            case (filter_type)
                2'd0:    r_out = r_low[31:8];
                2'd1:    r_out = r_band[31:8];
                2'd2:    r_out = r_high[31:8];
                default: r_out = r_low[31:8];
            endcase
        end
    endtask

    //---------------- 单步驱动 + 比对 ----------------
    // cmp_err 累计**所有**比对失配，最后统一并入 errors，
    // 避免像早先那样把失配记到局部计数器后忘记统计（等于静默吞掉失败）。
    integer max_err;
    integer cmp_err;
    integer err_before, err_after;
    integer shown;

    task reset_both;
        begin
            rst_async_n = 1'b0;
            repeat (5) @(posedge clk);
            rst_async_n = 1'b1;
            repeat (5) @(posedge clk);
            r_low  = 32'sd0;
            r_band = 32'sd0;
            r_high = 32'sd0;
        end
    endtask

    task run_one;
        input signed [23:0] din;
        begin
            @(negedge clk);
            while (ph !== 4'd0) @(negedge clk);
            audio_in = din;
            ref_step(din);
            //  ⚠ 2026-10-18：SVF 改成 4 级流水（修时序违例），
            //     输出比原来晚 3 拍，采样点随之顺延。数学未变，参考模型无需改。
            repeat (4) @(posedge clk);
            #1;
            if (audio_out !== r_out) begin
                cmp_err = cmp_err + 1;
                if (shown < 6) begin
                    $display("  [比对失败] in=%0d 期望 %0d 实为 %0d", din, r_out, audio_out);
                    shown = shown + 1;
                end
            end
        end
    endtask

    integer i, n;
    reg signed [23:0] din;
    integer amp_in, amp_out, peak_out;
    real    th;
    integer tail;

    initial begin
        rst_async_n = 1'b0;
        audio_in = 24'sd0; f_coeff = 16'd0; q_coeff = 16'd16384; filter_type = 2'd0;
        r_low = 32'sd0; r_band = 32'sd0; r_high = 32'sd0;
        cmp_err = 0; shown = 0;

        repeat (20) @(posedge clk);
        rst_async_n = 1'b1;
        repeat (20) @(posedge clk);

        //================================================================
        // 测试 1：复位后状态归零
        //================================================================
        if (filter_ic1 !== 32'sd0 || filter_ic2 !== 32'sd0) begin
            $display("FAIL svf 复位: filter_ic1=%0d filter_ic2=%0d，应均为 0",
                     filter_ic1, filter_ic2);
            errors = errors + 1;
        end else
            $display("PASS svf 复位: filter_ic1 / filter_ic2 归零");

        //================================================================
        // 测试 2：位精确比对（LP / BP / HP 各一轮，含随机与极值输入）
        //================================================================
        f_coeff = 16'd4287;      // fc≈1000Hz: 2·sin(π·1000/48000)·32768
        q_coeff = 16'd13107;     // Q≈2.5 → q=1/Q≈0.4

        for (n = 0; n < 3; n = n + 1) begin
            filter_type = n[1:0];
            reset_both();
            err_before = cmp_err;
            for (i = 0; i < 3000; i = i + 1) begin
                if (i % 7 == 0) din = 24'sd8388607;              // 正满量程
                else if (i % 7 == 1) din = -24'sd8388608;        // 负满量程
                else if (i % 7 == 2) din = 24'sd0;
                else din = $signed($random) >>> 8;               // 随机
                run_one(din);
            end
            err_after = cmp_err - err_before;
            if (err_after == 0)
                $display("PASS svf 参考比对: filter_type=%0d（%s）3000 个样本逐位一致",
                         n, (n==0)?"LP":(n==1)?"BP":"HP");
            else begin
                $display("FAIL svf 参考比对: filter_type=%0d 有 %0d 处不符", n, err_after);
                errors = errors + 1;
            end
        end
        // 复位重来，进入后续功能测试
        reset_both();

        //================================================================
        // 测试 3：低通 DC 增益 → 1
        //================================================================
        filter_type = 2'd0;
        f_coeff = 16'd4287;
        q_coeff = 16'd16384;
        for (i = 0; i < 4000; i = i + 1) run_one(24'sd2097152);   // 阶跃 0.25 满量程
        tail = audio_out;
        if ((tail > 2097152 + 20972) || (tail < 2097152 - 20972)) begin
            $display("FAIL svf DC 增益: 阶跃稳定后 %0d，期望 ≈ 2097152（±1%%）", tail);
            errors = errors + 1;
        end else
            $display("PASS svf DC 增益: 阶跃稳定后 %0d ≈ 输入 2097152（低通 DC 增益 1）", tail);

        //================================================================
        // 测试 4：频率选择（200 Hz 通过 / 10 kHz 衰减）
        //================================================================
        // 200 Hz 正弦（远低于 1000 Hz 截止）
        reset_both();
        amp_in = 0; peak_out = 0;
        for (i = 0; i < 3000; i = i + 1) begin
            th  = 2.0 * 3.14159265358979 * 200.0 * i / FS;
            din = $rtoi(2097152.0 * $sin(th));
            run_one(din);
            if (i > 1500) begin                         // 跳过建立过程
                if (din > amp_in) amp_in = din;
                if (audio_out > peak_out) peak_out = audio_out;
                if (-audio_out > peak_out) peak_out = -audio_out;
            end
        end
        if (peak_out < amp_in * 90 / 100) begin
            $display("FAIL svf 通带: 200Hz 输入峰值 %0d，低通输出峰值仅 %0d（应≈输入）",
                     amp_in, peak_out);
            errors = errors + 1;
        end else
            $display("PASS svf 通带: 200Hz 输入峰值 %0d → 输出峰值 %0d（通过）", amp_in, peak_out);

        // 10 kHz 正弦（远高于 1000 Hz 截止）
        reset_both();
        amp_in = 0; peak_out = 0;
        for (i = 0; i < 3000; i = i + 1) begin
            th  = 2.0 * 3.14159265358979 * 10000.0 * i / FS;
            din = $rtoi(2097152.0 * $sin(th));
            run_one(din);
            if (i > 1500) begin
                if (din > amp_in) amp_in = din;
                if (audio_out > peak_out) peak_out = audio_out;
                if (-audio_out > peak_out) peak_out = -audio_out;
            end
        end
        if (peak_out > amp_in * 25 / 100) begin
            $display("FAIL svf 阻带: 10kHz 输入峰值 %0d，低通输出峰值 %0d（衰减应 >12dB）",
                     amp_in, peak_out);
            errors = errors + 1;
        end else
            $display("PASS svf 阻带: 10kHz 输入峰值 %0d → 输出峰值 %0d（衰减 %.1f dB）",
                     amp_in, peak_out,
                     20.0 * $log10(peak_out / (amp_in + 1.0)));

        //================================================================
        // 测试 5：稳定性 —— 高 Q + f 较大，冲激响应不得发散
        //================================================================
        filter_type = 2'd1;                       // 带通，最容易看出振荡
        f_coeff = 16'd16384;                      // f ≈ 0.5
        q_coeff = 16'd1638;                       // q ≈ 0.05（Q≈20，高 Q）
        reset_both();
        peak_out = 0;
        for (i = 0; i < 20000; i = i + 1) begin
            din = (i == 0) ? 24'sd2097152 : 24'sd0;   // 单次冲激
            run_one(din);
            if (i > 100) begin
                if (audio_out > peak_out) peak_out = audio_out;
                if (-audio_out > peak_out) peak_out = -audio_out;
            end
        end
        // 冲激响应的包络应逐周期衰减；只要不顶到 24 位饱和就算稳定
        if (peak_out >= 8388600) begin
            $display("FAIL svf 稳定性: 高Q 冲激响应顶到饱和（峰值 %0d），滤波器发散", peak_out);
            errors = errors + 1;
        end else
            $display("PASS svf 稳定性: 高Q(f=0.5,q=0.05) 冲激响应峰值 %0d，未发散", peak_out);

        //================================================================
        // 收尾：把全程累计的比对失配并入 errors（不再静默吞掉）
        //================================================================
        errors = errors + cmp_err;
        if (errors == 0) $display("PASS  tb_svf_voice （全程参考比对失配 %0d 处）", cmp_err);
        else             $display("FAIL  tb_svf_voice: %0d 项", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL tb_svf_voice: 仿真超时");
        $finish;
    end

endmodule

`default_nettype wire
