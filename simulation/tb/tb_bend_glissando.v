//  tb_timbre_amp —— 用**最终 I2S 输出**测量不同音色的实际波形差异
//  ⚠ 2026-10-15：之前的 tb_timbre_e2e 测 voice_aud[23:0]（泳道0），
//     而分配到的声部可能在其他泳道 → 看错对象。这里直接用 sample_l（最终输出）。
`timescale 1ns/1ps
module tb_bend_glissando;
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
    initial begin
        if (!$value$plusargs("pc=%d", pcn)) pcn = 0;
        $display("  ★ 本次 Program Change = %0d", pcn);
        wait (dut.rst_n_sync === 1'b1);   // ⚠ 必须等复位真正释放，否则 MIDI 全被吞掉
        #2000;
        repeat (200) @(posedge clk50);

        //=======================================================
        // 测试模式验证（发任何 MIDI **之前**）
        //   期望：test_mode=1，且 sample_l 有非零输出（32 个对数均匀振荡器）
        //=======================================================
        mn = 1<<20; mx = -(1<<20); n = 0; nz = 0;
        counting = 1;
        repeat (300000) @(posedge clk50);      // 6 ms
        counting = 0;
        //  ⚠ 2026-10-18：确认 CC71-74 四个调制量的复位是"中心值" 64。
        //     通道 0 的四个值都应为 64；
        //     换算后 f_coeff=30000 / q_coeff=16384 / a_step=5 / r_step=8。
        //     若为 0 → q_coeff=0（阻尼为零 → 自激啸叫）+ 包络瞬间跳变（咔哒），
        //     这就是实板"所有音色都炸"的根因。
        $display("  [调制字段复位] ch0: cutoff=%0d reson=%0d attack=%0d release=%0d  (都应为 64)",
                 dut.u_sched.u_cps.ext_cutoff_mod[6:0],
                 dut.u_sched.u_cps.ext_reson_mod [6:0],
                 dut.u_sched.u_cps.ext_attack_mod[6:0],
                 dut.u_sched.u_cps.ext_release_mod[6:0]);
        if (dut.u_sched.u_cps.ext_cutoff_mod[6:0]  === 7'd64 &&
            dut.u_sched.u_cps.ext_reson_mod [6:0]  === 7'd64 &&
            dut.u_sched.u_cps.ext_attack_mod[6:0]  === 7'd64 &&
            dut.u_sched.u_cps.ext_release_mod[6:0] === 7'd64)
            $display("  *** 调制字段复位 PASS：全为 64（中心），不会啸叫/咔哒 ***");
        else
            $display("  *** 调制字段复位 FAIL：数值不对，实板还会炸 ***");

        $display("  [测试模式] 未发 MIDI: test_mode=%b  sample_l min=%0d max=%0d 峰峰值=%0d 非零=%0d",
                 dut.u_full_top.test_mode, mn, mx, mx-mn, nz);
        if (dut.u_full_top.test_mode === 1'b1 && (mx-mn) > 1000)
            $display("  *** 测试模式 PASS：上电即有 32 谱线输出 ***");
        else
            $display("  *** 测试模式 FAIL：上电无输出或 test_mode 不为 1 ***");

        midi_byte(8'hB0); midi_byte(8'h00); midi_byte(8'h00);   // Bank MSB
        midi_byte(8'hC0); midi_byte(pcn[7:0]);                   // Program Change
        #5_000_000;

        midi_byte(8'h90); midi_byte(8'h3C); midi_byte(8'h64);   // Note On ch0 n=60 v=100

        //=======================================================
        // 弯音验证：强制 ch_bend_ratio_bus，检查 pf_phase_inc 是否成比例
        //   期望 inc 与 bend_ratio 严格成正比（除法在 voice_fetch 里是 >>> 14）
        //=======================================================
        repeat (4000) @(posedge clk50);
        sample_inc(inc_ref);
        $display("  [弯音] 基准 (bend=1.0, 由 shadow 给出)  pf_phase_inc = %0d", inc_ref);

        force dut.u_sched.ch_bend_ratio_bus = {NCH{16'd32768}};   // 2.0x
        repeat (4000) @(posedge clk50);
        sample_inc(inc_x2);
        $display("  [弯音] bend=2.0  pf_phase_inc = %0d   比值 = %0.4f  (期望 2.0000)",
                 inc_x2, (inc_ref>0) ? real'(inc_x2)/real'(inc_ref) : 0.0);

        force dut.u_sched.ch_bend_ratio_bus = {NCH{16'd8192}};    // 0.5x
        repeat (4000) @(posedge clk50);
        sample_inc(inc_h);
        $display("  [弯音] bend=0.5  pf_phase_inc = %0d   比值 = %0.4f  (期望 0.5000)",
                 inc_h, (inc_ref>0) ? real'(inc_h)/real'(inc_ref) : 0.0);

        force dut.u_sched.ch_bend_ratio_bus = {NCH{16'd16384}};   // 1.0x
        repeat (4000) @(posedge clk50);
        sample_inc(inc_one);
        $display("  [弯音] bend=1.0  pf_phase_inc = %0d   比值 = %0.4f  (期望 1.0000)",
                 inc_one, (inc_ref>0) ? real'(inc_one)/real'(inc_ref) : 0.0);

        release dut.u_sched.ch_bend_ratio_bus;
        $display("  [测试模式] 发过 Note 之后: test_mode=%b （期望 0）", dut.u_full_top.test_mode);

        //=======================================================
        // 颤音验证：把 mod_wheel 拉满(127)，观察 pf_phase_inc 是否周期性起伏
        //   期望：在基准 ±3.1% 内摆动（depth 508/16384）
        //=======================================================
        begin
            integer vi, vmin, vmax, vnow;
            force dut.u_sched.mod_wheel_reg = {NCH{7'd127}};
            vmin = 1<<30; vmax = -(1<<30);
            for (vi = 0; vi < 4000; vi = vi + 1) begin
                @(posedge clk50);
                vnow = cur_inc();
                if (vnow > 0) begin
                    if (vnow < vmin) vmin = vnow;
                    if (vnow > vmax) vmax = vnow;
                end
            end
            release dut.u_sched.mod_wheel_reg;
            $display("  [颤音] mod_wheel=127  pf_phase_inc 摆动 min=%0d max=%0d 幅度=%0d (%.2f%%)",
                     vmin, vmax, vmax-vmin, (inc_ref>0) ? (real'(vmax-vmin)*100.0/real'(inc_ref)) : 0.0);
            if (vmax > vmin && (vmax-vmin) > (inc_ref/100) && (vmax-vmin) < (inc_ref/8))
                $display("  *** 颤音验证 PASS：pf_phase_inc 有周期性起伏，幅度合理 ***");
            else
                $display("  *** 颤音验证 FAIL：没有摆动或幅度异常 ***");
        end

        if (inc_ref > 0 && inc_x2 == 2*inc_ref && inc_h == (inc_ref>>1) && inc_one == inc_ref)
            $display("  *** 弯音验证 PASS：pf_phase_inc 与 bend_ratio 严格成正比 ***");
        else
            $display("  *** 弯音验证 FAIL：比例不对（ref=%0d x2=%0d half=%0d one=%0d）***",
                     inc_ref, inc_x2, inc_h, inc_one);

        counting = 1;
        #50_000_000;
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