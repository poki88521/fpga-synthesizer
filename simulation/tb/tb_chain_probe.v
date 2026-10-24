//============================================================================
//  tb_chain_probe —— 干路（声部 → 通道层 → 主混音）数字域探针
//
//  目的：上板实测到"失真与音量无关"，说明不是削波；而声部层（DDS+SVF+VCA）
//        在仿真里已经证明有干净的谐波结构。本 TB 把**通道层 + 主混音**也接进来，
//        看干路输出里有没有"错误样本 / 跳变"。
//
//  链路（与 full_system 的正常模式同构，只去掉 FX 与 MIDI）：
//      voice_slot_seq → voice_fetch → voice_mono → chan_layer → main_mix
//                                     └→ wave_fetch → wave_table_rom
//  接法与 full_top 一致：chan_layer 的 slot_vld/vld/ch_in/aud_in 来自
//      voice_mono 的 data_vld / data_gate / data_ch / voice_out（只用泳道 0）
//
//  ⚠ FX 输入全部接 0（fx_vld=1），所以这里量的是**干路**。
//
//  输出：
//      scratch/agent/probe_chain.txt   每帧一行：ch_l 流（按 ch_addr 取通道 0）与 main_l
//============================================================================
`timescale 1ns/1ps

module tb_chain_probe;

    localparam integer P      = 8;
    localparam integer G      = 4;
    localparam integer STRIDE = 32;
    localparam integer N_CYC  = 1024;
    localparam integer NCH    = 16;
    localparam integer N      = P * G;
    localparam integer NFRAME = 3000;          // 3000 帧 = 62.5 ms

    reg clk = 0;
    always #10 clk = ~clk;                     // 50 MHz → 帧率 48.828 kHz

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
    wire [1:0] slot, phase;
    wire       slot_vld, frame_done;

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
    reg  [2:0]  awr_timbre = 3'd0;            // 槽 0 = 钢琴（主用例）
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
        $display("[%0t] 分配 voice 0 / note 60 / gate=1 / timbre=0", $time);
    end

    //------------------------------------------ 波表取数
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
    wire signed [23:0] dbg_wave;

    voice_mono u_voice (
        .clk(clk), .rst_async_n(rst_n), .sample_en(slot_vld), .slot(slot),
        .phase_inc(pf_phase_inc[31:0]),
        .wave_sel(2'd0), .timbre_slot(pf_timbre[2:0]),
        .f_coeff(16'd30000), .q_coeff(16'd22000), .filter_type(2'd0),   // 钢琴槽参数
        .gate(pf_gate[0]), .sustain_pedal(pf_sust_pedal[0]),
        .adsr_curve(2'd0),
        .attack_step(16'd3000), .decay_step(16'd3000),   // 快速到稳态，便于测稳态波形
        .sustain_level(16'd24000), .release_step(16'd1),
        .velocity_gain(pf_vel_gain[15:0]), .vca_gain(pf_vca_gain[15:0]),
        .tab_n($signed(tab_n[15:0])), .tab_n1($signed(tab_n1[15:0])),
        .samples_rdy(rdy),
        .rom_addr_n(rom_addr_n), .rom_addr_n1(rom_addr_n1),
        .dbg_wave(dbg_wave),
        .voice_out(voice_out),
        .phase_acc(phase_acc), .env_value(env_value), .env_state(env_state),
        .filter_ic1(filter_ic1), .filter_ic2(filter_ic2),
        .data_vld(data_vld), .ch_in(4'd0),
        .data_gate(data_gate), .data_ch(data_ch)
    );

    //------------------------------------------ 通道层（内含 chan_buf + chan_coef）
    wire [P-1:0]     ch_vld_lane = {{(P-1){1'b0}}, data_gate};
    wire [P*4-1:0]   ch_in_lane   = {{(P-1){4'd0}}, data_ch};
    wire [P*24-1:0]  aud_lane     = {{(P-1){24'd0}}, voice_out};

    wire                    ch_vld;
    wire [3:0]              ch_addr;
    wire signed [23:0]      ch_l, ch_r;
    wire                    ch_frame_done;

    chan_layer #(.P(P), .G(G), .AW(24), .CW(4), .NCH(NCH), .SW(2)) u_chl (
        .clk(clk), .rst_n(rst_n), .frame_stb(frame_stb),
        .slot_vld(data_vld), .slot(slot),
        .vld(ch_vld_lane), .ch_in(ch_in_lane), .aud_in(aud_lane),
        .volume({NCH{7'd100}}), .expression({NCH{7'd127}}),
        .pan_gL({NCH{16'sd32767}}), .pan_gR({NCH{16'sd0}}),   // 全左
        .ch_vld(ch_vld), .ch_addr(ch_addr), .ch_l(ch_l), .ch_r(ch_r),
        .frame_done(ch_frame_done)
    );

    //------------------------------------------ 主混音（FX 全 0）
    wire               mix_vld;
    wire signed [23:0] main_l, main_r;

    main_mix #(.NCH(NCH), .AW(24)) u_mix (
        .clk(clk), .rst_n(rst_n), .frame_stb(frame_stb),
        .ch_vld(ch_vld), .ch_addr(ch_addr), .ch_l(ch_l), .ch_r(ch_r),
        .fx_l(24'sd0), .fx_r(24'sd0), .fx_vld(1'b1),
        .mix_vld(mix_vld), .main_l(main_l), .main_r(main_r)
    );

    //------------------------------------------ dump：每帧一行
    integer fd;
    initial fd = $fopen("D:/code/fpga-synthesizer/develop/scratch/agent/probe_chain.txt", "w");
    integer nc = 0;
    always @(posedge clk) begin
        if (rst_n && mix_vld) begin
            $fwrite(fd, "%0d %0d %0d %0d\n",
                    $signed(main_l), $signed(main_r),
                    $signed(ch_l), $signed(voice_out));
            nc = nc + 1;
        end
    end

    //------------------------------------------ 收尾
    initial begin
        wait (rst_n);
        repeat (NFRAME) @(posedge frame_stb);
        $display("帧数=%0d  mix_vld 次数=%0d", NFRAME, nc);
        $display("voice_out 峰值=%0d  env 终值=%0d", dbg_wave, env_value);
        $finish;
    end

    initial begin
        #120_000_000;
        $display("FAIL 超时");
        $finish;
    end

endmodule
