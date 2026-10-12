//============================================================================
//  sched_subsystem —— 调度层集成黑盒（给 full_top 一个模块接完）
//
//  目的：把调度层 9 个模块 + 影子寄存器 + 写回胶水**打包成一个模块**，
//        让 sakiko 不用理解内部结构，只要：
//            · 在 full_top 里引出一根 output wire sample_stb（= pt8211_tx 的）
//            · 例化本模块，给它 clk / rst_n_sync / frame_stb / 4 路 MIDI
//            · 把 ext_* 直接接到 full_top 的 ext_* 端口（EXT_TABLE=1）
//            · 把 pf_* 接到单声部层（P 个 voice_mono）的输入
//            · 把单声部层的运行状态接回 rs_*（见下方位段说明）
//
//  内部结构：
//      midi_parse ×4 → midi_arb → midi_filter ─┬→ chan_table ──┐
//                                              └→ voice_alloc  │
//      voice_slot_seq ────────────────────────→ voice_fetch ←──┘
//      chan_table(P 读口第 0 路) → chan_param_shadow → ext_*
//      写回胶水: rs_* (P 组) → voice_fetch 的单写口 rs_wr/rs_id/rs_data
//
//  ⚠ 时序同相说明（重要）：
//    full_top 内部**也**有一个 voice_slot_seq（它驱动内部 chan_layer）。本模块
//    内部的 voice_slot_seq 与它**参数相同（G/STRIDE）、复位源相同（frame_stb）**，
//    所以两者的 slot/slot_vld **天然同相**，不需要额外同步。
//    若将来 full_top 的 STRIDE/G 变了，这里的参数必须跟着改。
//
//  ⚠ 音色参数（wave_sel / f_coeff / q_coeff / filter_type / adsr_*）暂不在本模块：
//    它们来自音色参数表，目前仓库里还没有这个模块。为了不阻塞集成，单声部层
//    可以先接常量默认值。等音色表落地后，本模块的 pf_* 再扩出这些字段即可。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module sched_subsystem #(
    parameter integer P      = 8,
    parameter integer G      = 4,
    parameter integer NCH    = 16,
    parameter integer STRIDE = 8,          // 必须与 full_top 的 STRIDE 一致
    parameter integer N      = 32,         // 声部数 = P*G
    parameter integer TICK_DIV = 1573      // f_clk / 31250
)(
    input  wire        clk,
    input  wire        rst_n_sync,
    input  wire        frame_stb,          // ← full_top 的 sample_stb

    // ---- MIDI 串行输入（4 路，外部已两级同步）----
    input  wire [3:0]  midi_rx,

    // ---- 时隙信号（输出给 full_top / 单声部层；与 full_top 内部同相）----
    output wire [1:0]  slot,
    output wire        slot_vld,

    // ---- → full_top 的 ext_*（EXT_TABLE=1；帧边界更新，帧内恒定）----
    output wire [NCH*7-1:0]  ext_volume,
    output wire [NCH*7-1:0]  ext_expression,
    output wire [NCH*16-1:0] ext_pan_gL,
    output wire [NCH*16-1:0] ext_pan_gR,
    output wire [NCH*7-1:0]  ext_send_rev,
    output wire [NCH*7-1:0]  ext_send_cho,
    output wire [NCH*7-1:0]  ext_send_del,

    // ---- → 单声部层（P 组预取参数，时隙开始前稳定）----
    //      pf_vld 是"预取寄存器已更新"的单拍脉冲（P 组同时更新），不是每泳道一位；
    //      哪个泳道有效看 pf_gate。
    output wire            pf_vld,
    output wire [P*32-1:0] pf_phase_inc,
    output wire [P*3-1:0]  pf_timbre,
    output wire [P*7-1:0]  pf_note,
    output wire [P*16-1:0] pf_vel_gain,
    output wire [P*16-1:0] pf_vca_gain,
    output wire [P*4-1:0]  pf_ch,
    output wire [P-1:0]    pf_gate,
    output wire [P-1:0]    pf_fast_rel,
    output wire [P-1:0]    pf_sust_pedal,

    // ---- ← 单声部层的运行状态（P 组；本模块在时隙内逐个写回声部表）----
    input  wire [P*32-1:0] rs_phase_acc,
    input  wire [P*16-1:0] rs_env_value,
    input  wire [P*3-1:0]  rs_env_state,
    input  wire [P*32-1:0] rs_filter_ic1,
    input  wire [P*32-1:0] rs_filter_ic2
);
    //========================================================================
    // midi_tick：位节拍（÷1573 = 31250 Hz），内部产生，免得外面再拉一根线
    //========================================================================
    reg [11:0] tick_cnt;
    reg        midi_tick;
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            tick_cnt  <= 12'd0;
            midi_tick <= 1'b0;
        end else begin
            if (tick_cnt == (TICK_DIV-1)) begin
                tick_cnt  <= 12'd0;
                midi_tick <= 1'b1;
            end else begin
                tick_cnt  <= tick_cnt + 12'd1;
                midi_tick <= 1'b0;
            end
        end
    end

    //========================================================================
    // 一、MIDI：4 路解析 → 汇流 → 过滤分发
    //========================================================================
    wire [3:0]  p_msg_vld, p_msg_drop, p_msg_ovf, p_frame_err;
    wire [3:0]  p_sx_start, p_sx_vld, p_sx_err;
    wire [31:0] p_status, p_d0, p_d1, p_sx_byte;
    wire [27:0] p_sx_len;
    wire [3:0]  ack_msg, ack_sx;

    wire        a_msg_vld, a_sx_start, a_sx_vld, a_sx_err;
    wire [7:0]  a_status, a_d0, a_d1, a_sx_byte;
    wire [1:0]  a_port;
    wire [6:0]  a_sx_len;
    wire        f_msg_ack;

    wire        ev_note, ev_note_on, ev_cc_wr, ev_pc, ev_par_wr, drop_vld;
    wire [3:0]  ev_note_ch, ev_cc_ch, ev_pc_ch, ev_par_idx;
    wire [4:0]  ev_cc_field;
    wire [6:0]  ev_note_key, ev_note_vel, ev_pc_prog;
    wire [15:0] ev_cc_val, ev_par_data;
    wire [1:0]  ev_par_grp;

    genvar gm;
    generate
        for (gm = 0; gm < 4; gm = gm + 1) begin : g_parse
            midi_parse #(.PORT_ID(gm[1:0])) u_parse (
                .clk(clk), .rst_n_sync(rst_n_sync), .midi_tick(midi_tick),
                .rx(midi_rx[gm]),
                .msg_ack(ack_msg[gm]), .sysex_ack(ack_sx[gm]),
                .msg_vld(p_msg_vld[gm]), .msg_status(p_status[gm*8 +: 8]),
                .msg_d0(p_d0[gm*8 +: 8]), .msg_d1(p_d1[gm*8 +: 8]),
                .msg_port(), .msg_drop(p_msg_drop[gm]), .msg_ovf(p_msg_ovf[gm]),
                .sysex_start(p_sx_start[gm]), .sysex_len(p_sx_len[gm*7 +: 7]),
                .sysex_vld(p_sx_vld[gm]), .sysex_byte(p_sx_byte[gm*8 +: 8]),
                .sysex_err(p_sx_err[gm]), .frame_err(p_frame_err[gm])
            );
        end
    endgenerate

    midi_arb u_arb (
        .clk(clk), .rst_n_sync(rst_n_sync),
        .in_msg_vld(p_msg_vld), .in_msg_status(p_status),
        .in_msg_d0(p_d0), .in_msg_d1(p_d1),
        .in_sysex_start(p_sx_start), .in_sysex_len(p_sx_len),
        .in_sysex_vld(p_sx_vld), .in_sysex_byte(p_sx_byte), .in_sysex_err(p_sx_err),
        .in_msg_ack(ack_msg), .in_sysex_ack(ack_sx),
        .out_msg_vld(a_msg_vld), .out_msg_status(a_status), .out_msg_d0(a_d0),
        .out_msg_d1(a_d1), .out_msg_port(a_port), .out_msg_ack(f_msg_ack),
        .out_sysex_start(a_sx_start), .out_sysex_len(a_sx_len), .out_sysex_vld(a_sx_vld),
        .out_sysex_byte(a_sx_byte), .out_sysex_err(a_sx_err), .out_sysex_ack(1'b0)
    );

    midi_filter u_filter (
        .clk(clk), .rst_n_sync(rst_n_sync),
        .msg_vld(a_msg_vld), .msg_status(a_status), .msg_d0(a_d0), .msg_d1(a_d1),
        .msg_port(a_port), .msg_ack(f_msg_ack),
        .sysex_start(a_sx_start), .sysex_len(a_sx_len), .sysex_vld(a_sx_vld),
        .sysex_byte(a_sx_byte), .sysex_err(a_sx_err),
        .ev_note(ev_note), .ev_note_on(ev_note_on), .ev_note_ch(ev_note_ch),
        .ev_note_key(ev_note_key), .ev_note_vel(ev_note_vel),
        .ev_cc_wr(ev_cc_wr), .ev_cc_ch(ev_cc_ch), .ev_cc_field(ev_cc_field), .ev_cc_val(ev_cc_val),
        .ev_pc(ev_pc), .ev_pc_ch(ev_pc_ch), .ev_pc_prog(ev_pc_prog),
        .ev_par_wr(ev_par_wr), .ev_par_grp(ev_par_grp), .ev_par_idx(ev_par_idx),
        .ev_par_data(ev_par_data), .drop_vld(drop_vld)
    );

    //========================================================================
    // 二、通道状态表 + 影子寄存器
    //========================================================================
    wire [3:0]  ct_rd_ch;                    // voice_alloc 用它读 max_voices
    wire [6:0]  ct_volume, ct_pan, ct_expression, ct_program, ct_bank_msb, ct_bank_lsb;
    wire [15:0] ct_pan_gL, ct_pan_gR, ct_bend_ratio;
    wire [13:0] ct_bend_value;
    wire [6:0]  ct_bend_range, ct_attack, ct_release, ct_reson, ct_cutoff;
    wire [6:0]  ct_srev, ct_scho, ct_sdel;
    wire        ct_sust, ct_sost;
    wire [7:0]  ct_default_timbre;
    wire [5:0]  ct_max_voices, ct_note_count;
    wire        ct_wr_ovf, ct_dumping, ct_fifo_empty;

    wire [P*4-1:0]  prd_ch_bus;               // 第 0 路给影子模块扫描
    wire [P*16-1:0] prd_pan_gL, prd_pan_gR;
    wire [P*7-1:0]  prd_volume, prd_expression, prd_srev, prd_scho, prd_sdel;
    wire [P-1:0]    prd_sust_pedal;

    wire [3:0]  cps_scan_ch;
    wire [NCH-1:0] ch_sust_pedal_bus;

    // 分配器写回通道表的 note_count（直接写当前 bank）
    wire        va_nc_wr; wire [3:0] va_nc_ch; wire [5:0] va_nc_val;
    // 分配器 ↔ 取数器的扫描口
    wire [4:0]  va_scan_addr; wire va_scan_req; wire [2:0] vf_scan_env_state;
    // 分配写请求
    wire        va_awr; wire [4:0] va_awr_id; wire [6:0] va_awr_note, va_awr_vel;
    wire [3:0]  va_awr_ch; wire [2:0] va_awr_timbre; wire va_awr_gate;
    wire [15:0] va_awr_vg; wire [7:0] va_awr_age; wire va_awr_fast;
    wire [6:0]  va_evt_dout; wire va_evt_empty, va_evt_full;
    // 事件 FIFO 由本模块自己消费（帧边界之后读空，避免堆积）
    reg         va_evt_rd;

    chan_table #(.P(P), .NCH(NCH)) u_ct (
        .clk(clk), .rst_n_sync(rst_n_sync), .frame_stb(frame_stb),
        .ev_cc_wr(ev_cc_wr), .ev_cc_ch(ev_cc_ch), .ev_cc_field(ev_cc_field), .ev_cc_val(ev_cc_val),
        .ev_pc(ev_pc), .ev_pc_ch(ev_pc_ch), .ev_pc_prog(ev_pc_prog),
        .alloc_wr(va_nc_wr), .alloc_ch(va_nc_ch), .alloc_nc(va_nc_val),
        .cfg_wr(1'b0), .cfg_ch(4'd0), .cfg_default_timbre(8'd0), .cfg_max_voices(6'd0),
        .rd_ch(ct_rd_ch),
        .rd_volume(ct_volume), .rd_pan(ct_pan), .rd_pan_gL(ct_pan_gL), .rd_pan_gR(ct_pan_gR),
        .rd_expression(ct_expression), .rd_bend_ratio(ct_bend_ratio),
        .rd_bend_value(ct_bend_value), .rd_bend_range(ct_bend_range),
        .rd_program(ct_program), .rd_bank_msb(ct_bank_msb), .rd_bank_lsb(ct_bank_lsb),
        .rd_default_timbre(ct_default_timbre), .rd_max_voices(ct_max_voices),
        .rd_note_count(ct_note_count),
        .rd_sustain_pedal(ct_sust), .rd_sostenuto_pedal(ct_sost),
        .rd_attack_mod(ct_attack), .rd_release_mod(ct_release),
        .rd_resonance_mod(ct_reson), .rd_cutoff_mod(ct_cutoff),
        .rd_send_reverb(ct_srev), .rd_send_chorus(ct_scho), .rd_send_delay(ct_sdel),
        .prd_ch(prd_ch_bus),
        .prd_pan_gL(prd_pan_gL), .prd_pan_gR(prd_pan_gR),
        .prd_volume(prd_volume), .prd_expression(prd_expression),
        .prd_send_reverb(prd_srev), .prd_send_chorus(prd_scho), .prd_send_delay(prd_sdel),
        .prd_sust_pedal(prd_sust_pedal),
        .wr_ovf(ct_wr_ovf), .dumping(ct_dumping), .fifo_empty(ct_fifo_empty)
    );

    assign prd_ch_bus = { {(P-1){4'd0}}, cps_scan_ch };

    chan_param_shadow #(.NCH(NCH)) u_cps (
        .clk(clk), .rst_n_sync(rst_n_sync), .frame_stb(frame_stb),
        .rd_ch(cps_scan_ch),
        .rd_volume      (prd_volume    [0*7  +: 7 ]),
        .rd_expression  (prd_expression[0*7  +: 7 ]),
        .rd_pan_gL      (prd_pan_gL    [0*16 +: 16]),
        .rd_pan_gR      (prd_pan_gR    [0*16 +: 16]),
        .rd_send_reverb (prd_srev      [0*7  +: 7 ]),
        .rd_send_chorus (prd_scho      [0*7  +: 7 ]),
        .rd_send_delay  (prd_sdel      [0*7  +: 7 ]),
        .rd_sustain_pedal(prd_sust_pedal[0]),
        .ext_volume(ext_volume), .ext_expression(ext_expression),
        .ext_pan_gL(ext_pan_gL), .ext_pan_gR(ext_pan_gR),
        .ext_send_rev(ext_send_rev), .ext_send_cho(ext_send_cho), .ext_send_del(ext_send_del),
        .ch_sust_pedal(ch_sust_pedal_bus)
    );

    //========================================================================
    // 三、声部分配器
    //========================================================================
    voice_alloc #(.P(P), .G(G), .N(N), .NCH(NCH)) u_va (
        .clk(clk), .rst_n_sync(rst_n_sync), .frame_stb(frame_stb),
        .ev_note(ev_note), .ev_note_on(ev_note_on), .ev_note_ch(ev_note_ch),
        .ev_note_key(ev_note_key), .ev_note_vel(ev_note_vel),
        .cc_action(2'd0), .cc_ch(4'd0),
        .ch_rd_addr(ct_rd_ch), .ch_max_voices(ct_max_voices),
        //  ⚠ 2026-10-09：把该通道的 bank_msb / program 一起给分配器，
        //     供它内部的 timbre_map 决定音色槽（原先直接用 note[2:0]，
        //     导致 Program Change 无效）。这两个信号与 ch_max_voices 来自
        //     chan_table 的**同一个读口**，所以 S_DEC 那拍取到的就是目标通道的值。
        .ch_bank_msb(ct_bank_msb), .ch_prog_num(ct_program),
        .nc_wr(va_nc_wr), .nc_ch(va_nc_ch), .nc_val(va_nc_val),
        .scan_addr(va_scan_addr), .scan_req(va_scan_req), .scan_env_state(vf_scan_env_state),
        .awr(va_awr), .awr_id(va_awr_id), .awr_note(va_awr_note), .awr_vel(va_awr_vel),
        .awr_ch(va_awr_ch), .awr_timbre(va_awr_timbre), .awr_gate(va_awr_gate),
        .awr_vel_gain(va_awr_vg), .awr_age(va_awr_age), .awr_fast_rel(va_awr_fast),
        .evt_dout(va_evt_dout), .evt_empty(va_evt_empty), .evt_full(va_evt_full),
        .evt_rd(va_evt_rd)
    );

    //========================================================================
    // 四、时隙时序器（与 full_top 内部那个同参数、同复位源 → 天然同相）
    //========================================================================
    voice_slot_seq #(.G(G), .STRIDE(STRIDE)) u_sq (
        .clk(clk), .rst_n_sync(rst_n_sync), .frame_stb(frame_stb),
        .slot(slot), .slot_vld(slot_vld)
    );

    //========================================================================
    // 五、取数器（预取 + 写回）
    //========================================================================
    // 写回胶水：时隙开始后，用 P 拍把 P 个泳道的运行状态逐个写进 voice_fetch
    reg [3:0]  wb_ph;
    reg        wb_en;
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            wb_ph <= 4'd0;
            wb_en <= 1'b0;
        end else begin
            if (slot_vld) begin
                wb_ph <= 4'd0;
                wb_en <= 1'b1;
            end else if (wb_en) begin
                if (wb_ph == P[3:0] - 4'd1) wb_en <= 1'b0;
                else                        wb_ph <= wb_ph + 4'd1;
            end
        end
    end

    // P 选 1：按 wb_ph 选出该泳道的运行状态（用 case 展开，避免变量 indexed part-select）
    reg [31:0] wb_phase_acc, wb_ic1, wb_ic2;
    reg [15:0] wb_env_value;
    reg [2:0]  wb_env_state;
    always @(*) begin
        case (wb_ph[2:0])
            3'd0: begin
                wb_phase_acc = rs_phase_acc[0*32 +: 32];
                wb_env_value = rs_env_value[0*16 +: 16];
                wb_env_state = rs_env_state[0*3  +: 3 ];
                wb_ic1       = rs_filter_ic1[0*32 +: 32];
                wb_ic2       = rs_filter_ic2[0*32 +: 32];
            end
            3'd1: begin
                wb_phase_acc = rs_phase_acc[1*32 +: 32];
                wb_env_value = rs_env_value[1*16 +: 16];
                wb_env_state = rs_env_state[1*3  +: 3 ];
                wb_ic1       = rs_filter_ic1[1*32 +: 32];
                wb_ic2       = rs_filter_ic2[1*32 +: 32];
            end
            3'd2: begin
                wb_phase_acc = rs_phase_acc[2*32 +: 32];
                wb_env_value = rs_env_value[2*16 +: 16];
                wb_env_state = rs_env_state[2*3  +: 3 ];
                wb_ic1       = rs_filter_ic1[2*32 +: 32];
                wb_ic2       = rs_filter_ic2[2*32 +: 32];
            end
            3'd3: begin
                wb_phase_acc = rs_phase_acc[3*32 +: 32];
                wb_env_value = rs_env_value[3*16 +: 16];
                wb_env_state = rs_env_state[3*3  +: 3 ];
                wb_ic1       = rs_filter_ic1[3*32 +: 32];
                wb_ic2       = rs_filter_ic2[3*32 +: 32];
            end
            3'd4: begin
                wb_phase_acc = rs_phase_acc[4*32 +: 32];
                wb_env_value = rs_env_value[4*16 +: 16];
                wb_env_state = rs_env_state[4*3  +: 3 ];
                wb_ic1       = rs_filter_ic1[4*32 +: 32];
                wb_ic2       = rs_filter_ic2[4*32 +: 32];
            end
            3'd5: begin
                wb_phase_acc = rs_phase_acc[5*32 +: 32];
                wb_env_value = rs_env_value[5*16 +: 16];
                wb_env_state = rs_env_state[5*3  +: 3 ];
                wb_ic1       = rs_filter_ic1[5*32 +: 32];
                wb_ic2       = rs_filter_ic2[5*32 +: 32];
            end
            3'd6: begin
                wb_phase_acc = rs_phase_acc[6*32 +: 32];
                wb_env_value = rs_env_value[6*16 +: 16];
                wb_env_state = rs_env_state[6*3  +: 3 ];
                wb_ic1       = rs_filter_ic1[6*32 +: 32];
                wb_ic2       = rs_filter_ic2[6*32 +: 32];
            end
            default: begin
                wb_phase_acc = rs_phase_acc[7*32 +: 32];
                wb_env_value = rs_env_value[7*16 +: 16];
                wb_env_state = rs_env_state[7*3  +: 3 ];
                wb_ic1       = rs_filter_ic1[7*32 +: 32];
                wb_ic2       = rs_filter_ic2[7*32 +: 32];
            end
        endcase
    end

    // 139 位回写包：phase_acc(32) + env_value(16) + env_state(3) + ic1(32) + ic2(32) + lfo(24)
    wire [138:0] wb_data = { 24'd0, wb_ic2, wb_ic1, wb_env_state, wb_env_value, wb_phase_acc };
    wire [4:0]   wb_id   = { slot, wb_ph[2:0] };
    wire         wb_wr   = wb_en;

    voice_fetch #(.P(P), .G(G), .N(N), .NCH(NCH)) u_vf (
        .clk(clk), .rst_n_sync(rst_n_sync), .frame_stb(frame_stb),
        .slot(slot), .slot_vld(slot_vld),
        .awr(va_awr), .awr_id(va_awr_id), .awr_note(va_awr_note), .awr_vel(va_awr_vel),
        .awr_ch(va_awr_ch), .awr_timbre(va_awr_timbre), .awr_gate(va_awr_gate),
        .awr_vel_gain(va_awr_vg), .awr_age(va_awr_age), .awr_fast_rel(va_awr_fast),
        .awr_ready(),
        .rs_wr(wb_wr), .rs_id(wb_id), .rs_data(wb_data),
        .scan_addr(va_scan_addr), .scan_req(va_scan_req), .scan_env_state(vf_scan_env_state),
        .ch_sust_pedal(ch_sust_pedal_bus),
        .pf_phase_inc(pf_phase_inc), .pf_timbre(pf_timbre), .pf_note(pf_note),
        .pf_vel_gain(pf_vel_gain), .pf_vca_gain(pf_vca_gain), .pf_ch(pf_ch),
        .pf_gate(pf_gate), .pf_fast_rel(pf_fast_rel),
        .pf_sust_pedal(pf_sust_pedal), .pf_vld(pf_vld)
    );

    //========================================================================
    // 六、分配事件 FIFO：本模块自己消费（帧边界之后读空），不让它堆满
    //     （voice_slot_seq / voice_fetch 的消费逻辑在 RTL 里另有约定，
    //       这里只保证 FIFO 不被撑爆；语义上"事件已在 awr 里体现"。）
    //========================================================================
    reg [1:0] evt_drain;
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            va_evt_rd  <= 1'b0;
            evt_drain  <= 2'd0;
        end else begin
            va_evt_rd <= 1'b0;
            if (frame_stb) evt_drain <= 2'd3;              // 帧边界后连读 3 拍
            else if (evt_drain != 2'd0) begin
                va_evt_rd <= ~va_evt_empty;
                evt_drain <= evt_drain - 2'd1;
            end
        end
    end

    // 调试用（未使用信号的占位，避免综合告警）
    wire _unused = |{p_msg_drop, p_msg_ovf, p_frame_err, p_sx_err,
                     ct_wr_ovf, ct_dumping, ct_fifo_empty, drop_vld, ev_par_wr,
                     va_evt_dout, va_evt_full, ct_bend_ratio, ct_bend_value,
                     ct_bend_range, ct_attack, ct_release, ct_reson, ct_cutoff,
                     ct_volume, ct_pan, ct_expression, ct_program,
                     ct_bank_msb, ct_bank_lsb, ct_pan_gL, ct_pan_gR,
                     ct_default_timbre, ct_note_count, ct_sust, ct_sost,
                     ev_note_ch, ev_cc_ch, ev_pc_ch, ev_par_idx, ev_par_grp, ev_par_data};

endmodule
`default_nettype wire
