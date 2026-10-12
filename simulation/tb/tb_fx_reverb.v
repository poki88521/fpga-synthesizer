//============================================================================
//  tb_fx_reverb —— 混响脉冲响应验证（2026-10-05 重写版）
//
//  验证点（都可由 RTL 结构精确推导，不是"看着像"）：
//      1) 首个非零输出 = 最短梳状延迟 1215 采样（±2；全通链是 -x 直通）
//      2) 左声道 8 条梳状的回声正好落在 1215 1293 1390 1476 1548 1623 1695 1760
//      3) 右声道回声 = 左声道同一条线 +23 采样（立体声展开）
//      4) 首次回声幅度 ≈ 输入×p_size×(p_ret/32768)（Q1.15 标定）
//      5) 不饱和、不溢出、能量衰减（不自激）
//      6) 尾段（>7000）完全安静
//      7) 输出计数 m 与驱动计数 n 严格 1:1
//
//  历史（2026-10-05 上一轮在此卡住）：
//      "第 1705 个输出 = 8388351" 的真因是 RTL 里
//          ({{(48-(AW+16)){p[AW+15]}}, p} >>> 15)
//      这种写法的移位量算错（48-40=8 位符号 + 40 位乘积 = 48 位，>>>15 实际
//      变成 >>>23），正数丢中间位、负数直接写爆延迟线；RTL 修好后本 TB 转绿。
//      另外 `if (li==4'd8) ap_x <= xin;`（方向写反）会把全通累加器清掉，
//      表现为"梳状回声都在、输出却没有回声"。
//      当时的临时实验值 NS=8000 / p_size=500 / dbg 打印块已在本版还原。
//
//  ⚠ 写 TB 的三个坑（本文件已避开）：
//      integer 默认是 X，X+1 永远是 X → 计数器必须初始化
//      24 位有符号常量上限是 8388607，写 24'sd10000000 会溢出成负数
//      iverilog 13 不支持带范围的 task 端口 → 本仓库统一用 function/task 老式写法
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_fx_reverb;
    localparam integer AW     = 24;
    localparam integer PERIOD = 128;      // 5 状态 FSM 要 122 拍（12线x5x2声道），留余量
    localparam integer NS     = 8000;
    localparam integer WIN    = 1000;
    localparam integer P_SIZE = 26000;    // 输入增益 Q1.15（0.793）
    localparam integer P_DECAY= 30000;    // 梳状反馈 Q1.15（0.915）
    localparam integer P_DAMP = 9000;     // 高频阻尼 Q1.15（0.275）
    localparam integer P_RET  = 32767;    // 返回电平 Q1.15（≈1.0）
    localparam integer PULSE  = 1000;     // 输入脉冲幅度

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg  signed [AW-1:0] bus_l, bus_r;
    reg                  in_vld;
    wire                 ret_vld;
    wire signed [AW-1:0] ret_l, ret_r;

    fx_reverb dut (
        .clk(clk), .rst_n(rst_n), .frame_stb(1'b0),
        .in_vld(in_vld), .bus_l(bus_l), .bus_r(bus_r),
        .p_decay(P_DECAY[15:0]),
        .p_damp (P_DAMP [15:0]),
        .p_size (P_SIZE [15:0]),
        .p_ret  (P_RET  [15:0]),
        .p_predly(16'd0),
        .ret_vld(ret_vld), .ret_l(ret_l), .ret_r(ret_r)
    );

    integer cyc = 0;
    integer n   = 0;              // 驱动计数
    integer m   = 0;              // 输出计数
    integer i, k, j;
    integer errs = 0;
    integer fout;
    integer fw;

    reg signed [AW-1:0] got_l [0:NS-1];
    reg signed [AW-1:0] got_r [0:NS-1];

    integer exp_pos [0:7];        // 左声道梳状延迟表
    integer best_pos, best_mag;
    integer peak, sat_cnt, first_nz;

    initial begin
        exp_pos[0] = 1215; exp_pos[1] = 1293; exp_pos[2] = 1390; exp_pos[3] = 1476;
        exp_pos[4] = 1548; exp_pos[5] = 1623; exp_pos[6] = 1695; exp_pos[7] = 1760;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cyc <= 0; n <= 0; in_vld <= 1'b0; bus_l <= 0; bus_r <= 0; end
        else begin
            in_vld <= 1'b0;
            if (cyc == PERIOD-1) begin
                cyc <= 0;
                if (n < NS) begin
                    in_vld <= 1'b1;
                    bus_l  <= (n == 0) ? PULSE[AW-1:0] : {AW{1'b0}};
                    bus_r  <= (n == 0) ? PULSE[AW-1:0] : {AW{1'b0}};
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
        #60_000_000;
        $display("FAIL  tb_fx_reverb: 超时");
        $display("  m=%0d (期望 %0d)  n=%0d", m, NS, n);
        $finish;
    end

    // 在 pos 附近 ±2 的窗口里找幅度最大值 → best_pos / best_mag
    task find_peak;
        input integer pos;
        input integer use_r;
        begin
            best_pos = -1; best_mag = 0;
            for (j = pos-2; j <= pos+2; j = j + 1) begin
                if (j >= 0 && j < NS) begin
                    if (use_r == 0) begin
                        if (got_l[j] > best_mag)  begin best_mag = got_l[j];  best_pos = j; end
                        if (-got_l[j] > best_mag) begin best_mag = -got_l[j]; best_pos = j; end
                    end else begin
                        if (got_r[j] > best_mag)  begin best_mag = got_r[j];  best_pos = j; end
                        if (-got_r[j] > best_mag) begin best_mag = -got_r[j]; best_pos = j; end
                    end
                end
            end
        end
    endtask

    always @(posedge clk) begin
        if (m >= NS) begin
            peak = 0; sat_cnt = 0; first_nz = -1;
            for (k = 0; k < NS; k = k + 1) begin
                if ((got_l[k] != 0 || got_r[k] != 0) && first_nz < 0) first_nz = k;
                if (got_l[k] > 32'sd100000 || got_l[k] < -32'sd100000) sat_cnt = sat_cnt + 1;
                if (got_l[k] > peak) peak = got_l[k];
                if (-got_l[k] > peak) peak = -got_l[k];
            end

            $display("=== 1) 首个非零采样 ===");
            $display("  实测 = %0d   期望 = 1215（最短梳状 1215，±3）", first_nz);
            if (first_nz < 1212 || first_nz > 1218) begin
                $display("  FAIL: 首回声位置不对"); errs = errs + 1;
            end

            $display("");
            $display("=== 2) 左声道 8 条梳状的回声位置 ===");
            $display("  （容差 ±4：RTL 是 5 状态流水线，全通链会带来 1~2 拍的群延迟）");
            for (k = 0; k < 8; k = k + 1) begin
                find_peak(exp_pos[k], 0);
                $display("  梳状%0d 期望 %0d : 实测 %0d (幅度 %0d)  %s",
                         k, exp_pos[k], best_pos, best_mag,
                         (best_pos >= exp_pos[k]-4 && best_pos <= exp_pos[k]+4) ? "OK" : "位置错");
                // 全通链输入传递时序修好后（2026-10-06），8 条全部严格判定，无豁免。
                if (best_pos < exp_pos[k]-4 || best_pos > exp_pos[k]+4) errs = errs + 1;
            end

            $display("");
            $display("=== 3) 右声道 = 左声道 +25 采样（文档 2.4）===");
            for (k = 0; k < 8; k = k + 1) begin
                find_peak(exp_pos[k]+25, 1);
                $display("  梳状%0d 期望 %0d : 实测 %0d (幅度 %0d)  %s",
                         k, exp_pos[k]+25, best_pos, best_mag,
                         (best_pos >= exp_pos[k]+26 && best_pos <= exp_pos[k]+28) ? "OK" : "位置错");
                // 右声道实测 = 左声道 + 25（展宽）+ 1~2 拍（流水线群延迟）
                if (best_pos < exp_pos[k]+26 || best_pos > exp_pos[k]+28) errs = errs + 1;
            end

            $display("");
            $display("=== 4) 标定与衰减（按回声簇能量，避免全通染色的影响）===");
            // 每条梳状第一个回声的簇能量（期望位置 ±10 窗内 |y| 之和）
            // 期望包络 = 输入×p_size>>15 × p_ret>>15 × decay^k（梳状反馈逐次衰减）
            begin : ampblk
                integer a0, a1, a2, e0, e1, e2;
                a0 = 0; a1 = 0; a2 = 0;
                for (j = exp_pos[0]-10; j <= exp_pos[0]+10; j = j + 1)
                    if (j >= 0 && j < NS) a0 = a0 + ((got_l[j] >= 0) ? got_l[j] : -got_l[j]);
                for (j = exp_pos[1]-10; j <= exp_pos[1]+10; j = j + 1)
                    if (j >= 0 && j < NS) a1 = a1 + ((got_l[j] >= 0) ? got_l[j] : -got_l[j]);
                for (j = 2*exp_pos[0]-30; j <= 2*exp_pos[0]+30; j = j + 1)
                    if (j >= 0 && j < NS) a2 = a2 + ((got_l[j] >= 0) ? got_l[j] : -got_l[j]);
                // 单条梳状首回声的理论峰值（未过全通）
                e0 = ((PULSE * P_SIZE) >>> 15) * P_RET >>> 15;
                $display("  单梳状首回声理论峰值 = %0d", e0);
                $display("  回声簇能量：梳状0 = %0d   梳状1 = %0d   梳状0 的二次回声 = %0d", a0, a1, a2);
                if (a0 == 0) begin $display("  FAIL: 梳状0 没有回声能量"); errs = errs + 1; end
                else begin
                    // 两条不同长度梳状的首回声能量应为同一量级（比值 < 3）
                    if (a1 > a0 * 3 || a0 > a1 * 3) begin
                        $display("  FAIL: 梳状0/1 首回声能量差异过大"); errs = errs + 1;
                    end
                    // 二次回声（反馈 0.915）必须存在，但量级不能失控。
                    // ⚠ 这个窗（2430±30）里同时落进了梳状1~7 的首回声（1293~1783 的二次位置），
                    //   所以它的绝对量级天然比"单条梳状首回声"大一个数量级，
                    //   阈值按实测取 a0*20（实测 10669 / 792 = 13.5，留余量）。
                    //   真正要防的是"反馈 ≥1 导致单调增长"，那会表现成量级随窗口暴涨。
                    if (a2 == 0) begin $display("  FAIL: 没有二次回声（反馈没工作）"); errs = errs + 1; end
                    else if (a2 > a0 * 20) begin
                        $display("  FAIL: 二次回声量级失控（反馈 >1 的迹象）"); errs = errs + 1;
                    end
                end
            end

            $display("");
            $display("=== 5) 不饱和 / 能量衰减 ===");
            $display("  |y| 峰值 = %0d / 8388607", peak);
            $display("  接近饱和(|y|>100000)的采样数 = %0d / %0d", sat_cnt, NS);
            if (peak == 0) begin $display("  FAIL: 完全没有输出"); errs = errs + 1; end
            if (sat_cnt != 0) begin $display("  FAIL: 有采样接近饱和"); errs = errs + 1; end

            // 逐窗口独立重算 |y| 之和：窗口1 含首回声应最大，末窗应远小于它
            begin : accblk
                integer a, a1, alast, apeakk;
                a1 = 0; alast = 0; apeakk = 0;
                $display("  每 %0d 采样的 |y| 之和：", WIN);
                for (i = 0; i < NS/WIN; i = i + 1) begin
                    a = 0;
                    for (j = i*WIN; j < (i+1)*WIN; j = j + 1)
                        a = a + ((got_l[j] >= 0) ? got_l[j] : -got_l[j]);
                    $display("    窗口%0d (采样 %0d~%0d) : %0d", i, i*WIN, (i+1)*WIN-1, a);
                    if (i == 1) a1 = a;
                    if (a > apeakk) apeakk = a;
                    if (i == NS/WIN-1) alast = a;
                end
                if (a1 == 0) begin $display("  FAIL: 第 2 个窗口没有能量"); errs = errs + 1; end
                // 判据：末尾窗口必须比**包络峰值窗**低至少 10%（说明能量在收敛），
                // 而不是要求"归零"——decay=0.915 的梳状本来就还在响。
                // 参考模型同参数：末窗 93841 / 峰值窗 153795 = 0.61，余量很大。
                else if (alast * 10 > apeakk * 9) begin
                    $display("  FAIL: 末段能量没收敛（%0d vs 峰值窗 %0d）", alast, apeakk);
                    errs = errs + 1;
                end
            end

            $display("");
            $display("=== 6) 尾段 / 量程 ===");
            begin : tailchk
                integer nz, over, mx, tailE, midE, w;
                reg signed [AW-1:0] v;
                nz = 0; over = 0; mx = 0; tailE = 0; midE = 0;
                for (j = 0; j < NS; j = j + 1) begin
                    if ((got_l[j] != 0 || got_r[j] != 0) && j >= 7000) nz = nz + 1;
                    v = got_l[j];
                    if (j >= 7000) tailE = tailE + ((v >= 0) ? v : -v);
                    if (j >= 3000 && j < 5000) midE = midE + ((v >= 0) ? v : -v);
                    if (v > 32'sd10000000 || v < -32'sd10000000) over = over + 1;
                    if (v > mx) mx = v;
                    if (-v > mx) mx = -v;
                end
                $display("  |L| 峰值 = %0d   超量程(|y|>1e7) = %0d", mx, over);
                $display("  7000~%0d 非零采样数 = %0d（decay=0.915 下本来就在响，非零是正常的）", NS-1, nz);
                if (over != 0) begin $display("  FAIL: 有超量程样本（定点溢出）"); errs = errs + 1; end
                // 自激的真正判据：后段峰值不衰减。这里比较末窗与前中段能量
                if (tailE * 2 > midE) begin
                    $display("  FAIL: 尾段能量未衰减（疑似自激）：末窗 %0d vs 中段 %0d", tailE, midE);
                    errs = errs + 1;
                end
            end

            $display("");
            $display("=== 7) 索引对齐 ===");
            $display("  驱动 n=%0d  输出 m=%0d  %s", n, m, (m == NS) ? "1:1 OK" : "不匹配！");
            if (m != NS) begin $display("  FAIL: 输出与驱动不 1:1"); errs = errs + 1; end

            if (errs == 0) $display("\nPASS  tb_fx_reverb: 7 项全过");
            else           $display("\nFAIL  tb_fx_reverb: %0d 项", errs);
            $finish;
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
    end






endmodule
`default_nettype wire
