//  tb_timbre_amp —— 用**最终 I2S 输出**测量不同音色的实际波形差异
//  ⚠ 2026-10-15：之前的 tb_timbre_e2e 测 voice_aud[23:0]（泳道0），
//     而分配到的声部可能在其他泳道 → 看错对象。这里直接用 sample_l（最终输出）。
`timescale 1ns/1ps
module tb_timbre_amp;
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
        .TEST_MODE_DEFAULT(0),
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
    integer i2;
    initial begin
        if (!$value$plusargs("pc=%d", pcn)) pcn = 0;
        $display("  ★ 本次 Program Change = %0d", pcn);
        wait (dut.rst_n_sync === 1'b1);   // ⚠ 必须等复位真正释放，否则 MIDI 全被吞掉
        #2000;
        repeat (200) @(posedge clk50);

        midi_byte(8'hB0); midi_byte(8'h00); midi_byte(8'h00);   // Bank MSB
        midi_byte(8'hC0); midi_byte(pcn[7:0]);                   // Program Change
        #5_000_000;

        midi_byte(8'h90); midi_byte(8'h3C); midi_byte(8'h64);   // Note On ch0 n=60 v=100

        counting = 1;
        #100_000_000;
        counting = 0;

        rms = 0.0;
        if (n > 0) rms = $sqrt(sumsq / n);
        $display("");
        $display("     === 最终 I2S 输出统计（pc=%0d）===", pcn);
        $display("       样本数      : %0d", n);
        $display("       最小/最大   : %0d / %0d", mn, mx);
        $display("       峰峰值      : %0d", mx - mn);
        $display("       RMS         : %0.0f", rms);
        $display("       非零样本    : %0d", nz);
        $display("       过零次数    : %0d", zc);
        $display("       音色槽(pf_timbre[2:0]) = %b", dut.pf_timbre[2:0]);
        $display("       --- 波表原始数据（绕开限幅器）---");
        $display("       max |tab_n| 全泳道 = %0d", tab_max);
        $display("       tab_n 非零计数      = %0d", tab_nz);
        $display("       pf_gate   = %b", dut.pf_gate);
        $display("       pf_timbre = %b (每泳道3位)", dut.pf_timbre);
        $display("       --- ROM 地址槽号（高3位）---");
        $display("       dds_voice 输出 rom_addr_n 的最大槽号 = %0d", dds_slot_seen);
        $display("       最后抓到的 lane0 tab_n = %0d", dbg_tab);
        $display("       --- lane0 (有gate) 的 tab_n 统计 ---");
        $display("       min = %0d   max = %0d   峰峰值 = %0d", tn_min, tn_max, tn_max - tn_min);
        $display("       过零次数 = %0d   样本数 = %0d", tn_zc, tn_n);
        $display("       --- wave_fetch 内部 ---");
        $display("       rom_addr 槽号最大值 = %0d", ra_slot_max);
        $display("       rom_dout  min/max = %0d / %0d   过零 = %0d", rd_min, rd_max, rd_zc);
        $display("       --- ROM 存储器实际内容（每 2048 点取首值）---");
        $display("       mem[    0] = %0d", $signed(dut.u_wfetch.u_rom.mem[0]));
        $display("       mem[ 2048] = %0d", $signed(dut.u_wfetch.u_rom.mem[2048]));
        $display("       mem[ 4096] = %0d", $signed(dut.u_wfetch.u_rom.mem[4096]));
        $display("       mem[ 6144] = %0d", $signed(dut.u_wfetch.u_rom.mem[6144]));
        $display("       mem[ 8192] = %0d", $signed(dut.u_wfetch.u_rom.mem[8192]));
        $display("       mem[10240] = %0d", $signed(dut.u_wfetch.u_rom.mem[10240]));
        $display("       mem[12288] = %0d", $signed(dut.u_wfetch.u_rom.mem[12288]));
        $display("       mem[14336] = %0d", $signed(dut.u_wfetch.u_rom.mem[14336]));
        $display("       --- 每槽内 4 个点（看形状：正弦应有正负）---");
        $display("       槽0: %0d %0d %0d %0d", $signed(dut.u_wfetch.u_rom.mem[0]), $signed(dut.u_wfetch.u_rom.mem[512]), $signed(dut.u_wfetch.u_rom.mem[1024]), $signed(dut.u_wfetch.u_rom.mem[1536]));
        $display("       槽5: %0d %0d %0d %0d", $signed(dut.u_wfetch.u_rom.mem[10240]), $signed(dut.u_wfetch.u_rom.mem[10752]), $signed(dut.u_wfetch.u_rom.mem[11264]), $signed(dut.u_wfetch.u_rom.mem[11776]));
        $display("       --- gate 有效期间的 rom_addr 槽号分布 ---");
        $display("       槽0 次数 = %0d   槽5 次数 = %0d   其他 = %0d", cnt_s0, cnt_s5, cnt_oth);
        $display("       槽0 时 rom_dout 范围 = %0d / %0d  (n=%0d)", d0_min, d0_max, d0_n);
        $display("       槽5 时 rom_dout 范围 = %0d / %0d  (n=%0d)", d5_min, d5_max, d5_n);
        $display("");
        $finish;
    end
endmodule