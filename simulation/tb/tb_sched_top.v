//============================================================================
//  tb_sched_top —— 调度层顶层联调
//
//  把调度层 8 个模块串起来，跑真实场景，验证跨模块时序假设：
//    midi_parse → midi_arb → midi_filter ─┬→ chan_table ──→ (读口)
//                                          └→ voice_alloc ──→ voice_fetch
//    voice_slot_seq ──────────────────────────────────────→ voice_fetch
//
//  场景：
//    ① Note On 走完整条事件路径：分配声部 → frame_stb 提交 → 预取能看到 gate/note
//    ② CC volume 走 chan_table：下一帧读口能看到新值
//    ③ Note Off：gate 回 0（预取反映）
//
//  frame_stb 由本 TB 产生（真实系统里来自 pt8211_tx.sample_stb）。
//  驱动规范：输入一律在 negedge 更新。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_sched_top;
    localparam real    TCLK   = 20.345;
    localparam integer BITCLK = 1573;
    parameter P = 8, G = 4, N = 32;

    reg clk = 0;
    always #(TCLK/2.0) clk = ~clk;

    reg rst_n = 0;
    reg midi_tick = 0;

    integer tc = 0;
    always @(posedge clk) begin
        midi_tick <= 1'b0;
        if (tc == BITCLK-1) begin tc <= 0; midi_tick <= 1'b1; end
        else                     tc <= tc + 1;
    end

    // frame_stb 发生器（真实系统来自 I2S 采样脉冲）
    reg       frame_stb = 0;
    integer   fc = 0;
    always @(posedge clk) begin
        frame_stb <= 1'b0;
        if (fc == 1023) begin fc <= 0; frame_stb <= 1'b1; end
        else                  fc <= fc + 1;
    end

    //============================================================== MIDI 输入
    reg  rx = 1;
    wire pm_vld, ps_start, ps_vld, ps_err;
    wire [7:0] pst, pd0, pd1, psb;
    wire [6:0] psl;
    wire [3:0] ack_msg, ack_sx;

    //============================================================== arb
    // 注意：接在 arb 的**位 3**，这样 arb 输出的 port=3，midi_filter 才会把它当
    // "混音器端口"。乐器端口（port≠3）会按设计丢弃 CC 7/10/91/93/94，
    // 而联调要测 CC volume 能否进 chan_table。
    wire [3:0] in_msg_vld    = {pm_vld, 1'b0, 1'b0, 1'b0};
    wire [31:0] in_msg_status= {pst, 8'd0, 8'd0, 8'd0};
    wire [31:0] in_msg_d0    = {pd0, 8'd0, 8'd0, 8'd0};
    wire [31:0] in_msg_d1    = {pd1, 8'd0, 8'd0, 8'd0};
    wire [3:0] in_sx_start   = {ps_start, 1'b0, 1'b0, 1'b0};
    wire [27:0] in_sx_len    = {psl, 7'd0, 7'd0, 7'd0};
    wire [3:0] in_sx_vld     = {ps_vld, 1'b0, 1'b0, 1'b0};
    wire [31:0] in_sx_byte   = {psb, 8'd0, 8'd0, 8'd0};
    wire [3:0] in_sx_err     = {ps_err, 1'b0, 1'b0, 1'b0};

    wire a_msg_vld, a_sx_start, a_sx_vld, a_sx_err;
    wire [7:0] a_status, a_d0, a_d1, a_sx_byte;
    wire [1:0] a_port;
    wire [6:0] a_sx_len;
    wire       f_msg_ack;

    //============================================================== filter
    wire       ev_note, ev_note_on, ev_cc_wr, ev_pc, ev_par_wr, drop_vld;
    wire [3:0] ev_note_ch, ev_cc_ch, ev_pc_ch, ev_par_idx;
    wire [4:0] ev_cc_field;
    wire [6:0] ev_note_key, ev_note_vel, ev_pc_prog;
    wire [15:0] ev_cc_val, ev_par_data;
    wire [1:0] ev_par_grp;

    //============================================================== chan_table
    // 通道表读口地址由 voice_alloc 驱动（它要读"要分配的那个通道"的 max_voices）
    wire [6:0] ct_volume, ct_pan;
    wire [5:0] ct_max_voices, ct_note_count;
    wire [7:0] ct_default_timbre;
    wire [15:0] ct_pan_gL, ct_pan_gR, ct_bend_ratio;
    wire [13:0] ct_bend_value;
    wire [6:0]  ct_expression, ct_program, ct_bank_msb, ct_bank_lsb, ct_bend_range;
    wire [6:0]  ct_attack, ct_release, ct_reson, ct_cutoff, ct_srev, ct_scho, ct_sdel;
    wire        ct_sust, ct_sost;
    wire        ct_wr_ovf, ct_dumping, ct_fifo_empty;
    wire [P*16-1:0] prd_pan_gL, prd_pan_gR;
    wire [P*7-1:0]  prd_volume, prd_expression, prd_srev, prd_scho, prd_sdel;
    wire [P-1:0]    prd_sust_pedal;
    wire [3:0]      cps_scan_ch;                  // 影子模块的扫描地址
    wire [15:0]     ch_sust_pedal_bus;            // 16 个通道的延音踏板
    wire [P-1:0]    pf_sust_pedal;
    // P 个并行读口的第 0 路给影子模块扫描用（其余接 0）
    wire [P*4-1:0]  prd_ch_bus = { {(P-1){4'd0}}, cps_scan_ch };

    //============================================================== voice_alloc
    wire [3:0]  va_ch_rd_addr;
    wire        va_nc_wr; wire [3:0] va_nc_ch; wire [5:0] va_nc_val;
    wire [4:0]  va_scan_addr;
    wire        va_scan_req;
    wire [2:0]  vf_scan_env_state;
    wire        va_awr; wire [4:0] va_awr_id;
    wire [6:0]  va_awr_note, va_awr_vel;
    wire [3:0]  va_awr_ch; wire [2:0] va_awr_timbre;
    wire        va_awr_gate; wire [15:0] va_awr_vg; wire [7:0] va_awr_age;
    wire        va_awr_fast;
    wire [6:0]  va_evt_dout; wire va_evt_empty, va_evt_full;
    reg         va_evt_rd = 0;

    //============================================================== slot_seq / fetch
    wire [1:0] sq_slot;
    wire       sq_slot_vld;
    wire [P*32-1:0] pf_phase_inc;
    wire [P*3-1:0]  pf_timbre;
    wire [P*7-1:0]  pf_note;
    wire [P*16-1:0] pf_vel_gain, pf_vca_gain;
    wire [P*4-1:0]  pf_ch;
    wire [P-1:0]    pf_gate, pf_fast_rel;
    wire            pf_vld;
    wire            vf_awr_ready;

    //============================================================== 例化
    midi_parse #(.PORT_ID(2'd0)) u_parse (
        .clk(clk), .rst_n_sync(rst_n), .midi_tick(midi_tick), .rx(rx),
        // parse 接在 arb 的位 3，ack 也必须从位 3 回落 —— 接错会让解析器在第一条
        // 消息之后永远等不到 ack，后续消息全部收不到（本次联调踩过）。
        .msg_ack(ack_msg[3]), .sysex_ack(ack_sx[3]),
        .msg_vld(pm_vld), .msg_status(pst), .msg_d0(pd0), .msg_d1(pd1),
        .msg_port(), .msg_drop(), .msg_ovf(),
        .sysex_start(ps_start), .sysex_len(psl), .sysex_vld(ps_vld),
        .sysex_byte(psb), .sysex_err(ps_err), .frame_err()
    );

    midi_arb u_arb (
        .clk(clk), .rst_n_sync(rst_n),
        .in_msg_vld(in_msg_vld), .in_msg_status(in_msg_status),
        .in_msg_d0(in_msg_d0), .in_msg_d1(in_msg_d1),
        .in_sysex_start(in_sx_start), .in_sysex_len(in_sx_len),
        .in_sysex_vld(in_sx_vld), .in_sysex_byte(in_sx_byte), .in_sysex_err(in_sx_err),
        .in_msg_ack(ack_msg), .in_sysex_ack(ack_sx),
        .out_msg_vld(a_msg_vld), .out_msg_status(a_status), .out_msg_d0(a_d0),
        .out_msg_d1(a_d1), .out_msg_port(a_port), .out_msg_ack(f_msg_ack),
        .out_sysex_start(a_sx_start), .out_sysex_len(a_sx_len), .out_sysex_vld(a_sx_vld),
        .out_sysex_byte(a_sx_byte), .out_sysex_err(a_sx_err), .out_sysex_ack(1'b0)
    );

    midi_filter u_filter (
        .clk(clk), .rst_n_sync(rst_n),
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

    chan_table #(.P(P)) u_ct (
        .clk(clk), .rst_n_sync(rst_n), .frame_stb(frame_stb),
        .ev_cc_wr(ev_cc_wr), .ev_cc_ch(ev_cc_ch), .ev_cc_field(ev_cc_field), .ev_cc_val(ev_cc_val),
        .ev_pc(ev_pc), .ev_pc_ch(ev_pc_ch), .ev_pc_prog(ev_pc_prog),
        .alloc_wr(va_nc_wr), .alloc_ch(va_nc_ch), .alloc_nc(va_nc_val),
        .cfg_wr(1'b0), .cfg_ch(4'd0), .cfg_default_timbre(8'd0), .cfg_max_voices(6'd0),
        .rd_ch(va_ch_rd_addr),
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

    voice_alloc #(.P(P), .G(G), .N(N)) u_va (
        .clk(clk), .rst_n_sync(rst_n), .frame_stb(frame_stb),
        .ev_note(ev_note), .ev_note_on(ev_note_on), .ev_note_ch(ev_note_ch),
        .ev_note_key(ev_note_key), .ev_note_vel(ev_note_vel),
        .cc_action(2'd0), .cc_ch(4'd0),
        .ch_rd_addr(va_ch_rd_addr), .ch_max_voices(ct_max_voices),
        .nc_wr(va_nc_wr), .nc_ch(va_nc_ch), .nc_val(va_nc_val),
        .scan_addr(va_scan_addr), .scan_req(va_scan_req), .scan_env_state(vf_scan_env_state),
        .awr(va_awr), .awr_id(va_awr_id), .awr_note(va_awr_note), .awr_vel(va_awr_vel),
        .awr_ch(va_awr_ch), .awr_timbre(va_awr_timbre), .awr_gate(va_awr_gate),
        .awr_vel_gain(va_awr_vg), .awr_age(va_awr_age), .awr_fast_rel(va_awr_fast),
        .evt_dout(va_evt_dout), .evt_empty(va_evt_empty), .evt_full(va_evt_full),
        .evt_rd(va_evt_rd)
    );

    voice_slot_seq #(.G(G), .STRIDE(8)) u_sq (
        .clk(clk), .rst_n_sync(rst_n), .frame_stb(frame_stb),
        .slot(sq_slot), .slot_vld(sq_slot_vld)
    );

    // ---- chan_param_shadow：通道参数 → ext_* 影子寄存器（对接 full_top 的 EXT_TABLE）----
    // 它借用 chan_table 的 P 个并行读口的第 0 路做逐通道扫描（见上面的 prd_ch_bus）
    wire [16*7-1:0]  ext_volume, ext_expression, ext_send_rev, ext_send_cho, ext_send_del;
    wire [16*16-1:0] ext_pan_gL, ext_pan_gR;
    chan_param_shadow #(.NCH(16)) u_cps (
        .clk(clk), .rst_n_sync(rst_n), .frame_stb(frame_stb),
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

    voice_fetch #(.P(P), .G(G), .N(N)) u_vf (
        .clk(clk), .rst_n_sync(rst_n), .frame_stb(frame_stb),
        .slot(sq_slot), .slot_vld(sq_slot_vld),
        .awr(va_awr), .awr_id(va_awr_id), .awr_note(va_awr_note), .awr_vel(va_awr_vel),
        .awr_ch(va_awr_ch), .awr_timbre(va_awr_timbre), .awr_gate(va_awr_gate),
        .awr_vel_gain(va_awr_vg), .awr_age(va_awr_age), .awr_fast_rel(va_awr_fast),
        .awr_ready(vf_awr_ready),
        .rs_wr(1'b0), .rs_id(5'd0), .rs_data(139'd0),
        .scan_addr(va_scan_addr), .scan_req(va_scan_req), .scan_env_state(vf_scan_env_state),
        .ch_sust_pedal(ch_sust_pedal_bus),
        .pf_phase_inc(pf_phase_inc), .pf_timbre(pf_timbre), .pf_note(pf_note),
        .pf_vel_gain(pf_vel_gain), .pf_vca_gain(pf_vca_gain), .pf_ch(pf_ch),
        .pf_gate(pf_gate), .pf_fast_rel(pf_fast_rel),
        .pf_sust_pedal(pf_sust_pedal), .pf_vld(pf_vld)
    );

    //============================================================== MIDI 驱动
    task sbit(input v); begin rx = v; repeat (BITCLK) @(posedge clk); end endtask
    task sbyte(input [7:0] b);
        integer i; begin
            sbit(0); for (i=0;i<8;i=i+1) sbit(b[i]); sbit(1);
        end
    endtask

    integer errors = 0;

    // 全局监视：把事件路径上的关键单拍脉冲都打出来
    always @(posedge clk) begin
        if (ev_note)  $display("    [note] t=%0t ch=%0d key=%0d vel=%0d on=%b",
                               $time, ev_note_ch, ev_note_key, ev_note_vel, ev_note_on);
        if (ev_cc_wr) $display("    [cc]   t=%0t ch=%0d field=%0d val=%0d",
                               $time, ev_cc_ch, ev_cc_field, ev_cc_val);
        if (va_awr)   $display("    [awr]  t=%0t id=%0d note=%0d gate=%b fast=%b",
                               $time, va_awr_id, va_awr_note, va_awr_gate, va_awr_fast);
    end
    task chk(input cond, input [255:0] name);
        begin
            if (!cond) begin errors = errors + 1; $display("FAIL  %0s", name); end
            else $display("  ok  %0s", name);
        end
    endtask

    // 等分配完成 + 下一个 frame_stb 提交 + 预取生效
    // 等到"预取 slot0 生效"那一刻：slot==3 的时隙脉冲之后，预取寄存器里就是 slot0 的参数
    task settle;
        begin
            repeat (120) @(posedge clk);          // 等分配 FSM 跑完（~70 拍）
            @(posedge frame_stb);                 // 等帧边界
            repeat (100) @(posedge clk);          // 等 voice_fetch 提交（WB+AW 共 64 拍）
            @(posedge clk);
            while (!(sq_slot == 2'd3 && sq_slot_vld)) @(posedge clk);
            @(posedge clk);                       // 预取寄存器在下一拍生效
            #1;
        end
    endtask

    integer i;
    initial begin
        $dumpfile("tb_sched_top.vcd");
        $dumpvars(0, tb_sched_top);

        repeat (10) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (5) @(posedge clk);

        //================================================ ① Note On 全链路
        $display("== 1. Note On through the whole event path ==");
        sbyte(8'h90); sbyte(8'h3C); sbyte(8'h64);       // Note On ch0 key60 vel100
        settle;
        // 声部 0 = {slot0, lane0}；预取 slot0 时看 lane0
        $display("       slot=%0d pf_gate[0]=%b pf_note[0]=%0d pf_timbre[0]=%0d",
                 sq_slot, pf_gate[0], pf_note[0*7 +: 7], pf_timbre[0*3 +: 3]);
        chk(pf_gate[0] === 1'b1, "note on -> prefreeched gate = 1");
        chk(pf_note[0*7 +: 7] === 7'd60, "note on -> prefetched note = 60");
        chk(ct_note_count === 6'd1, "chan_table note_count = 1");

        //================================================ ② CC volume → 通道表
        $display("== 2. CC volume updates chan_table ==");
        sbyte(8'hB0); sbyte(8'h07); sbyte(8'h50);       // CC7 = 80
        repeat (200) @(posedge clk);
        @(posedge frame_stb);
        repeat (100) @(posedge clk);
        $display("       ct_volume=%0d (exp 80)  rd_ch=%0d fifo_empty=%b dumping=%b",
                 ct_volume, va_ch_rd_addr, ct_fifo_empty, ct_dumping);
        chk(ct_volume === 7'd80, "CC7 = 80 visible at chan_table read port");

        //================================================ ③ Note Off
        $display("== 3. Note Off -> gate = 0 ==");
        sbyte(8'h80); sbyte(8'h3C); sbyte(8'h40);       // Note Off ch0 key60
        settle;
        $display("       pf_gate[0]=%b", pf_gate[0]);
        chk(pf_gate[0] === 1'b0, "note off -> prefetched gate = 0");

        if (errors == 0) $display("PASS  tb_sched_top");
        else             $display("FAIL  tb_sched_top : %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
