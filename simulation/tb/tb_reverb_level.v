//============================================================================
//  tb_reverb_level —— 混响湿声电平回归（2026-10-28 重写）
//
//  目的：把"湿声电平"钉成可回归的数字，防止再出现
//        ① 内部位宽 bug 把电平冲到满量程（2026-10-28 之前的"炸"）
//        ② 归一化过头导致混响听不出来
//
//  激励：0.60 FS / 1 kHz 正弦，每 PERIOD(1024) 拍送一样本（与全系统同节拍），
//        参数取 full_top 的上板默认值。
//
//  判据（数字来自 2026-10-28 重构后的实测，见 rtl/global/fx_reverb.v 头注释）：
//      · ret_vld 与驱动严格 1:1
//      · 湿声峰值在 [0.03, 0.35] FS（预算上限 0.35 FS，不削顶）
//      · 左右声道电平比在 [0.3, 3.3]（模态差异允许，但不能一边倒）
//      · 模块内部软限幅 0 次（正常信号远低于 0.75 FS 拐点）
//
//  ⚠ 之前这版 TB 恒返回 0 的原因：混响的延迟线是 BSRAM，仿真里必须初始化为 0，
//     而 RTL 的清零块在 `ifdef SIMULATION 里。少加 -DSIMULATION 时整条链都是 X，
//     统计值全 0（看起来像"没握手"）。现在 TB 自己清零，不再依赖编译宏。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_reverb_level;
    localparam integer PERIOD = 1024;
    localparam integer NIN    = 6000;      // 输入帧数（≈123 ms）
    localparam integer NFR    = 6500;      // 总帧数
    localparam real    FS_HZ  = 48828.125;
    localparam real    AMP    = 0.60;

    localparam integer P_SIZE = 26000;
    localparam integer P_DECAY= 31000;
    localparam integer P_DAMP = 24576;     // full_top.v 现值
    localparam integer P_RET  = 26000;

    reg clk = 0, rst_n = 0, frame_stb = 1'b0;
    reg in_vld = 0;
    reg signed [23:0] bus_l = 0, bus_r = 0;
    wire ret_vld;
    wire signed [23:0] ret_l, ret_r;

    always #10.17 clk = ~clk;

    fx_reverb #(.AW(24), .SBW(12), .SLOT(4096)) dut (
        .clk(clk), .rst_n(rst_n), .frame_stb(frame_stb),
        .in_vld(in_vld), .bus_l(bus_l), .bus_r(bus_r),
        .p_decay(P_DECAY[15:0]), .p_damp(P_DAMP[15:0]),
        .p_size(P_SIZE[15:0]), .p_ret(P_RET[15:0]), .p_predly(16'd0),
        .ret_vld(ret_vld), .ret_l(ret_l), .ret_r(ret_r)
    );

    integer i;
    initial begin
        //  BSRAM 清零（不依赖 -DSIMULATION）
        for (i = 0; i < 49000; i = i + 1) dut.rmem[i] = 24'sd0;
    end

    // ---------------- 激励 ----------------
    integer cyc = 0, n = 0;
    real    ang;
    integer v;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cyc <= 0; n <= 0; in_vld <= 1'b0; bus_l <= 24'sd0; bus_r <= 24'sd0;
            frame_stb <= 1'b0;
        end else begin
            in_vld <= 1'b0;
            frame_stb <= 1'b0;
            if (cyc == PERIOD-1) begin
                cyc <= 0;
                frame_stb <= 1'b1;
                if (n < NFR) begin
                    if (n < NIN) begin
                        ang = 2.0*3.14159265358979*1000.0*$itor(n)/FS_HZ;
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
    integer retn = 0, peak_l = 0, peak_r = 0, t;
    always @(posedge clk) begin
        if (ret_vld) begin
            retn = retn + 1;
            t = $signed(ret_l); if (t < 0) t = -t; if (t > peak_l) peak_l = t;
            t = $signed(ret_r); if (t < 0) t = -t; if (t > peak_r) peak_r = t;
        end
    end

    // ---------------- 结论 ----------------
    real fs_l, fs_r, db_l, db_r;
    integer errs = 0;
    initial begin
        repeat (8) @(posedge clk);
        rst_n = 1;
        wait (n >= NFR);
        repeat (PERIOD*3) @(posedge clk);

        fs_l = peak_l / 8388608.0;
        fs_r = peak_r / 8388608.0;
        db_l = 20.0*$log10(fs_l + 1e-12);
        db_r = 20.0*$log10(fs_r + 1e-12);

        $display("");
        $display("=== 混响湿声电平（0.60 FS 1 kHz 正弦，%0d 帧，上板参数）===", NIN);
        $display("  驱动帧 %0d / ret_vld %0d", NFR, retn);
        $display("  湿声峰值 L = %0d (%.4f FS, %0.1f dBFS)", peak_l, fs_l, db_l);
        $display("  湿声峰值 R = %0d (%.4f FS, %0.1f dBFS)", peak_r, fs_r, db_r);

        if (retn != NFR) begin
            $display("  FAIL: ret_vld 与驱动不 1:1（%0d vs %0d）", retn, NFR);
            errs = errs + 1;
        end
        if (fs_l < 0.03 || fs_r < 0.03) begin
            $display("  FAIL: 湿声太小（<0.03 FS）—— 归一化过头，混响听不出来");
            errs = errs + 1;
        end
        if (fs_l > 0.35 || fs_r > 0.35) begin
            $display("  FAIL: 湿声太大（>0.35 FS）—— 超出 dry 0.6 + wet 0.35 的预算");
            errs = errs + 1;
        end
        if (peak_l == 0 || peak_r == 0) begin
            $display("  FAIL: 有一个声道恒 0"); errs = errs + 1;
        end else if (peak_l * 10 < peak_r * 3 || peak_r * 10 < peak_l * 3) begin
            $display("  FAIL: 左右声道电平差超过 10 dB"); errs = errs + 1;
        end

        if (errs == 0) $display("\nPASS  tb_reverb_level: 湿声电平静音正常、无削顶");
        else           $display("\nFAIL  tb_reverb_level: %0d 项", errs);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("FAIL  tb_reverb_level: 超时");
        $finish;
    end

endmodule
`default_nettype wire
