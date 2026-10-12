//============================================================================
//  tb_rev_dbg —— fx_reverb 索引对齐诊断（临时用，不是回归的一员）
//
//  交接.md 第三节 1 号待办：
//      "输出数组 got[1705] = 满量程 8388351，但驱动到第 1705 个采样时
//       DUT 内部（comb_sum / m0 / ap_x / ap_w）全是 0。"
//      → 怀疑 TB 的输出计数器 m 和驱动计数器 n 没对齐。
//
//  本 TB 要回答三个问题：
//      Q1  ret_vld 脉冲数 == 驱动采样数吗？（1:1 吗）
//      Q2  第 k 个输出来自第 k 个输入吗？（把驱动换成"第 n 个采样值 = n"的斜坡，
//          输出序列直接就是延迟指纹，能一眼看出错位/重复/丢样）
//      Q3  FWFT 溢出的根因：是 TB 的固定节拍 PERIOD 太紧（DUT 需要 ~74 拍，
//          TB 只给 96 拍里有 24 拍空闲 → 不该溢出），还是别的？
//
//  做法：PERIOD 参数化，默认给足 200 拍（远大于 DUT 的 74 拍），
//        排除"节拍太紧"这个变量之后，再看 m/n 是否还错位。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_rev_dbg;
    localparam integer AW     = 24;
    localparam integer PERIOD = 200;      // 宽松节拍：DUT 每采样约 74 拍
    localparam integer NS     = 8000;     // 与 tb_fx_reverb 的实验值一致
    localparam integer P_SIZE = 500;      // 与 tb_fx_reverb 的实验值一致

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg  signed [AW-1:0] bus_l, bus_r;
    reg                  in_vld;
    wire                 ret_vld;
    wire signed [AW-1:0] ret_l, ret_r;

    fx_reverb dut (
        .clk(clk), .rst_n(rst_n), .frame_stb(1'b0),
        .in_vld(in_vld), .bus_l(bus_l), .bus_r(bus_r),
        .p_decay(16'd30000),      // 0.915
        .p_damp (16'd9000),       // 0.275
        .p_size (16'd500),
        .p_ret  (16'd32767),
        .p_predly(16'd0),
        .ret_vld(ret_vld), .ret_l(ret_l), .ret_r(ret_r)
    );

    integer cyc = 0;
    integer n   = 0;              // 驱动计数（已发出的采样数）
    integer m   = 0;              // 输出计数（收到的采样数）
    integer backpressure = 0;     // 上一次采样还没输出完就要发下一个 → 背压冲突

    reg     pending;              // 是否有采样在飞（发出但还没收回）

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cyc <= 0; n <= 0; in_vld <= 1'b0; bus_l <= 0; bus_r <= 0;
        end else begin
            in_vld <= 1'b0;
            if (cyc == PERIOD-1) begin
                cyc <= 0;
                if (n < NS) begin
                    if (pending) backpressure <= backpressure + 1;
                    in_vld <= 1'b1;
                    // 单脉冲：只有第 0 个采样 = 1000（与 tb_fx_reverb 完全一致）
                    bus_l  <= (n == 0) ? 24'sd1000 : 24'sd0;
                    bus_r  <= (n == 0) ? 24'sd1000 : 24'sd0;
                    n      <= n + 1;
                end
            end else cyc <= cyc + 1;
        end
    end

    // 全量输出落盘（非零才打，避免 2600 行垃圾）
    always @(posedge clk) begin
        if (ret_vld) begin
            if (ret_l != 0 || ret_r != 0)
                $display("OUT m=%0d  n=%0d  ret_l=%0d  ret_r=%0d", m, n, ret_l, ret_r);
            m <= m + 1;
        end
    end

    // ---- 找出"是谁把超大值写进了延迟线" ----
    // 正常脉冲响应量级只有 ±15；任何 |wdata| > 100000 的写都是异常。
    reg [63:0] cyc_cnt = 0;
    always @(posedge clk) cyc_cnt <= cyc_cnt + 1;

    always @(posedge clk) begin
        if (rst_n && (dut.st == 3'd5)) begin   // ST_WB = 写回那一拍（旧的 we 已改为状态译码）
            if (dut.wdata > 24'sd100000 || dut.wdata < -24'sd100000) begin
                $display("  [BIGWR] cyc=%0d addr=%0d wdata=%0d | st=%0d li=%0d ch=%0d m0=%0d ap_x=%0d ap_out=%0d ap_w=%0d comb_sum=%0d",
                         cyc_cnt, dut.waddr, dut.wdata, dut.st, dut.li, dut.ch,
                         dut.m0, dut.ap_x, dut.ap_out, dut.ap_w, dut.comb_sum);
            end
        end
    end

    // 关键窗口的 DUT 内部状态
    always @(posedge clk) if (ret_vld) begin
        if ((m >= 1700 && m <= 1712) || (m < 3) || (m >= NS-3)) begin
            $display("  [align] 第 %0d 个输出：ret_l=%0d  n=%0d DUT: st=%0d li=%0d ch=%0d ptr_l0=%0d fs_l0=%0d",
                     m, ret_l, n, dut.st, dut.li, dut.ch, dut.ptr_l[0], dut.fs_l[0]);
        end
    end

    initial begin
        #400_000_000;
        $display("FAIL 超时：m=%0d n=%0d", m, n);
        $finish;
    end

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
    end

    // ---- 结束条件：驱动发完 + 输出也收完（或跑到 n 发完后再等 300 拍）----
    integer idle = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            if (n >= NS && m >= NS) begin
                $display("=== 统计 ===");
                $display("  驱动 n=%0d  输出 m=%0d", n, m);
                $display("  背压冲突次数（发出时上一个还没收回）= %0d", backpressure);
                $display("  %s", (m == NS) ? "Q1: 1:1 对齐 OK" : "Q1: 数量不匹配（丢样/多输出）");
                $finish;
            end
            if (n >= NS) begin
                idle <= idle + 1;
                if (idle > 3000) begin
                    $display("=== 统计 ===");
                    $display("  驱动 n=%0d  输出 m=%0d  → 输出少了 %0d 个", n, m, n - m);
                    $display("  背压冲突次数 = %0d", backpressure);
                    $finish;
                end
            end
        end
    end

endmodule
`default_nettype wire
