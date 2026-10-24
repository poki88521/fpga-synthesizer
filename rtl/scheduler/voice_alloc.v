//============================================================================
//  voice_alloc —— 声部分配 / 释放器（调度层 · 事件类）
//
//  依据：documents/硬件实现.md §三.六
//
//  分配优先级（Note On）：
//    ① 同通道、同 note、且 gate=1 的声部存在 → 重新触发该声部（复用）
//    ② 否则存在空闲声部（env_state == IDLE 且 gate == 0）→ 取编号最小者
//    ③ 否则抢断：本通道内 age 最小（最老）的声部
//  并先检查该通道 note_count < max_voices；已达上限则只在本通道内抢断。
//
//  字段归属（§三.六.3）：本模块是**分配类字段的唯一写者**
//    note / velocity / channel / timbre_slot / gate / velocity_gain / age
//  模块内部这份摘要即权威副本；完整声部表在 voice_fetch 里，由 awr_* 写请求
//  在 frame_stb 边界提交。
//
//  ⚠ 扫描时**不**用 `vs_env_state[i*3 +: 3]` 这种变量 indexed part-select
//    （前面模块已证实 iverilog 下不可靠）：改为输出 scan_addr，由 voice_fetch
//    打一拍返回 scan_env_state。
//
//  分配事件 FIFO（§三.六.4）：条目 = {voice_id[4:0], op[1:0]}，深度 4，
//    op：0=分配、1=释放、2=抢断。
//
//  本期简化（已在报告里说明）：timbre_slot 取 note 低位（真映射经 timbre_map）；
//    velocity_gain 暂用线性 vel<<8（音色表 vel_sensitivity 待接）。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module voice_alloc #(
    parameter P   = 8,
    parameter G   = 4,
    parameter N   = 32,
    parameter NCH = 16
)(
    input  wire        clk,
    input  wire        rst_n_sync,
    input  wire        frame_stb,

    // ——— Note 事件（来自 midi_filter）———
    input  wire        ev_note,
    input  wire        ev_note_on,
    input  wire [3:0]  ev_note_ch,
    input  wire [6:0]  ev_note_key,
    input  wire [6:0]  ev_note_vel,

    // ——— 控制类事件 ———
    input  wire [1:0]  cc_action,        // 1=CC120 全音关(直断) 2=CC123 全音符关(走 RELEASE)
    input  wire [3:0]  cc_ch,

    // ——— 通道状态表读口（读 max_voices / bank_msb / program）———
    output reg  [3:0]  ch_rd_addr,
    input  wire [5:0]  ch_max_voices,
    input  wire [6:0]  ch_bank_msb,      // 同一次读口取回，供 timbre_map
    input  wire [6:0]  ch_prog_num,      // 音色号 0~127

    // ——— note_count 写回通道表 ———
    output reg         nc_wr,
    output reg  [3:0]  nc_ch,
    output reg  [5:0]  nc_val,

    // ——— 声部 env_state 扫描口（→ voice_fetch）———
    output reg  [4:0]  scan_addr,
    output reg         scan_req,
    input  wire [2:0]  scan_env_state,

    // ——— 分配写请求（→ voice_fetch，frame_stb 边界提交）———
    output reg         awr,
    output reg  [4:0]  awr_id,
    output reg  [6:0]  awr_note,
    output reg  [6:0]  awr_vel,
    output reg  [3:0]  awr_ch,
    output reg  [2:0]  awr_timbre,
    output reg         awr_gate,
    output reg  [15:0] awr_vel_gain,
    output reg  [7:0]  awr_age,
    output reg         awr_fast_rel,     // 1 = 抢断/直断，需 ~1ms 快速斜坡

    // ——— 分配事件 FIFO ———
    output wire [6:0]  evt_dout,         // {voice_id[4:0], op[1:0]}
    output wire        evt_empty,
    output wire        evt_full,
    input  wire        evt_rd
);
    localparam [2:0] S_IDLE = 3'd0, S_SCAN = 3'd1, S_WSCAN = 3'd2,
                     S_DEC  = 3'd3, S_WRITE = 3'd4, S_NC = 3'd5, S_ALLNO = 3'd6;
    localparam [1:0] OP_ALLOC = 2'd0, OP_REL = 2'd1, OP_STEAL = 2'd2;

    //========================================================================
    // 音色映射（timbre_map）：用**该通道的 program** 决定音色槽
    //
    //  ⚠ 2026-10-09 接入。原先 `awr_timbre <= evt_key[2:0]`，即"音色槽 = note 低 3 位"，
    //     导致 Program Change 完全无效（上板实测：换音色后声音不变）。
    //
    //  ⚠ 时序对齐（**关键**）：timbre_map 是 `req` 后**下一拍**输出（它的设计如此，
    //     为了切断组合长链）。而 `S_DEC` 决定目标声部后，下一拍正好就是 `S_WRITE`，
    //     所以这里用**组合**的 `tm_req = (st == S_DEC)`：
    //         S_DEC  那一拍 tm_req 拉高 → timbre_map 采样 bank_msb/prog_num
    //         S_WRITE 那一拍 tm_slot 有效 → 直接写进 awr_timbre
    //     若改成"寄存器打一拍"的 tm_req，就会晚一拍、S_WRITE 取到上一轮的旧值。
    //
    //  ⚠ ch_prog_num 取自 chan_table 的同一个读口，而 ch_rd_addr 在 S_IDLE 检测到
    //     ev_note 时就已指向"要分配的那个通道"（见 S_IDLE 的 ch_rd_addr <= ev_note_ch），
    //     所以 S_DEC 那拍取到的 program 是正确的。
    //
    //  ⚠ tm_vld 用不到：tm_req 与 S_WRITE 的相位是固定的，不需要额外握手。
    //========================================================================
    wire        tm_req = (st == S_DEC);
    wire [2:0]  tm_slot;

    timbre_map u_timbre_map (
        .clk         (clk),
        .rst_n_sync  (rst_n_sync),
        .req         (tm_req),
        .bank_msb    (ch_bank_msb),
        .prog_num    (ch_prog_num),
        .timbre_slot (tm_slot),
        .vld         ()                  // 相位固定，不需要
    );

    //========================================================================
    // 状态 / 声部摘要（本模块即分配类字段的权威副本）
    //========================================================================
    reg [2:0] st;

    reg [6:0] v_note [0:N-1];
    reg [3:0] v_ch   [0:N-1];
    reg       v_gate [0:N-1];
    reg [7:0] v_age  [0:N-1];
    reg [7:0] age_ctr;
    reg [5:0] ch_ncnt [0:NCH-1];

    //========================================================================
    // 事件 FIFO（深度 4）
    //========================================================================
    reg [6:0]  efifo [0:3];
    reg [1:0]  e_wp, e_rp;
    reg [2:0]  e_cnt;
    wire       e_full = (e_cnt >= 3'd4);
    assign     evt_empty = (e_cnt == 3'd0);
    assign     evt_full  = e_full;
    assign     evt_dout  = efifo[e_rp];

    //========================================================================
    // 扫描候选 / 锁存事件
    //========================================================================
    reg [4:0]  scan_i;
    reg [4:0]  cand_retrig;
    reg [4:0]  cand_free;
    reg [4:0]  cand_old;
    reg [7:0]  best_age;
    reg [6:0]  evt_key, evt_vel;         // 注意：必须 7 位，不能只存低 5 位
    reg [3:0]  evt_ch;
    reg        evt_on;
    reg [4:0]  tgt_id;
    reg [1:0]  tgt_op;
    reg        tgt_steal;
    reg [1:0]  all_action;
    reg [3:0]  all_ch;
    reg [4:0]  all_i;

    function [15:0] vel_gain_fn;
        input [6:0] vel;
        begin
            //  2026-10-24：vel_sensitivity 第一版 —— **平方曲线**（原来线性 vel<<7）
        //      vel=127 → 127×127 = 16129，与原来的 16256 只差 0.09 dB（**最大响度不变**）
        //      vel=64  → 4096（原来 8192，−6 dB），vel=32 → 1024（原来 4096，−12 dB）
        //      ⇒ 轻按明显更柔、重按仍然能顶到满，符合钢琴手感
        //  代价：一次 7×7 乘法，但在**分配器**里（每按一次键算一次，不是逐采样）→ 无时序风险
        vel_gain_fn = {9'd0, vel} * {9'd0, vel};
        end
    endfunction

    integer k;
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            st        <= S_IDLE;
            for (k = 0; k < N; k = k + 1) begin
                v_note[k] <= 7'd0;
                v_ch[k]   <= 4'd0;
                v_gate[k] <= 1'b0;
                v_age[k]  <= 8'd0;
            end
            for (k = 0; k < NCH; k = k + 1) ch_ncnt[k] <= 6'd0;
            age_ctr     <= 8'd0;
            e_wp        <= 2'd0;
            e_rp        <= 2'd0;
            e_cnt       <= 3'd0;
            scan_i      <= 5'd0;
            cand_retrig <= 5'h1f;
            cand_free   <= 5'h1f;
            cand_old    <= 5'h1f;
            best_age    <= 8'd0;
            evt_key     <= 7'd0;
            evt_vel     <= 7'd0;
            evt_ch      <= 4'd0;
            evt_on      <= 1'b0;
            tgt_id      <= 5'h1f;
            tgt_op      <= 2'd0;
            tgt_steal   <= 1'b0;
            all_action  <= 2'd0;
            all_ch      <= 4'd0;
            all_i       <= 5'd0;
            ch_rd_addr  <= 4'd0;
            nc_wr       <= 1'b0;
            nc_ch       <= 4'd0;
            nc_val      <= 6'd0;
            scan_addr   <= 5'd0;
            scan_req    <= 1'b0;
            awr         <= 1'b0;
            awr_id      <= 5'd0;
            awr_note    <= 7'd0;
            awr_vel     <= 7'd0;
            awr_ch      <= 4'd0;
            awr_timbre  <= 3'd0;
            awr_gate    <= 1'b0;
            awr_vel_gain<= 16'd0;
            awr_age     <= 8'd0;
            awr_fast_rel<= 1'b0;
        end else begin
            nc_wr    <= 1'b0;
            awr      <= 1'b0;
            scan_req <= 1'b0;
            age_ctr  <= age_ctr + 8'd1;

            if (evt_rd && e_cnt != 3'd0) begin
                e_rp  <= e_rp + 2'd1;
                e_cnt <= e_cnt - 3'd1;
            end

            case (st)
                //----------------------------------------------------------
                S_IDLE: begin
                    if (cc_action != 2'd0) begin
                        all_action <= cc_action;
                        all_ch     <= cc_ch;
                        all_i      <= 5'd0;
                        st         <= S_ALLNO;
                    end
                    else if (ev_note) begin
                        evt_ch     <= ev_note_ch;
                        evt_key    <= ev_note_key;
                        evt_vel    <= ev_note_vel;
                        evt_on     <= ev_note_on;
                        ch_rd_addr <= ev_note_ch;
                        scan_i      <= 5'd0;
                        cand_retrig <= 5'h1f;
                        cand_free   <= 5'h1f;
                        cand_old    <= 5'h1f;
                        best_age    <= 8'hff;
                        st          <= S_SCAN;
                    end
                end
                //----------------------------------------------------------
                S_SCAN: begin
                    scan_addr <= scan_i;
                    scan_req  <= 1'b1;
                    st        <= S_WSCAN;
                end
                //----------------------------------------------------------
                S_WSCAN: begin
                    if (!evt_on) begin
                        // Note Off：只找"同通道 + 同 note + gate"的声部
                        if ((v_ch[scan_i] == evt_ch) &&
                            (v_note[scan_i] == evt_key) && v_gate[scan_i]) begin
                            if (cand_retrig == 5'h1f) cand_retrig <= scan_i;
                        end
                    end else begin
                        if ((v_ch[scan_i] == evt_ch) &&
                            (v_note[scan_i] == evt_key) && v_gate[scan_i]) begin
                            if (cand_retrig == 5'h1f) cand_retrig <= scan_i;   // 优先①
                        end
                        if (!v_gate[scan_i] && (scan_env_state == 3'd0)) begin
                            if (cand_free == 5'h1f) cand_free <= scan_i;       // 优先②
                        end
                        if ((v_ch[scan_i] == evt_ch) && v_gate[scan_i]) begin
                            if (v_age[scan_i] < best_age) begin                // 优先③
                                cand_old <= scan_i;
                                best_age <= v_age[scan_i];
                            end
                        end
                    end
                    if (scan_i == (N-1)) st <= S_DEC;
                    else begin
                        scan_i <= scan_i + 5'd1;
                        st     <= S_SCAN;
                    end
                end
                //----------------------------------------------------------
                S_DEC: begin
                    if (!evt_on) begin
                        tgt_id <= cand_retrig;
                        tgt_op <= OP_REL;
                        st     <= S_WRITE;
                    end
                    else if (cand_retrig != 5'h1f) begin
                        tgt_id    <= cand_retrig;
                        tgt_op    <= OP_ALLOC;
                        tgt_steal <= 1'b0;
                        st        <= S_WRITE;
                    end
                    else if ((cand_free != 5'h1f) &&
                             (ch_ncnt[evt_ch] < ch_max_voices)) begin
                        tgt_id    <= cand_free;
                        tgt_op    <= OP_ALLOC;
                        tgt_steal <= 1'b0;
                        st        <= S_WRITE;
                    end
                    else if (cand_old != 5'h1f) begin
                        tgt_id    <= cand_old;
                        tgt_op    <= OP_STEAL;
                        tgt_steal <= 1'b1;
                        st        <= S_WRITE;
                    end
                    else st <= S_IDLE;
                end
                //----------------------------------------------------------
                S_WRITE: begin
                    if (tgt_id != 5'h1f) begin
                        awr         <= 1'b1;
                        awr_id      <= tgt_id;
                        awr_note    <= evt_key;
                        awr_vel     <= evt_vel;
                        awr_ch      <= evt_ch;
                        awr_timbre  <= tm_slot;           // 由 timbre_map 依该通道的 program 决定
                        awr_gate    <= (tgt_op == OP_REL) ? 1'b0 : 1'b1;
                        awr_vel_gain<= vel_gain_fn(evt_vel);
                        awr_age     <= age_ctr;
                        awr_fast_rel<= tgt_steal;

                        if (tgt_op == OP_REL) begin
                            v_gate[tgt_id] <= 1'b0;
                            if (ch_ncnt[evt_ch] != 6'd0)
                                ch_ncnt[evt_ch] <= ch_ncnt[evt_ch] - 6'd1;
                            if (!e_full) begin
                                efifo[e_wp] <= {tgt_id, OP_REL};
                                e_wp        <= e_wp + 2'd1;
                                e_cnt       <= e_cnt + 3'd1;
                            end
                        end else begin
                            if (!v_gate[tgt_id]) begin
                                ch_ncnt[evt_ch] <= ch_ncnt[evt_ch] + 6'd1;
                            end else if (v_ch[tgt_id] != evt_ch) begin
                                if (ch_ncnt[v_ch[tgt_id]] != 6'd0)
                                    ch_ncnt[v_ch[tgt_id]] <= ch_ncnt[v_ch[tgt_id]] - 6'd1;
                                ch_ncnt[evt_ch] <= ch_ncnt[evt_ch] + 6'd1;
                            end
                            v_note[tgt_id] <= evt_key;
                            v_ch[tgt_id]   <= evt_ch;
                            v_gate[tgt_id] <= 1'b1;
                            v_age[tgt_id]  <= age_ctr;
                            if (!e_full) begin
                                efifo[e_wp] <= {tgt_id, tgt_steal ? OP_STEAL : OP_ALLOC};
                                e_wp        <= e_wp + 2'd1;
                                e_cnt       <= e_cnt + 3'd1;
                            end
                        end
                        nc_ch <= evt_ch;
                        st    <= S_NC;
                    end
                    else st <= S_IDLE;
                end
                //----------------------------------------------------------
                S_NC: begin
                    nc_wr  <= 1'b1;
                    nc_ch  <= evt_ch;
                    nc_val <= ch_ncnt[evt_ch];
                    st     <= S_IDLE;
                end
                //----------------------------------------------------------
                S_ALLNO: begin
                    if (v_gate[all_i] && (v_ch[all_i] == all_ch)) begin
                        v_gate[all_i] <= 1'b0;
                        awr           <= 1'b1;
                        awr_id        <= all_i;
                        awr_note      <= v_note[all_i];
                        awr_vel       <= 7'd0;
                        awr_ch        <= all_ch;
                        awr_timbre    <= v_note[all_i][2:0];
                        awr_gate      <= 1'b0;
                        awr_vel_gain  <= 16'd0;
                        awr_age       <= age_ctr;
                        awr_fast_rel  <= (all_action == 2'd1);   // CC120 直断 / CC123 正常释放
                        if (ch_ncnt[all_ch] != 6'd0)
                            ch_ncnt[all_ch] <= ch_ncnt[all_ch] - 6'd1;
                    end
                    if (all_i == (N-1)) begin
                        nc_wr  <= 1'b1;
                        nc_ch  <= all_ch;
                        nc_val <= ch_ncnt[all_ch];
                        st     <= S_IDLE;
                    end else all_i <= all_i + 5'd1;
                end
                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
`default_nettype wire
