//============================================================================
//  tb_fx_reverb —— 混响脉冲响应验证（2026-10-28 按 16 梳状 + 4 全通重写）
//
//  结构（见 rtl/global/fx_reverb.v 头注释）：16 条梳状并联求和 → 4 级全通。
//
//  验证点（都可由 RTL 结构精确推导，不是"看着像"）：
//      1) 输出首个非零 = 1215（最短梳状；全通链第 1 拍是 -x 直通）
//      2) 内部"16 条梳状之和"的回声正好落在 len_of() 的 16 个长度上（左声道）
//      3) 右声道内部回声 = 左声道同一条线 +25（立体声展宽 + 独立的 +25 间隙表）
//      4) 首回声标定：注入 = PULSE*size>>23，出口 = 注入/2 × (p_ret>>14)
//      5) 不饱和、不溢出（2026-10-28 之前的"炸"= 内部位宽 bug，这里必须抓得住）
//      6) 能量衰减（不自激）
//      7) 输出计数 m 与驱动计数 n 严格 1:1
//
//  ⚠ 为什么在"内部梳状和"上验证位置、而不是只看输出：
//     4 级全通（延时 605/480/371/245）会把前面的回声再延后叠加，某些位置上
//     正好与新回声幅度相等、符号相反（实测 1476 = 1231 + 245 完全抵消），
//     只看输出会把"结构正确"误判成"位置错"。
//
//  ⚠ 2026-10-28 两处必改（否则本 TB 本身是错的）：
//     · PERIOD 128 → 260：FSM 现在 20 线 x 5 拍 x 2 声道 = 200 拍/采样，
//       128 拍时 in_vld 会在处理中途到来而被丢掉（m 与 n 不 1:1）。
//     · 回声表按 16 条梳状更新；PULSE 从 1000 提到 400000（÷256 归一化后
//       1000 只剩 3 LSB，位置还能看，幅度判据就废了）。
//
//  ⚠ 写 TB 的三个坑（本文件已避开）：
//      integer 默认是 X，X+1 永远是 X → 计数器必须初始化
//      24 位有符号常量上限是 8388607，写 24'sd10000000 会溢出成负数；
//      integer 是 32 位，PULSE*size 会溢出 → 标定值用 64 位算
//      iverilog 13 不支持带范围的 task 端口 → 本仓库统一用 function/task 老式写法
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_fx_reverb;
    localparam integer AW     = 24;
    localparam integer NL     = 16;       // 梳状条数
    localparam integer PERIOD = 260;      // 200 拍 FSM + 余量
    localparam integer NS     = 8000;
    localparam integer WIN    = 1000;
    localparam integer P_SIZE = 26000;    // 输入增益 Q1.15（0.793）
    localparam integer P_DECAY= 30000;    // 梳状反馈 Q1.15（0.915）
    localparam integer P_DAMP = 9000;     // 高频阻尼 Q1.15（0.275）
    localparam integer P_RET  = 32767;    // 返回电平 Q1.15（≈1.0）
    localparam integer RET_SH = 13;       // 必须与 rtl 的 RET_SH 一致
    localparam integer PULSE  = 400000;   // 输入脉冲幅度（÷256 后 ≈1240，留够分辨率）

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

    reg signed [AW-1:0] got_l [0:NS-1];
    reg signed [AW-1:0] got_r [0:NS-1];
    integer cs_l [0:NS-1];        // 内部：16 条梳状之和 >>1（左声道）
    integer cs_r [0:NS-1];        // 内部：16 条梳状之和 >>1（右声道）

    // 左声道 16 条梳状的长度（必须与 rtl 的 len_of() 一致）
    integer exp_pos [0:NL-1];

    integer best_pos, best_mag;
    integer peak, sat_cnt, first_nz;

    initial begin
        exp_pos[0] = 1215; exp_pos[1] = 1231; exp_pos[2] = 1249; exp_pos[3] = 1277;
        exp_pos[4] = 1293; exp_pos[5] = 1319; exp_pos[6] = 1346; exp_pos[7] = 1373;
        exp_pos[8] = 1390; exp_pos[9] = 1417; exp_pos[10]= 1443; exp_pos[11]= 1476;
        exp_pos[12]= 1508; exp_pos[13]= 1548; exp_pos[14]= 1592; exp_pos[15]= 1637;
        //  ⚠ 不依赖 -DSIMULATION：TB 自己把 DUT 的 BSRAM 清零
        //     （硬件上 BSRAM 初值是 0，仿真里不初始化会读出 X）
        for (i = 0; i < 49000; i = i + 1) dut.rmem[i] = {AW{1'b0}};
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

    //  内部探针：每条线 li==15 的 ST_CM 那一拍就是"16 条之和"，
    //  分别按声道锁存，等 ret_vld 时与输出一起记到本帧的下标上。
    integer cs_hold_l = 0, cs_hold_r = 0;
    always @(posedge clk) begin
        if (rst_n && dut.st == 3'd4 && dut.li == 5'd15) begin
            if (dut.ch == 1'b0) cs_hold_l = $signed(dut.comb_sum_n) >>> 1;
            else                cs_hold_r = $signed(dut.comb_sum_n) >>> 1;
        end
        if (ret_vld) begin
            got_l[m] = ret_l;
            got_r[m] = ret_r;
            cs_l[m]  = cs_hold_l;
            cs_r[m]  = cs_hold_r;
            m = m + 1;
        end
    end

    initial begin
        #60_000_000;
        $display("FAIL  tb_fx_reverb: 超时");
        $display("  m=%0d (期望 %0d)  n=%0d", m, NS, n);
        $finish;
    end

    // 在 pos 附近 ±2 的窗口里找幅度最大值 → best_pos / best_mag（src=0 输出, 1 内部 L, 2 内部 R）
    task find_peak;
        input integer pos;
        input integer src;
        integer v;
        begin
            best_pos = -1; best_mag = 0;
            for (j = pos-2; j <= pos+2; j = j + 1) begin
                if (j >= 0 && j < NS) begin
                    case (src)
                        0: begin
                            v = got_l[j];
                            if (v > best_mag)  begin best_mag = v;  best_pos = j; end
                            if (-v > best_mag) begin best_mag = -v; best_pos = j; end
                        end
                        1: begin
                            v = cs_l[j];
                            if (v > best_mag)  begin best_mag = v;  best_pos = j; end
                            if (-v > best_mag) begin best_mag = -v; best_pos = j; end
                        end
                        default: begin
                            v = cs_r[j];
                            if (v > best_mag)  begin best_mag = v;  best_pos = j; end
                            if (-v > best_mag) begin best_mag = -v; best_pos = j; end
                        end
                    endcase
                end
            end
        end
    endtask

    always @(posedge clk) begin
        if (m >= NS) begin
            peak = 0; sat_cnt = 0; first_nz = -1;
            for (k = 0; k < NS; k = k + 1) begin
                if ((got_l[k] != 0 || got_r[k] != 0) && first_nz < 0) first_nz = k;
                if (got_l[k] > 32'sd1000000 || got_l[k] < -32'sd1000000) sat_cnt = sat_cnt + 1;
                if (got_l[k] > peak) peak = got_l[k];
                if (-got_l[k] > peak) peak = -got_l[k];
            end

            $display("=== 1) 输出首个非零采样 ===");
            $display("  实测 = %0d   期望 = 1215（最短梳状 1215，+-3）", first_nz);
            if (first_nz < 1212 || first_nz > 1218) begin
                $display("  FAIL: 首回声位置不对"); errs = errs + 1;
            end

            $display("");
            $display("=== 2) 左声道 16 条梳状的回声位置（内部节点，容差 +-4）===");
            for (k = 0; k < NL; k = k + 1) begin
                find_peak(exp_pos[k], 1);
                $display("  comb%0d expect %0d : got %0d (mag %0d)  %s",
                         k, exp_pos[k], best_pos, best_mag,
                         (best_pos >= exp_pos[k]-4 && best_pos <= exp_pos[k]+4) ? "OK" : "BAD");
                if (best_pos < exp_pos[k]-4 || best_pos > exp_pos[k]+4) errs = errs + 1;
            end

            $display("");
            $display("=== 3) 右声道内部回声 = 左声道 +25（文档 2.4 立体声展宽）===");
            for (k = 0; k < NL; k = k + 1) begin
                find_peak(exp_pos[k]+25, 2);
                $display("  comb%0d expect %0d : got %0d (mag %0d)  %s",
                         k, exp_pos[k]+25, best_pos, best_mag,
                         (best_pos >= exp_pos[k]+21 && best_pos <= exp_pos[k]+29) ? "OK" : "BAD");
                if (best_pos < exp_pos[k]+21 || best_pos > exp_pos[k]+29) errs = errs + 1;
            end

            $display("");
            $display("=== 4) 首回声标定 ===");
            begin : ampblk
                reg [63:0] e0w;
                integer e0, a0, a1;
                //  e0 = (PULSE*size + 2^22) >> 23 —— 用 64 位算，32 位会溢出
                e0w = ((PULSE * 1) * P_SIZE) + (1<<22);
                e0  = e0w >> 23;
                $display("  注入（单条梳状首回声）理论 = %0d", e0);
                find_peak(exp_pos[0], 1);
                a0 = best_mag;
                find_peak(exp_pos[1], 1);
                a1 = best_mag;
                $display("  内部 comb0 首拍 = %0d ; comb1 首拍 = %0d", a0, a1);
                if (a0 == 0) begin $display("  FAIL: comb0 没有回声"); errs = errs + 1; end
                //  内部探针取的是"16 条之和 >>SUM_SH(1)"，所以理论值要除 2
                else if (a0 < (e0>>1)-2 || a0 > (e0>>1)+2) begin
                    $display("  FAIL: 注入标定错（%0d，理论 %0d）", a0, e0>>1); errs = errs + 1;
                end
                if (a1 > a0*3 || a0 > a1*3) begin
                    $display("  FAIL: comb0/1 首拍幅度差异过大"); errs = errs + 1;
                end
                //  出口：4 级全通第 1 拍是 -x 的四次（符号 +1），
                //  再 (comb_sum>>SUM_SH) × p_ret >> RET_SH
                find_peak(exp_pos[0], 0);
                $display("  出口首拍 = %0d（理论 = (注入/2)*p_ret>>%0d = %0d）",
                         best_mag, RET_SH, ((e0>>1) * P_RET) >> RET_SH);
                if (best_mag < (((e0>>1) * P_RET) >> RET_SH)-4
                 || best_mag > (((e0>>1) * P_RET) >> RET_SH)+4) begin
                    $display("  FAIL: 出口电平与 p_ret 标定不符"); errs = errs + 1;
                end
            end

            $display("");
            $display("=== 5) 不饱和 / 不溢出 ===");
            $display("  |y| 峰值 = %0d（阈值 1000000）", peak);
            $display("  接近饱和(|y|>1e6)的采样数 = %0d / %0d", sat_cnt, NS);
            if (peak == 0) begin $display("  FAIL: 完全没有输出"); errs = errs + 1; end
            if (sat_cnt != 0) begin $display("  FAIL: 有采样接近饱和"); errs = errs + 1; end

            $display("");
            $display("=== 6) 能量衰减（不自激）===");
            begin : accblk
                integer a, a1, alast, apeakk;
                a1 = 0; alast = 0; apeakk = 0;
                for (i = 0; i < NS/WIN; i = i + 1) begin
                    a = 0;
                    for (j = i*WIN; j < (i+1)*WIN; j = j + 1)
                        a = a + ((got_l[j] >= 0) ? got_l[j] : -got_l[j]);
                    $display("    窗口%0d (采样 %0d~%0d) : |y| 之和 = %0d", i, i*WIN, (i+1)*WIN-1, a);
                    if (i == 1) a1 = a;
                    if (a > apeakk) apeakk = a;
                    if (i == NS/WIN-1) alast = a;
                end
                if (a1 == 0) begin $display("  FAIL: 第 2 个窗口没有能量"); errs = errs + 1; end
                else if (alast * 10 > apeakk * 9) begin
                    $display("  FAIL: 末段能量没收敛（%0d vs 峰值窗 %0d）", alast, apeakk);
                    errs = errs + 1;
                end
            end

            $display("");
            $display("=== 7) 索引对齐 ===");
            $display("  驱动 n=%0d  输出 m=%0d  %s", n, m, (m == NS) ? "1:1 OK" : "MISMATCH");
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
