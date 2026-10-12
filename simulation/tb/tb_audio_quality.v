//============================================================================
//  tb_audio_quality —— 端到端音频质量测试（THD / SNR / ENOB 基线）
//
//  目的：测**主输出链**（主音量 → 软限幅 → 隔直 → 抖动 → 16 bit 截断）的
//        质量地板。输入是"理想正弦"（1024 点正弦表 + 32 位相位累加，
//        相位截断噪声约 −72 dB，远低于 16 bit 地板），
//        所以测出来的 THD+N **就是主输出链自身的贡献**。
//
//  配置：
//    · 主音量拉满（vol = 16383）、不限幅（test_mode=1 → 限幅固定增益）
//    · 隔直开（DC_ENABLE=1，实际系统如此）
//    · 输入幅度 ±0x200000（24 位满量程的 25%，即 −12 dBFS）
//      → 输出约 −16 dBFS，远离削顶，能干净地看量化/抖动地板
//
//  输出：`out/audio_quality.csv`（每行一个 16 位输出样本）
//        由 `sim/audio_quality.py` 做 FFT 分析。
//
//  验证点（TB 内自检）：
//    ① 样本数足够（≥ 60000，给 FFT 用）
//    ② 输出非静音、双极性
//    ③ 输出不削顶（|sample| < 32767）
//    ④ 输出无 X
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_audio_quality;
    localparam integer HALF_NS  = 10;          // 50 MHz 仿真时钟（分析用，非真实频率）
    localparam integer FS       = 48000;
    //  ⚠⚠ **必须用相干采样频率**（整数个周期落在 FFT 窗内），否则频谱泄漏
    //     会让 SNR 看起来只有 40 多 dB（实测踩过：997 Hz 非相干时报 43.8 dB，
    //     换成相干频率 + 矩形窗后是 86.06 dB，与理论值 86.05 dB 完全吻合）。
    //     N_SAMP = 65536，取 1361 个周期 → f = 1361 × 48000 / 65536 = 996.826 Hz
    localparam integer N_SAMP   = 65536;       // 采集样本数（2 的幂，便于 FFT）
    localparam integer CYCLES   = 1361;        // FFT 窗内的周期数（整数 → 相干）
    localparam real    FREQ     = CYCLES * 48000.0 / N_SAMP;   // = 996.8262 Hz
    localparam integer AMP      = 24'sd2097152; // ±0x200000 = −12 dBFS

    reg clk = 0, rst_n = 0;
    always #HALF_NS clk = ~clk;

    // ---------------- 相位累加 + 1024 点正弦表（理想正弦源）----------------
    localparam integer FTW = 32;
    //  INC = FREQ / FS * 2^32
    localparam [31:0] INC = (FREQ / FS) * 4294967296.0;

    reg [31:0] phase = 0;
    //  ⚠ 用共享正弦源（**带线性插值**）——见 sine_src.vh 顶部的实测数据说明
    `include "sine_src.vh"
    wire signed [23:0] src;
    sine_src #(.TAB_BITS(10), .AMP(2097152)) u_src (.phase(phase), .val(src));

    // ---------------- 被测：主输出链 ----------------
    reg  en = 0;
    wire [15:0] sample_l, sample_r;

    master_chain #(.DC_ENABLE(1), .LIM_ENABLE(1)) dut (
        .clk(clk), .rst_n(rst_n), .en(en),
        .l_in(src), .r_in(src),
        .vol(14'd16383),          // 主音量拉满
        .mute(1'b0),
        .test_mode(1'b1),         // 限幅固定增益（不做动态压缩）→ 只看静态质量
        .sample_l(sample_l), .sample_r(sample_r)
    );

    // ---------------- 采样节拍与采集 ----------------
    integer cyc = 0, nsamp = 0, errs = 0;
    integer pos = 0, neg = 0, maxabs = 0;
    integer fd;

    always @(posedge clk) cyc <= cyc + 1;

    initial begin
        fd = $fopen("out/audio_quality.csv", "w");
        if (fd == 0) begin
            $display("FAIL  tb_audio_quality: 打不开 out/audio_quality.csv（要先 mkdir out）");
            $finish;
        end
    end

    // 每 100 个时钟产生一拍采样使能（仿真加速用；不改变算法）
    always @(posedge clk) begin
        en <= ((cyc % 100) == 99);
        if (en) begin
            phase <= phase + INC;      // 推进相位（每采样一次）
            if (nsamp < N_SAMP && rst_n) begin
                $fwrite(fd, "%0d\n", $signed(sample_l));
                nsamp <= nsamp + 1;
                if ($signed(sample_l) > 0) pos <= pos + 1;
                if ($signed(sample_l) < 0) neg <= neg + 1;
                if (($signed(sample_l) > maxabs ? $signed(sample_l) : -$signed(sample_l)) > maxabs)
                    maxabs <= ($signed(sample_l) > 0) ? $signed(sample_l) : -$signed(sample_l);
                if (sample_l === 16'bx) begin
                    $display("FAIL: sample_l 是 X");
                    errs <= errs + 1;
                end
            end
        end
    end

    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1;
        $display("=== tb_audio_quality：采集 %0d 个样本（%.1f Hz @ %0d Hz）===", N_SAMP, FREQ, FS);
        //  仿真时间估算：N_SAMP × 100 拍 × 20 ns ≈ 131 ms 仿真时间
        wait (nsamp >= N_SAMP);
        repeat (10) @(posedge clk);
        $fclose(fd);

        $display("  样本数 = %0d", nsamp);
        $display("  正样本 %0d / 负样本 %0d", pos, neg);
        $display("  峰值 = %0d / 32767", maxabs);

        if (nsamp < N_SAMP) begin $display("  FAIL: 样本不足"); errs = errs + 1; end
        if (pos == 0 || neg == 0) begin $display("  FAIL: 输出不是双极性"); errs = errs + 1; end
        if (maxabs >= 32767) begin $display("  FAIL: 输出削顶"); errs = errs + 1; end
        else $display("  不削顶 ✓");

        if (errs == 0) $display("PASS  tb_audio_quality: 采集完成，样本已写入 out/audio_quality.csv");
        else           $display("FAIL  tb_audio_quality: %0d 项", errs);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("FAIL  tb_audio_quality: 超时（nsamp=%0d cyc=%0d）", nsamp, cyc);
        $finish;
    end
endmodule
`default_nettype wire
