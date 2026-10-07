//============================================================================
//  midi_filter —— 消息过滤与分发（调度层 · 事件类）
//
//  依据：documents/硬件实现.md
//    §三.1   端口过滤：**乐器端口（port ≠ 3）丢弃混音类 CC 7 / 10 / 91 / 93 / 94**
//    §三.三  消息 → 目标：Note → voice_alloc；CC → chan_table 待写缓冲；
//            PC → chan_table + timbre_map；SysEx → 全局层参数写口（§六.3.5）
//    §三.三.3  field_id 编码表（0~17）
//    §三.六   Note On 力度 0 按 Note Off 处理
//    §二.5    SysEx：F0 7D <slot> <param> <hi> <lo> F7（效果参数）
//                    F0 7F <dev> 04 01 ll mm F7（主音量，14 位）
//
//  输出均为**单拍脉冲**；上游 msg_vld 保持到 msg_ack，本模块只处理一次。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module midi_filter (
    input  wire        clk,
    input  wire        rst_n_sync,

    // ——— 来自 midi_arb ———
    input  wire        msg_vld,
    input  wire [7:0]  msg_status,
    input  wire [7:0]  msg_d0,
    input  wire [7:0]  msg_d1,
    input  wire [1:0]  msg_port,
    output reg         msg_ack,

    input  wire        sysex_start,
    input  wire [6:0]  sysex_len,
    input  wire        sysex_vld,
    input  wire [7:0]  sysex_byte,
    input  wire        sysex_err,

    // ——— Note 事件 → voice_alloc ———
    output reg         ev_note,          // 单拍脉冲
    output reg         ev_note_on,       // 1 = Note On，0 = Note Off
    output reg  [3:0]  ev_note_ch,       // 通道 0~15
    output reg  [6:0]  ev_note_key,
    output reg  [6:0]  ev_note_vel,

    // ——— CC 写 → chan_table 待写缓冲 ———
    output reg         ev_cc_wr,
    output reg  [3:0]  ev_cc_ch,
    output reg  [4:0]  ev_cc_field,      // field_id（§三.三.3）
    output reg  [15:0] ev_cc_val,

    // ——— Program Change → chan_table / timbre_map ———
    output reg         ev_pc,
    output reg  [3:0]  ev_pc_ch,
    output reg  [6:0]  ev_pc_prog,

    // ——— 全局层参数写口（§六.3.5）———
    output reg         ev_par_wr,
    output reg  [1:0]  ev_par_grp,       // 0 混响 / 1 合唱 / 2 延迟 / 3 主输出
    output reg  [3:0]  ev_par_idx,
    output reg  [15:0] ev_par_data,

    // ——— 丢弃计数（乐器端口的混音类 CC）———
    output reg         drop_vld
);
    //========================================================================
    // field_id 编码（§三.三.3）
    //========================================================================
    localparam [4:0] F_VOLUME      = 5'd0,
                     F_PAN         = 5'd1,
                     F_EXPRESSION  = 5'd2,
                     F_SUSTAIN     = 5'd3,
                     F_SOSTENUTO   = 5'd4,
                     F_ATTACK_MOD  = 5'd5,
                     F_RELEASE_MOD = 5'd6,
                     F_RESONANCE   = 5'd7,
                     F_CUTOFF_MOD  = 5'd8,
                     F_SEND_REV    = 5'd9,
                     F_SEND_CHO    = 5'd10,
                     F_SEND_DEL    = 5'd11,
                     F_BANK_MSB    = 5'd12,
                     F_BANK_LSB    = 5'd13,
                     F_PROGRAM     = 5'd14,
                     F_BEND_VALUE  = 5'd15,
                     F_BEND_RANGE  = 5'd16,
                     F_NONE        = 5'd31;

    // CC 号 → field_id（不含 RPN，RPN 单独处理）
    function [4:0] cc2field;
        input [6:0] cc;
        begin
            case (cc)
                7'd0  : cc2field = F_BANK_MSB;
                7'd32 : cc2field = F_BANK_LSB;
                7'd7  : cc2field = F_VOLUME;
                7'd10 : cc2field = F_PAN;
                7'd11 : cc2field = F_EXPRESSION;
                7'd64 : cc2field = F_SUSTAIN;
                7'd66 : cc2field = F_SOSTENUTO;
                7'd71 : cc2field = F_RESONANCE;
                7'd72 : cc2field = F_RELEASE_MOD;
                7'd73 : cc2field = F_ATTACK_MOD;
                7'd74 : cc2field = F_CUTOFF_MOD;
                7'd91 : cc2field = F_SEND_REV;
                7'd93 : cc2field = F_SEND_CHO;
                7'd94 : cc2field = F_SEND_DEL;
                default: cc2field = F_NONE;      // 未列出的 CC → 忽略
            endcase
        end
    endfunction

    // 乐器端口要丢弃的混音类 CC
    function is_mix_cc;
        input [6:0] cc;
        begin
            is_mix_cc = (cc == 7'd7)  || (cc == 7'd10) || (cc == 7'd91) ||
                        (cc == 7'd93) || (cc == 7'd94);
        end
    endfunction

    //========================================================================
    // 状态
    //========================================================================
    reg       msg_busy;                  // 本拍已处理过一条消息
    reg [6:0] rpn_msb, rpn_lsb;          // RPN 号（只用 RPN 0,0）
    reg [7:0] sxb [0:7];                 // SysEx 前 8 个字节足够
    reg [2:0] sxn;                       // 已收字节数
    reg [2:0] sx_len_lat;
    reg       sx_act;
    reg       sx_done;                   // 最后一字节已收，下一拍解析

    // 消息字段（组合展开）
    wire [3:0]  m_type = msg_status[7:4];
    wire [3:0]  m_ch   = msg_status[3:0];
    wire [6:0]  m_cc   = msg_d0[6:0];
    wire [6:0]  m_val7 = msg_d1[6:0];
    wire [4:0]  m_fld  = cc2field(m_cc);
    wire        m_mixcc_drop = (msg_port != 2'd3) && is_mix_cc(m_cc);

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            msg_ack      <= 1'b0;
            msg_busy     <= 1'b0;
            rpn_msb      <= 7'd0;
            rpn_lsb      <= 7'd0;
            sxn          <= 3'd0;
            sx_len_lat   <= 3'd0;
            sx_act       <= 1'b0;
            sx_done      <= 1'b0;
            ev_note      <= 1'b0;
            ev_note_on   <= 1'b0;
            ev_note_ch   <= 4'd0;
            ev_note_key  <= 7'd0;
            ev_note_vel  <= 7'd0;
            ev_cc_wr     <= 1'b0;
            ev_cc_ch     <= 4'd0;
            ev_cc_field  <= 5'd0;
            ev_cc_val    <= 16'd0;
            ev_pc        <= 1'b0;
            ev_pc_ch     <= 4'd0;
            ev_pc_prog   <= 7'd0;
            ev_par_wr    <= 1'b0;
            ev_par_grp   <= 2'd0;
            ev_par_idx   <= 4'd0;
            ev_par_data  <= 16'd0;
            drop_vld     <= 1'b0;
        end else begin
            // ---- 默认：所有事件都是单拍脉冲 ----
            msg_ack   <= 1'b0;
            ev_note   <= 1'b0;
            ev_cc_wr  <= 1'b0;
            ev_pc     <= 1'b0;
            ev_par_wr <= 1'b0;
            drop_vld  <= 1'b0;
            sx_done   <= 1'b0;

            //================================================================
            // 一、通道消息（只在 msg_vld 首次出现那一拍处理）
            //================================================================
            if (msg_vld && !msg_busy) begin
                msg_busy <= 1'b1;
                msg_ack  <= 1'b1;

                case (m_type)
                    4'h8, 4'h9: begin
                        // Note Off / Note On（力度 0 的 Note On 按 Note Off 处理）
                        ev_note     <= 1'b1;
                        ev_note_on  <= (m_type == 4'h9) && (m_val7 != 7'd0);
                        ev_note_ch  <= m_ch;
                        ev_note_key <= m_cc;               // d0 = 音符号
                        ev_note_vel <= (m_type == 4'h9) ? m_val7 : 7'd0;
                    end
                    4'hB: begin
                        // Control Change
                        if (m_mixcc_drop) begin
                            drop_vld <= 1'b1;              // 乐器端口的混音类 CC → 丢弃
                        end
                        else if (m_cc == 7'd101) begin
                            rpn_msb <= m_val7;             // RPN MSB
                        end
                        else if (m_cc == 7'd100) begin
                            rpn_lsb <= m_val7;             // RPN LSB
                        end
                        else if (m_cc == 7'd6) begin
                            // Data Entry：本项目只用 RPN 0,0（弯音范围）
                            if (rpn_msb == 7'd0 && rpn_lsb == 7'd0) begin
                                ev_cc_wr    <= 1'b1;
                                ev_cc_ch    <= m_ch;
                                ev_cc_field <= F_BEND_RANGE;
                                ev_cc_val   <= {9'd0, m_val7};
                            end
                        end
                        else if (m_fld != F_NONE) begin
                            ev_cc_wr    <= 1'b1;
                            ev_cc_ch    <= m_ch;
                            ev_cc_field <= m_fld;
                            ev_cc_val   <= {9'd0, m_val7};
                        end
                        // m_fld == F_NONE → 忽略（未列出的 CC）
                    end
                    4'hC: begin
                        // Program Change（单数据字节）
                        ev_pc      <= 1'b1;
                        ev_pc_ch   <= m_ch;
                        ev_pc_prog <= m_cc;
                    end
                    4'hE: begin
                        // Pitch Bend：En ll mm → 值 = mm×128 + ll（LSB 在前）
                        ev_cc_wr    <= 1'b1;
                        ev_cc_ch    <= m_ch;
                        ev_cc_field <= F_BEND_VALUE;
                        ev_cc_val   <= {2'b0, m_val7, m_cc};
                    end
                    default: ;                         // 其它消息忽略（但仍 ack）
                endcase
            end
            else if (!msg_vld) begin
                msg_busy <= 1'b0;                      // 上游已撤 → 允许处理下一条
            end

            //================================================================
            // 二、SysEx：先缓存，收齐后再解析
            //================================================================
            if (sysex_start) begin
                sx_act     <= 1'b1;
                sxn        <= 3'd0;
                sx_len_lat <= sysex_len[2:0];
            end
            else if (sysex_vld && sx_act) begin
                if (sxn <= 3'd7) sxb[sxn] <= sysex_byte;
                if (sxn == sx_len_lat - 3'd1) begin
                    sx_done <= 1'b1;                   // 最后一字节
                    sx_act  <= 1'b0;
                end else begin
                    sxn <= sxn + 3'd1;
                end
            end

            //================================================================
            // 三、SysEx 解析（最后一字节的下一拍）
            //================================================================
            if (sx_done) begin
                if (sxb[0] == 8'h7D && sx_len_lat >= 3'd5) begin
                    // 效果参数：F0 7D <slot> <param> <hi> <lo> F7
                    ev_par_wr   <= 1'b1;
                    ev_par_grp  <= sxb[1][1:0];
                    ev_par_idx  <= sxb[2][3:0];
                    ev_par_data <= {2'b0, sxb[3][6:0], sxb[4][6:0]};
                end
                else if (sxb[0] == 8'h7F && sx_len_lat >= 3'd6 &&
                         sxb[2] == 8'h04 && sxb[3] == 8'h01) begin
                    // 主音量：F0 7F <dev> 04 01 ll mm F7 → 组 3、号 0
                    ev_par_wr   <= 1'b1;
                    ev_par_grp  <= 2'd3;
                    ev_par_idx  <= 4'd0;
                    ev_par_data <= {2'b0, sxb[5][6:0], sxb[4][6:0]};
                end
                // 其它 SysEx：忽略
            end
        end
    end

    // 保留接口（parse 侧错误时不会交付，故此处不使用）
    wire _unused = sysex_err;

endmodule
`default_nettype wire
