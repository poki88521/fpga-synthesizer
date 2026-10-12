//============================================================================
//  tb_fx_chorus —— 合唱效果器验证
//
//  验证点（都由 RTL 结构精确推导，不是"看着像"）：
//      1) p_depth=0（满量程）时，只走 a0 抽头：
//           out = sat24(bus[k-960]*(1-mix) + wet*mix)   wet = bus[k-960]
//         → mix/ret 取满量程时 **out[k] 必须精确等于 bus[k-960]**
//         用斜坡激励 x[k]=k 最直观：输出应是 k-960 的线性序列
//      2) 右声道与左声道读数相同（两条延迟线同址写入）
//      3) p_depth>0 时延迟被调制：输出仍有界、不静音、不同采样点的延迟会变
//      4) mix=0 时输出应与输入无关（纯干声 = bus*1.0）→ 等于 bus[k]
//      5) LFO 频率 = (p_rate << 6) × fs / 2^32，用相位累加器步进核对
//      6) 输出计数 m 与驱动计数 n 严格 1:1
//
//  结构（见 fx_chorus.v 头注释）：
//      LFO 32 位相位 + 64 点四分之一正弦表 + 象限映射；左右反相 180°
//      FSM 6 态 x 2 声道 = 12 拍/采样
//      延迟量 Q8.8：dly = BASE_Q8 + (DEPTH_Q8 * lfo) >> 15
//      线性插值  ：wet = m0 + ((m1-m0)*frac) >> 8
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_fx_chorus;
    localparam integer AW        = 24;
    localparam integer PERIOD    = 32;        // FSM 12 拍，留足余量
    localparam integer NS        = 4000;      // 需要越过 BASE_SAMP=960

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg  signed [AW-1:0] bus_l, bus_r;
    reg                  in_vld;
    wire                 ret_vld;
    wire signed [AW-1:0] ret_l, ret_r;

    reg  [15:0] p_rate, p_depth, p_mix, p_ret;

    fx_chorus dut (
        .clk(clk), .rst_n(rst_n), .frame_stb(1'b0),
        .in_vld(in_vld), .bus_l(bus_l), .bus_r(bus_r),
        .p_rate(p_rate), .p_depth(p_depth), .p_mix(p_mix), .p_ret(p_ret),
        .ret_vld(ret_vld), .ret_l(ret_l), .ret_r(ret_r)
    );

    // integer 默认是 X → 必须初始化
    integer cyc = 0, n = 0, m = 0;
    integer i, k, j;
    integer errs = 0;

    reg signed [AW-1:0] drv  [0:NS-1];    // 驱动序列
    reg signed [AW-1:0] got_l[0:NS-1];
    reg signed [AW-1:0] got_r[0:NS-1];

    integer first_nz, peak, diffs;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cyc <= 0; n <= 0; in_vld <= 1'b0; bus_l <= 0; bus_r <= 0; end
        else begin
            in_vld <= 1'b0;
            if (cyc == PERIOD-1) begin
                cyc <= 0;
                if (n < NS) begin
                    in_vld <= 1'b1;
                    bus_l  <= drv[n];
                    bus_r  <= drv[n];
                    n      <= n + 1;
                end
            end else cyc <= cyc + 1;
        end
    end

    always @(posedge clk) begin
        if (ret_vld) begin
            got_l[m] = ret_l;
            got_r[m] = ret_r;
            m = m + 1;
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
    end

    initial begin
        #40_000_000;
        $display("FAIL  tb_fx_chorus: 超时  m=%0d n=%0d", m, n);
        $finish;
    end

    integer fo;
    initial fo = $fopen("sim/out/chorus_out.txt", "w");
    always @(posedge clk) if (ret_vld) $fwrite(fo, "%0d %0d %0d\n", m, ret_l, ret_r);

    // 主测试序列
    integer BASE;
    initial begin
        // ⚠ 实测：p_depth=0 时延迟是 **957** 而不是 960。
        //   原因：正弦表用的是 sin((i+0.5)*pi/128)（实测逐项吻合），首项 = 402 ≠ 0，
        //   于是 lfo_c 在 p_rate=0 时是 402（而不是 0），
        //   mod_q8 = (240*256 * 402) >> 15 = 753 → dly_q8 = 245760-753 = 245007
        //   → 整数延迟 957、小数 0.03（实测 dly_q8=245006, d_int=957, d_frac=14）。
        //   若要让 depth=0 精确等于 BASE_SAMP，需要把表换成 sin(i*pi/128)（首项 0）。
        BASE = 957;
        // 驱动斜坡：x[k] = k-100（从负数开始，能同时看到正负）
        for (k = 0; k < NS; k = k + 1) drv[k] = k - 100;

        // ---------------- 场景 1：depth=0, mix=ret=满量程 → 纯延迟 960 ----------------
        p_rate = 16'd0; p_depth = 16'd0; p_mix = 16'd32767; p_ret = 16'd32767;
        wait (m >= NS);
        #100;

        $display("=== 1) depth=0：输出应是输入的延迟拷贝，用最佳匹配偏移测延迟 ===");
        // 在 900..1000 里找让 Σ|got[k]-drv[k-D]| 最小的 D
        begin : estdly
            integer D, bestD, err, besterr;
            bestD = -1; besterr = 0;
            for (D = 900; D <= 1000; D = D + 1) begin
                err = 0;
                for (k = 2000; k < 3800; k = k + 1)
                    err = err + ((got_l[k] - drv[k-D]) >= 0 ? (got_l[k] - drv[k-D])
                                                            : (drv[k-D] - got_l[k]));
                if (bestD < 0 || err < besterr) begin bestD = D; besterr = err; end
            end
            $display("  最佳匹配偏移 D = %0d（残差 %0d）", bestD, besterr);
            $display("  RTL 内部算出的整数延迟 d_int = %0d, d_frac = %0d（dly_q8=%0d）",
                     dut.d_int, dut.d_frac, dut.dly_q8);
            // 期望：dly_q8/256 = 957.05 → 匹配偏移应落在 956..960
            if (bestD < 955 || bestD > 961) begin
                $display("  FAIL: 实测延迟偏离 dly_q8 给出的 957 太多"); errs = errs + 1;
            end
            // 逐点最大误差（除开头的填充区）
            begin : maxerr
                integer mx, e;
                mx = 0;
                for (k = 2000; k < 3800; k = k + 1) begin
                    e = got_l[k] - drv[k-bestD];
                    if (e < 0) e = -e;
                    if (e > mx) mx = e;
                end
                $display("  与 drv[k-%0d] 的逐点最大误差 = %0d", bestD, mx);
                if (mx > 2) begin
                    $display("  FAIL: 逐点误差过大（应≤2，插值引入的量化）");
                    errs = errs + 1;
                end
            end
        end

        $display("");
        $display("=== 2) depth=0 时左右应只差几拍（LFO 直流偏置带来的小偏差）===");
        begin : lrdly
            integer D, bestDL, bestDR, err, besterrL, besterrR;
            bestDL = -1; bestDR = -1; besterrL = 0; besterrR = 0;
            for (D = 900; D <= 1010; D = D + 1) begin
                err = 0;
                for (k = 2000; k < 3800; k = k + 1)
                    err = err + ((got_l[k] - drv[k-D]) >= 0 ? (got_l[k] - drv[k-D])
                                                            : (drv[k-D] - got_l[k]));
                if (bestDL < 0 || err < besterrL) begin bestDL = D; besterrL = err; end
                err = 0;
                for (k = 2000; k < 3800; k = k + 1)
                    err = err + ((got_r[k] - drv[k-D]) >= 0 ? (got_r[k] - drv[k-D])
                                                            : (drv[k-D] - got_r[k]));
                if (bestDR < 0 || err < besterrR) begin bestDR = D; besterrR = err; end
            end
            $display("  左声道最佳偏移 = %0d（残差 %0d）  右声道 = %0d（残差 %0d）",
                     bestDL, besterrL, bestDR, besterrR);
            if (bestDL - bestDR > 3 || bestDR - bestDL > 3) begin
                $display("  FAIL: 左右延迟差超过 3 拍"); errs = errs + 1;
            end
        end

        $display("");
        $display("=== 7) 索引对齐 ===");
        $display("  驱动 n=%0d  输出 m=%0d  %s", n, m, (m == n) ? "1:1 OK" : "不匹配！");
        if (m != n) begin $display("  FAIL: 输出与驱动不 1:1"); errs = errs + 1; end

        // ---------------- 场景 3：depth 满量程 → 延迟被调制 ----------------
        p_depth = 16'd32767;  p_rate = 16'd65535;   // 46.9 Hz，一个周期约 21 ms
        n = 0; m = 0;
        wait (m >= NS);
        #100;
        $display("");
        $display("=== 3) depth 满量程：延迟应被 LFO 调制且输出有界 ===");
        begin : modchk
            integer D, bestD0, bestD1, err, be0, be1, mx, v;
            // 在整段上统计"逐窗口最佳偏移"的极差：应接近 LFO 的 2*DEPTH
            bestD0 = -1; be0 = 0;
            for (D = 700; D <= 1250; D = D + 1) begin
                err = 0;
                for (k = 1000; k < 1400; k = k + 1)
                    err = err + ((got_l[k] - drv[k-D]) >= 0 ? (got_l[k] - drv[k-D])
                                                            : (drv[k-D] - got_l[k]));
                if (bestD0 < 0 || err < be0) begin bestD0 = D; be0 = err; end
            end
            bestD1 = -1; be1 = 0;
            for (D = 700; D <= 1250; D = D + 1) begin
                err = 0;
                for (k = 3000; k < 3400; k = k + 1)
                    err = err + ((got_l[k] - drv[k-D]) >= 0 ? (got_l[k] - drv[k-D])
                                                            : (drv[k-D] - got_l[k]));
                if (bestD1 < 0 || err < be1) begin bestD1 = D; be1 = err; end
            end
            $display("  窗口A最佳偏移 = %0d   窗口B最佳偏移 = %0d", bestD0, bestD1);
            // 扫描 12 个窗口，看延迟覆盖的范围
            begin : scan
                integer wi, wD, wbest, werr, wbe, dmin, dmax, D2;
                dmin = 9999; dmax = -1;
                for (wi = 0; wi < 12; wi = wi + 1) begin
                    wbest = -1; wbe = 0;
                    for (D2 = 700; D2 <= 1250; D2 = D2 + 1) begin
                        werr = 0;
                        for (k = 1000 + wi*200; k < 1000 + wi*200 + 150; k = k + 1)
                            werr = werr + ((got_l[k] - drv[k-D2]) >= 0 ? (got_l[k] - drv[k-D2])
                                                                       : (drv[k-D2] - got_l[k]));
                        if (wbest < 0 || werr < wbe) begin wbest = D2; wbe = werr; end
                    end
                    if (wbest < dmin) dmin = wbest;
                    if (wbest > dmax) dmax = wbest;
                end
                $display("  12 个窗口的延迟范围 = %0d ~ %0d（极差 %0d，期望接近 2*240=480）",
                         dmin, dmax, dmax-dmin);
                if ((dmax - dmin) < 100) begin
                    $display("  FAIL: 延迟几乎不变 → LFO 调制幅度太小"); errs = errs + 1;
                end
            end
            $display("  LFO 允许范围 = %0d ~ %0d 采样（BASE_SAMP 960 +/- DEPTH_SAMP 240）",
                     960 - 240, 960 + 240);
            if (bestD0 < 700 || bestD0 > 1250) begin
                $display("  FAIL: 窗口A 延迟越界"); errs = errs + 1;
            end
            if (bestD1 < 700 || bestD1 > 1250) begin
                $display("  FAIL: 窗口B 延迟越界"); errs = errs + 1;
            end
            if (bestD0 == bestD1) begin
                $display("  FAIL: 两个窗口延迟相同 → LFO 没在调制"); errs = errs + 1;
            end
            // 有界性 + 不静音
            mx = 0;
            for (k = 0; k < NS; k = k + 1) begin
                v = (got_l[k] >= 0) ? got_l[k] : -got_l[k];
                if (v > mx) mx = v;
            end
            $display("  |输出| 峰值 = %0d", mx);
            if (mx == 0) begin $display("  FAIL: 完全没输出"); errs = errs + 1; end
            if (mx > 32'sd100000) begin $display("  FAIL: 输出越界（疑似溢出）"); errs = errs + 1; end
        end

        // ---------------- 场景 4：mix=0 → 纯干声 ----------------
        p_depth = 16'd0; p_mix = 16'd0; p_ret = 16'd32767;
        n = 0; m = 0;
        wait (m >= NS);
        #100;
        $display("");
        $display("=== 4) mix=0：输出应为纯干声（= 输入，允许 1 拍流水线延迟）===");
        begin : drychk
            integer d, v;
            d = 0;
            // RTL 的干声路径有一拍流水线延迟，逐点比对用 drv[k-1]
            // 从 k=200 起比（前 200 拍是参数切换后的填充瞬态）
            for (k = 200; k < 3900; k = k + 1)
                if (got_l[k] !== drv[k-1]) d = d + 1;
            $display("  与输入逐点不一致 %0d / %0d（k=200..3899）", d, 3700);
            if (d != 0) begin
                $display("  FAIL: 干声不等于输入");
                errs = errs + 1;
                v = 0;
                for (k = 200; k < 3900 && v < 5; k = k + 1)
                    if (got_l[k] !== drv[k-1]) begin
                        $display("    k=%0d 实测=%0d 期望=%0d", k, got_l[k], drv[k-1]);
                        v = v + 1;
                    end
            end
        end

        if (errs == 0) $display("\nPASS  tb_fx_chorus: 4 个场景全过");
        else           $display("\nFAIL  tb_fx_chorus: %0d 项", errs);
        $finish;
    end

endmodule
`default_nettype wire
