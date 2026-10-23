//============================================================================
//  tb_slot_probe —— 时隙/预取时序探针（极小仿真，0.5 ms 内出结论）
//
//  目的：查清 voice_mono 在 `vca_en`（音频就绪）那一刻看到的参数，
//        到底是**本声部**的还是**下一个时隙声部**的。
//
//  被测组合（与 full_system 同构，只去掉 MIDI/通道层/效果器）：
//      voice_slot_seq → voice_fetch → pf_* → voice_mono
//                                         wave_fetch → tab_n/n1
//
//  打印：每个 vca_en 一行
//      slot          当前时隙号
//      pf_gate       实时 pf_gate（voice_mono 旧代码用的就是它）
//      lat_gate      voice_mono 在 dds_en 锁存的 gate（新代码用它）
//      envst/env     ADSR 状态与电平
//      phacc         相位累加器
//  ⚠ 关键判据：pf_gate 与 lat_gate 若不相等，就证明"差一个时隙"确实存在。
//============================================================================
`timescale 1ns/1ps

module tb_slot_probe;

    localparam integer P      = 8;
    localparam integer G      = 4;
    localparam integer STRIDE = 32;
    localparam integer N_CYC  = 1024;
    localparam integer NCH    = 16;
    localparam integer N      = P * G;

    reg clk = 0;
    always #10 clk = ~clk;                       // 50 MHz

    reg rst_n = 0;
    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1;
    end

    //------------------------------------------ 帧节拍
    reg [10:0] cyc = 0;
    reg        frame_stb = 0;
    always @(posedge clk) begin
        cyc       <= (cyc == N_CYC - 1) ? 11'd0 : (cyc + 11'd1);
        frame_stb <= (cyc == N_CYC - 1);
    end

    //------------------------------------------ 时隙时序
    wire [1:0] slot;
    wire       slot_vld;
    wire [1:0] phase;
    wire       frame_done;

    voice_slot_seq #(.G(G), .N_CYC(N_CYC), .STRIDE(STRIDE), .SW(2)) u_sq (
        .clk(clk), .rst_n_sync(rst_n), .frame_stb(frame_stb),
        .slot(slot), .slot_vld(slot_vld), .phase(phase), .frame_done(frame_done)
    );

    //------------------------------------------ 声部取数（只分配 voice 0）
    reg         awr = 0;
    reg  [4:0]  awr_id = 0;
    reg  [6:0]  awr_note = 7'd60;
    reg  [6:0]  awr_vel = 7'd100;
    reg  [3:0]  awr_ch = 4'd0;
    reg  [2:0]  awr_timbre = 3'd1;        // 用槽 1，便于和"邻位空闲=槽0"区分
    reg         awr_gate = 1'b1;
    reg  [15:0] awr_vel_gain = 16'd32768;
    reg  [7:0]  awr_age = 8'd0;
    reg         awr_fast_rel = 1'b0;
    wire        awr_ready;

    wire [P*32-1:0] pf_phase_inc;
    wire [P*3-1:0]  pf_timbre;
    wire [P*7-1:0]  pf_note;
    wire [P*16-1:0] pf_vel_gain, pf_vca_gain;
    wire [P*4-1:0]  pf_ch;
    wire [P-1:0]    pf_gate, pf_fast_rel, pf_sust_pedal;
    wire            pf_vld;

    voice_fetch #(.P(P), .G(G), .N(N), .NCH(NCH)) u_vf (
        .clk(clk), .rst_n_sync(rst_n), .frame_stb(frame_stb),
        .slot(slot), .slot_vld(slot_vld),
        .awr(awr), .awr_id(awr_id), .awr_note(awr_note), .awr_vel(awr_vel),
        .awr_ch(awr_ch), .awr_timbre(awr_timbre), .awr_gate(awr_gate),
        .awr_vel_gain(awr_vel_gain), .awr_age(awr_age),
        .awr_fast_rel(awr_fast_rel), .awr_ready(awr_ready),
        .rs_wr(1'b0), .rs_id(5'd0), .rs_data(139'd0),
        .scan_addr(5'd0), .scan_req(1'b0), .scan_env_state(),
        .ch_sust_pedal({NCH{1'b0}}),
        //  ⚠ 必须是 Q2.14 的 1.0（16384）。接 0 会让 apply_ratio 输出 0
        //     → phase_inc 恒 0 → 相位不动、完全没声音（第一次跑就踩了这个）。
        .ch_bend_ratio({NCH{16'd16384}}),
        .ch_vib_ratio({NCH{16'd16384}}),
        .pf_phase_inc(pf_phase_inc), .pf_timbre(pf_timbre), .pf_note(pf_note),
        .pf_vel_gain(pf_vel_gain), .pf_vca_gain(pf_vca_gain), .pf_ch(pf_ch),
        .pf_gate(pf_gate), .pf_fast_rel(pf_fast_rel),
        .pf_sust_pedal(pf_sust_pedal), .pf_vld(pf_vld)
    );

    initial begin
        wait (rst_n);
        repeat (4) @(posedge clk);
        awr = 1'b1;
        @(posedge clk);
        awr = 1'b0;
        $display("[%0t] 已发出分配请求：voice 0 / note 60 / gate=1 / timbre=1", $time);
    end

    //------------------------------------------ 泳道 0 的波表取数
    wire [13:0]      rom_addr_n, rom_addr_n1;
    wire [P*16-1:0]  tab_n, tab_n1;
    wire             rdy;
    wire [P*14-1:0]  addr_n_flat, addr_n1_flat;

    assign addr_n_flat  = {{(P-1){14'd0}}, rom_addr_n};
    assign addr_n1_flat = {{(P-1){14'd0}}, rom_addr_n1};

    wave_fetch #(.P(P), .AW(14), .DW(16), .INIT_FILE("data/wave_table.hex")) u_wf (
        .clk(clk), .rst_n_sync(rst_n), .sample_en(slot_vld),
        .addr_n_flat(addr_n_flat), .addr_n1_flat(addr_n1_flat),
        .rdy(rdy), .tab_n_flat(tab_n), .tab_n1_flat(tab_n1)
    );

    //------------------------------------------ 泳道 0 的单声部
    wire signed [23:0] voice_out;
    wire [31:0]        phase_acc;
    wire [15:0]        env_value;
    wire [2:0]         env_state;
    wire signed [31:0] filter_ic1, filter_ic2;
    wire               data_vld, data_gate;
    wire [3:0]         data_ch;

    voice_mono u_voice (
        .clk(clk), .rst_async_n(rst_n), .sample_en(slot_vld),
        .slot(slot),                          // 方案 A：4 份状态的选择子
        .phase_inc(pf_phase_inc[31:0]),
        .wave_sel(2'd0),
        .timbre_slot(pf_timbre[2:0]),
        .f_coeff(16'd30000), .q_coeff(16'd22000), .filter_type(2'd0),   // 钢琴槽 0 的实际参数
        .gate(pf_gate[0]),
        .sustain_pedal(pf_sust_pedal[0]),
        .adsr_curve(2'd0),
        .attack_step(16'd3000),        // 故意放大，几帧内就能看到 SUSTAIN
        .decay_step(16'd3000),
        .sustain_level(16'd24000),
        .release_step(16'd2),
        .velocity_gain(pf_vel_gain[15:0]),
        .vca_gain(pf_vca_gain[15:0]),
        .tab_n($signed(tab_n[15:0])), .tab_n1($signed(tab_n1[15:0])),
        .samples_rdy(rdy),
        .rom_addr_n(rom_addr_n), .rom_addr_n1(rom_addr_n1),
        .voice_out(voice_out),
        .phase_acc(phase_acc), .env_value(env_value), .env_state(env_state),
        .filter_ic1(filter_ic1), .filter_ic2(filter_ic2),
        .data_vld(data_vld), .ch_in(4'd0),
        .data_gate(data_gate), .data_ch(data_ch)
    );

    //------------------------------------------ 探针：每个 vca_en 一行
    integer n = 0;
    integer n_diff = 0;
    integer n_tot  = 0;
    reg signed [23:0] prev_out = 24'sd0;

    always @(posedge clk) begin
        if (rst_n && u_voice.vca_en) begin
            n_tot = n_tot + 1;
            if (pf_gate[0] !== data_gate) n_diff = n_diff + 1;
            if (n < 40) begin
                $display("  [%0t] slot=%0d  pf_gate=%b lat_gate=%b  envst=%0d env=%0d  phacc=%0d  out=%0d",
                         $time, slot, pf_gate[0], data_gate,
                         env_state, env_value, phase_acc, voice_out);
                n = n + 1;
            end
        end
    end

    //------------------------------------------ 探针 2：data_vld 时刻（chan_buf 采样的那一拍）
    //  这是"没声音"的直接判据：data_vld 时 voice_out 必须已经是**本时隙**刚算出的值。
    integer m = 0;
    integer n_zero_when_gate = 0;
    integer n_gated_dv = 0;
    integer max_gated = 0;
    integer n_sat = 0;          // voice_out 撞到 sat24 上限的次数（削波证据）
    always @(posedge clk) begin
        if (rst_n && data_vld) begin
            if (data_gate) begin
                n_gated_dv = n_gated_dv + 1;
                if ((voice_out > max_gated) || (-voice_out > max_gated))
                    max_gated = (voice_out > 0) ? voice_out : -voice_out;
                if ((voice_out >= 24'sd8388600) || (voice_out <= -24'sd8388600))
                    n_sat = n_sat + 1;
                if (voice_out == 24'sd0)
                    n_zero_when_gate = n_zero_when_gate + 1;
            end
            if (m < 16) begin
                $display("  [%0t] DV slot=%0d gate=%b env=%0d svf=%0d g_vt=%0d | p40=%0d norm=%0d sat=%0d audio_out=%0d out=%0d",
                         $time, slot, data_gate,
                         u_voice.env_value, u_voice.svf_out, u_voice.u_adsr_vca.g_vt,
                         u_voice.u_adsr_vca.p40, u_voice.u_adsr_vca.norm,
                         u_voice.u_adsr_vca.vca_sat,
                         u_voice.u_adsr_vca.audio_out, voice_out);
                m = m + 1;
            end
        end
    end

    //  —— 2026-10-22 加：dump voice_out 与 DDS 输出，供离线频谱分析
    //     判据：voice_out 的谐波应该 ≈ 波表本身的谐波（钢琴=基频+4 次谐波）。
    //     若出现一大堆谐波/噪声 → 声部层在"制造"失真，与幅度无关。
    integer fd_v;
    initial fd_v = $fopen("D:/code/fpga-synthesizer/folder-reorg/scratch/agent/probe_voice.txt", "w");
    always @(posedge clk) begin
        if (rst_n && data_vld && data_gate)
            $fwrite(fd_v, "%0d %0d\n", $signed(voice_out), $signed(u_voice.dbg_wave));
    end

    //------------------------------------------ 逐拍 trace（定位沿对齐）
    always @(posedge clk) begin
        if (rst_n && $time >= 62000 && $time <= 62120)
            $display("    t=%0t slot=%0d rdy=%b d1=%b d5=%b dvld=%b | env=%0d svf=%0d sat=%0d aout=%0d",
                     $time, slot, rdy, u_voice.rdy_d1, u_voice.rdy_d5, data_vld,
                     u_voice.env_value, u_voice.svf_out,
                     u_voice.u_adsr_vca.vca_sat, u_voice.u_adsr_vca.audio_out);
    end

    //------------------------------------------ 收尾统计
    integer f;
    initial begin
        wait (rst_n);
        for (f = 0; f < 10000; f = f + 1) @(posedge frame_stb);
        $display("");
        $display("=== 统计 ===");
        $display("  vca_en 次数 = %0d（每帧应为 4）", n_tot);
        $display("  pf_gate 与锁存 gate 不一致的次数 = %0d / %0d", n_diff, n_tot);
        $display("  pf_phase_inc[31:0] = %0d", pf_phase_inc[31:0]);
        $display("  pf_timbre[2:0]     = %0d", pf_timbre[2:0]);
        $display("  phase_acc          = %0d", phase_acc);
        $display("  env_state/env      = %0d / %0d", env_state, env_value);
        $display("  gate=1 的 data_vld 次数 = %0d，其中输出为 0 的 = %0d", n_gated_dv, n_zero_when_gate);
        $display("  gate=1 时 |voice_out| 最大值 = %0d", max_gated);
        $display("  gate=1 时撞满量程(sat24)的次数 = %0d  ← 非 0 就是声部层在削波", n_sat);
        if (n_diff > 0)
            $display("  结论：ADSR/SVF 拿到的是**下一个时隙声部**的参数（差一个时隙）");
        else
            $display("  结论：参数与本声部同拍，不存在差一个时隙");
        $finish;
    end

endmodule
