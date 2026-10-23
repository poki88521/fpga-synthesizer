//  tb_timbre_amp —— 用**最终 I2S 输出**测量不同音色的实际波形差异
//  ⚠ 2026-10-15：之前的 tb_timbre_e2e 测 voice_aud[23:0]（泳道0），
//     而分配到的声部可能在其他泳道 → 看错对象。这里直接用 sample_l（最终输出）。
`timescale 1ns/1ps
module tb_poly_latency;
    localparam integer P = 8, NCH = 16;
    reg clk50 = 0, clk12288 = 0;
    reg [3:0] midi_rx = 4'hF;
    wire scl, mux_sel0, mux_sel1, mux_sel2, HP_BCK, HP_WS, HP_DIN, PA_EN;
    wire [3:0] dbg_led;
    inout sda;

    always #10 clk50 = ~clk50;
    always #20.345 clk12288 = ~clk12288;

    pullup(sda);   // midi_rx 由 TB 手动驱动，不能加 pullup

    //  ⚠ 必须照抄 tb_full_system 的仿真参数：USE_PLL=0（旁路 PLL）+ POR_BITS=8
    //     否则仿真里 PLL 桩不锁定 → rst_n_sync 永远为 0 → MIDI 全被吞掉。
    full_system #(
        .USE_PLL(0), .P(P), .G(4), .NCH(NCH), .STRIDE(32),
        .PA_DELAY(8), .POR_BITS(8),
        .TEST_MODE_DEFAULT(1),
        .WAVE_INIT_FILE("data/wave_table.hex")
    ) dut (
        .clk50(clk50), .clk12288(clk12288), .midi_rx(midi_rx),
        .scl(scl), .sda(sda),
        .mux_sel0(mux_sel0), .mux_sel1(mux_sel1), .mux_sel2(mux_sel2),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),
        .dbg_led(dbg_led)
    );

    localparam integer BIT_TICK = 1573;    // 与 midi_parse 的过采样节拍一致（比真实 31250 baud 快 20 倍，仅仿真用）
    integer pcn = 0;
    task midi_byte(input [7:0] b);
        integer i;
        begin
            midi_rx[3] = 1'b0; #(BIT_TICK);
            for (i = 0; i < 8; i = i + 1) begin midi_rx[3] = b[i]; #(BIT_TICK); end
            midi_rx[3] = 1'b1; #(BIT_TICK);
        end
    endtask

    integer n = 0, mn = 1<<20, mx = -(1<<20), nz = 0, zc = 0;
    //  ⚠ 2026-10-15 加：直接跟踪**波表原始数据 tab_n / tab_n1**，
    //     绕开 soft_limiter（×16 增益下限幅器会把不同音色压成同一电平）。
    integer tab_max = 0, tab_nz = 0, tab_n = 0;
    integer ta;
    //  ⚠ 2026-10-15 加：直接看**ROM 地址的高 3 位**（槽号）以及 dds_voice 给出的地址
    integer addr_slot_seen = 0;      // 见过的最大槽号
    integer dds_slot_seen  = 0;      // dds_voice 输出地址的最大槽号
    integer dbg_tab = 0, dbg_addr = 0, dbg_dds = 0;
    integer tn_min = 1<<20, tn_max = -(1<<20), tn_zc = 0, tn_last = 0, tn_n = 0;
    //  ⚠ 直接探 wave_fetch 内部的 rom_addr / rom_dout
    integer ra_slot_max = 0, rd_min = 1<<20, rd_max = -(1<<20), rd_zc = 0, rd_last = 0, rd_n = 0;
    //  ⚠ 在 gate 有效时统计 rom_addr 槽号分布 + 各槽对应的 rom_dout 范围
    integer cnt_s0 = 0, cnt_s5 = 0, cnt_oth = 0;
    integer d5_min = 1<<20, d5_max = -(1<<20), d5_n = 0;
    integer d0_min = 1<<20, d0_max = -(1<<20), d0_n = 0;
    integer last = 0;
    real    sumsq = 0.0;
    integer counting = 0;
    reg [15:0] prev = 0;

    always @(posedge clk50) if (dut.rst_n_sync && counting) begin
        integer v;
        v = $signed(dut.u_full_top.sample_l);
        n = n + 1;
        if (v < mn) mn = v;
        if (v > mx) mx = v;
        if (v != 0) nz = nz + 1;
        sumsq = sumsq + v*v;
        if (n > 1 && ((v < 0 && last >= 0) || (v >= 0 && last < 0))) zc = zc + 1;
        last = v;
        //  ⚠ 只统计**有 gate 的泳道**！空闲泳道的 pf_timbre 恒为 0，
        //     会一直读槽 0（幅度 30000），把真正发声音色的数据淹没。
        //  dds_voice 组合输出的地址（全泳道，取最大槽号）
        for (ta = 0; ta < 8; ta = ta + 1) begin
            integer sl;
            sl = dut.rom_addr_n[ta*14 + 13 -: 3] ;
            if (sl > dds_slot_seen) dds_slot_seen = sl;
        end
        //  wave_fetch 锁存后真正的 ROM 地址由内部扫，这里抓 lane0 的 tab_n 与地址
        dbg_tab = $signed(dut.tab_n[15:0]);
        begin
            integer sl, dv;
            sl = dut.u_wfetch.rom_addr[13:11];
            if (sl > ra_slot_max) ra_slot_max = sl;
            dv = $signed(dut.u_wfetch.rom_dout);
            if (dut.pf_gate[0]) begin
                if (sl == 0) cnt_s0 = cnt_s0 + 1;
                else if (sl == 5) cnt_s5 = cnt_s5 + 1;
                else cnt_oth = cnt_oth + 1;
                if (sl == 0) begin
                    if (dv < d0_min) d0_min = dv;
                    if (dv > d0_max) d0_max = dv;
                    d0_n = d0_n + 1;
                end
                if (sl == 5) begin
                    if (dv < d5_min) d5_min = dv;
                    if (dv > d5_max) d5_max = dv;
                    d5_n = d5_n + 1;
                end
            end
            if (dv < rd_min) rd_min = dv;
            if (dv > rd_max) rd_max = dv;
            if (rd_n > 0 && ((dv < 0 && rd_last >= 0) || (dv >= 0 && rd_last < 0))) rd_zc = rd_zc + 1;
            rd_last = dv; rd_n = rd_n + 1;
        end
        if (dut.pf_gate[0]) begin
            integer t0;
            t0 = $signed(dut.tab_n[15:0]);
            if (t0 < tn_min) tn_min = t0;
            if (t0 > tn_max) tn_max = t0;
            if (tn_n > 0 && ((t0 < 0 && tn_last >= 0) || (t0 >= 0 && tn_last < 0))) tn_zc = tn_zc + 1;
            tn_last = t0; tn_n = tn_n + 1;
        end
        for (ta = 0; ta < 8; ta = ta + 1) begin
            integer tv;
            if (dut.pf_gate[ta]) begin
                tv = $signed(dut.tab_n[ta*16 +: 16]);
                if (tv < 0) tv = -tv;
                if (tv > tab_max) tab_max = tv;
                if (tv != 0) tab_nz = tab_nz + 1;
            end
        end
    end

    real rms;
    // ===== 弯音验证 =====
    integer inc_ref = 0, inc_x2 = 0, inc_h = 0, inc_one = 0;

    //  取所有"有 gate"的泳道里最大的 pf_phase_inc（= 正在响的那个声部）
    function [31:0] cur_inc;
        integer k;
        reg [31:0] v;
        begin
            v = 32'd0;
            for (k = 0; k < P; k = k + 1)
                if (dut.pf_gate[k] && dut.pf_phase_inc[k*32 +: 32] > v)
                    v = dut.pf_phase_inc[k*32 +: 32];
            cur_inc = v;
        end
    endfunction

    //  ⚠ 单拍读 `pf_phase_inc` 会抓在更新的那一拍拿到 0（实测 bend=1.0 读成 0）。
    //     这里跨 N 拍取最大值，稳定反映"正在响的声部的相位增量"。
    task sample_inc(output [31:0] r);
        integer t2;
        reg [31:0] v;
        begin
            v = 32'd0;
            for (t2 = 0; t2 < 400; t2 = t2 + 1) begin
                @(posedge clk50);
                if (cur_inc() > v) v = cur_inc();
            end
            r = v;
        end
    endtask

    integer i2;
    // ===== 复音 / 延迟测试变量 =====
    integer t_note, t_audio, kk, i32;
    integer poly_ok, poly_n;
    integer pkmax, pkmin;

    // ===== 变量 =====
    integer t_ready, pk1, pk32, mn1, mn32, gate_hi, gate_n;

    //  量一段窗口内 sample_l 的峰峰值（有符号！sample_l 本身是无符号 16 位）
    task measure_pk(output integer pk, output integer mn);
        integer q;
        begin
            pk = -32768; mn = 32767;
            for (q = 0; q < 200000; q = q + 1) begin
                @(posedge clk50);
                if ($signed(dut.u_full_top.sample_l) > pk) pk = $signed(dut.u_full_top.sample_l);
                if ($signed(dut.u_full_top.sample_l) < mn) mn = $signed(dut.u_full_top.sample_l);
            end
        end
    endtask

    initial begin
        wait (dut.rst_n_sync === 1'b1);
        #2000;
        repeat (200) @(posedge clk50);

        // 退出测试模式 + 全音关
        midi_byte(8'h90); midi_byte(8'h3C); midi_byte(8'h00);
        repeat (3000) @(posedge clk50);
        midi_byte(8'hB0); midi_byte(8'h7B); midi_byte(8'h00);
        midi_byte(8'hB0); midi_byte(8'h78); midi_byte(8'h00);
        repeat (8000) @(posedge clk50);

        //==================================================================
        // 1. 延迟：Note On 最后一字节 → pf_gate 首次非零（调度层可见延迟）
        //    音频链后面还有固定的流水级数（声部→通道→效果→I2S），另行估算
        //==================================================================
        $display("");
        $display("=== 1. 延迟实测（Note On 最后一字节 → pf_gate 首次非零）===");
        midi_byte(8'h90); midi_byte(8'h40); midi_byte(8'h64);   // note 64 vel 100
        t_note  = $time;
        t_ready = 0;
        for (kk = 0; kk < 500000 && t_ready == 0; kk = kk + 1) begin
            @(posedge clk50);
            if (dut.pf_gate !== 8'h00) t_ready = $time;
        end
        if (t_ready == 0)
            $display("    ✗ 超时：10 ms 内没有分配出声部");
        else begin
            $display("    = %0d ns = %0.4f ms  （%0d 个 clk50 周期）",
                     t_ready - t_note, real'(t_ready - t_note)/1000000.0, (t_ready - t_note)/20);
            $display("    注：音频链在 pf_gate 之后还有 ~10-20 个采样（0.2-0.4 ms）流水");
            if ((t_ready - t_note) < 4000000)
                $display("    ✓ 即使加上音频流水，仍远小于 5 ms");
        end

        // 清音
        midi_byte(8'hB0); midi_byte(8'h7B); midi_byte(8'h00);
        midi_byte(8'hB0); midi_byte(8'h78); midi_byte(8'h00);
        repeat (200000) @(posedge clk50);      // 4 ms

        //==================================================================
        // 2a. 单音基准电平
        //==================================================================
        $display("");
        $display("=== 2. 复音实测（用输出电平对比：1 音 vs 32 音）===");
        midi_byte(8'h90); midi_byte(8'h40); midi_byte(8'h64);
        repeat (100000) @(posedge clk50);      // 2 ms，等起音
        measure_pk(pk1, mn1);
        $display("    1  个音 : min=%0d max=%0d 峰峰值=%0d", mn1, pk1, pk1 - mn1);

        midi_byte(8'hB0); midi_byte(8'h7B); midi_byte(8'h00);
        midi_byte(8'hB0); midi_byte(8'h78); midi_byte(8'h00);
        repeat (200000) @(posedge clk50);

        //==================================================================
        // 2b. 32 音
        //==================================================================
        for (i32 = 0; i32 < 32; i32 = i32 + 1) begin
            midi_byte(8'h90); midi_byte(8'd36 + i32[7:0]); midi_byte(8'h64);
        end
        repeat (150000) @(posedge clk50);      // 3 ms
        measure_pk(pk32, mn32);

        gate_hi = 0; gate_n = 0;
        for (kk = 0; kk < 8000; kk = kk + 1) begin
            @(posedge clk50);
            gate_n = gate_n + 1;
            if (dut.pf_gate === 8'hFF) gate_hi = gate_hi + 1;
        end

        $display("    32 个音 : min=%0d max=%0d 峰峰值=%0d", mn32, pk32, pk32 - mn32);
        $display("    电平比（32音/1音）: %0.2f 倍", (pk1-mn1 > 0) ? real'(pk32-mn32)/real'(pk1-mn1) : 0.0);
        $display("    pf_gate 全 1 比例  : %0d / %0d（仅供参考，分配器不保证填满时隙）", gate_hi, gate_n);

        if ((pk32-mn32) > (pk1-mn1) * 3)
            $display("    *** 32 复音 PASS：32 音电平显著高于 1 音（%0.1f 倍）***",
                     real'(pk32-mn32)/real'(pk1-mn1));
        else if ((pk32-mn32) > (pk1-mn1))
            $display("    △ 32 音电平只略高于 1 音（%0.2f 倍），可能被限幅器压缩或有声部未分配",
                     real'(pk32-mn32)/real'(pk1-mn1));
        else
            $display("    *** 32 复音 FAIL：电平没有增长 ***");

        midi_byte(8'hB0); midi_byte(8'h7B); midi_byte(8'h00);
        midi_byte(8'hB0); midi_byte(8'h78); midi_byte(8'h00);
        repeat (5000) @(posedge clk50);

        $display("");
        $display("=== 测试结束 ===");
        $finish;
    end

endmodule
