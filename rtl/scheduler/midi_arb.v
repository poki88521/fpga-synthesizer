//============================================================================
//  midi_arb —— 4 路 MIDI 消息汇流（调度层 · 事件类）
//
//  依据：documents/硬件实现.md §三.一.1 / §三.一.5(2)
//    · 4 路（乐器 ×3 + 混音器 ×1）消息汇入同一条事件总线，消息携带端口号
//    · 仲裁规则：固定优先级 0 → 3（端口号小者优先），一次只交付一条
//    · 未被选中的路保持 msg_vld 等待，不丢消息；不需要 FIFO（MIDI 帧间隔很长）
//    · SysEx 是多拍流，必须**锁定**选中路直到整条交付完，不能被打断
//
//  握手时序（与 midi_parse 对接）：
//    消息：源路 msg_vld 保持 → 本模块输出 out_msg_vld → 下游 out_msg_ack
//          → 本模块回落 in_msg_ack[owner] → 源路撤 msg_vld → 本模块释放
//    SysEx：源路 sysex_start（单拍，同拍 sysex_len 有效）→ 本模块锁定并转发
//          → 之后 len 拍逐字节透传（每拍回落一个 in_sysex_ack）→ 计数到 0 释放
//
//  ⚠ 三个踩过的坑（写在这里，避免再犯）：
//    ① 4 路输入的选取**必须**用 `case` 展开，不要用 `vec[sel*N +: N]` 这种
//       「变量 indexed part-select」；更不要把选取放进独立的组合 always
//       再喂给本时序块——嵌套组合 always 在 iverilog 下会滞后一拍，
//       表现为输出恒为 0。**在选择处直接内联 case**。
//    ② out_sysex_vld 是寄存器输出，比 in_sysex_vld 晚一拍；最后一个字节要等
//       它透传出去之后再释放，提前清 vld 会丢掉最后一个字节。
//    ③ 回落 ack 要用整体赋值（case 展开成 4'b0001 之类），不要与"默认清零的
//       整体赋值"混用位赋值。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module midi_arb (
    input  wire        clk,
    input  wire        rst_n_sync,

    // ——— 4 路输入（来自 midi_parse ×4）———
    input  wire [3:0]  in_msg_vld,
    input  wire [31:0] in_msg_status,     // 4 × 8
    input  wire [31:0] in_msg_d0,         // 4 × 8
    input  wire [31:0] in_msg_d1,         // 4 × 8
    input  wire [3:0]  in_sysex_start,
    input  wire [27:0] in_sysex_len,      // 4 × 7
    input  wire [3:0]  in_sysex_vld,
    input  wire [31:0] in_sysex_byte,     // 4 × 8
    input  wire [3:0]  in_sysex_err,
    output reg  [3:0]  in_msg_ack,
    output reg  [3:0]  in_sysex_ack,

    // ——— 汇流输出（→ midi_filter）———
    output reg         out_msg_vld,
    output reg  [7:0]  out_msg_status,
    output reg  [7:0]  out_msg_d0,
    output reg  [7:0]  out_msg_d1,
    output reg  [1:0]  out_msg_port,
    input  wire        out_msg_ack,
    output reg         out_sysex_start,
    output reg  [6:0]  out_sysex_len,
    output reg         out_sysex_vld,
    output reg  [7:0]  out_sysex_byte,
    output reg         out_sysex_err,
    input  wire        out_sysex_ack      // 当前未使用（交付为自动流式）
);
    //========================================================================
    // 仲裁（组合，只依赖输入向量，优先级 0 → 3）
    //========================================================================
    reg [1:0] msel;
    always @(*) begin
        if      (in_msg_vld[0]) msel = 2'd0;
        else if (in_msg_vld[1]) msel = 2'd1;
        else if (in_msg_vld[2]) msel = 2'd2;
        else                    msel = 2'd3;
    end
    wire any_msg = |in_msg_vld;

    reg [1:0] ssel;
    always @(*) begin
        if      (in_sysex_start[0]) ssel = 2'd0;
        else if (in_sysex_start[1]) ssel = 2'd1;
        else if (in_sysex_start[2]) ssel = 2'd2;
        else                        ssel = 2'd3;
    end
    wire any_sysex = |in_sysex_start;

    //========================================================================
    // 状态
    //========================================================================
    reg       msg_busy;
    reg       msg_acked;
    reg [1:0] msg_owner;
    reg       sx_busy;
    reg [1:0] sx_owner;
    reg [6:0] sx_left;
    reg       sx_last;

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            in_msg_ack       <= 4'd0;
            in_sysex_ack     <= 4'd0;
            out_msg_vld      <= 1'b0;
            out_msg_status   <= 8'd0;
            out_msg_d0       <= 8'd0;
            out_msg_d1       <= 8'd0;
            out_msg_port     <= 2'd0;
            out_sysex_start  <= 1'b0;
            out_sysex_len    <= 7'd0;
            out_sysex_vld    <= 1'b0;
            out_sysex_byte   <= 8'd0;
            out_sysex_err    <= 1'b0;
            msg_busy         <= 1'b0;
            msg_acked        <= 1'b0;
            msg_owner        <= 2'd0;
            sx_busy          <= 1'b0;
            sx_owner         <= 2'd0;
            sx_left          <= 7'd0;
            sx_last          <= 1'b0;
        end else begin
            // ---- 默认脉冲 ----
            in_msg_ack      <= 4'd0;
            in_sysex_ack    <= 4'd0;
            out_sysex_start <= 1'b0;
            out_sysex_vld   <= 1'b0;

            //================================================================
            // 一、消息通道：回落 ack / 释放
            //================================================================
            if (msg_busy) begin
                if (out_msg_vld && out_msg_ack && !msg_acked) begin
                    msg_acked <= 1'b1;
                    case (msg_owner)                  // 只回给 owner 那一路
                        2'd0:    in_msg_ack <= 4'b0001;
                        2'd1:    in_msg_ack <= 4'b0010;
                        2'd2:    in_msg_ack <= 4'b0100;
                        default: in_msg_ack <= 4'b1000;
                    endcase
                end
                if (!in_msg_vld[msg_owner]) begin     // 源路已撤 → 释放
                    msg_busy    <= 1'b0;
                    msg_acked   <= 1'b0;
                    out_msg_vld <= 1'b0;
                end
            end

            //================================================================
            // 二、SysEx 通道：锁定后逐字节透传
            //    ⚠ 输出比输入晚一拍，最后一个字节要等透传完再释放
            //================================================================
            if (sx_busy) begin
                case (sx_owner)
                    2'd0: begin
                        out_sysex_vld  <= in_sysex_vld[0];
                        out_sysex_byte <= in_sysex_byte[7:0];
                        out_sysex_err  <= in_sysex_err[0];
                        if (in_sysex_vld[0]) begin
                            in_sysex_ack <= 4'b0001;
                            if (sx_left <= 7'd1) sx_last <= 1'b1;
                            else                 sx_left <= sx_left - 7'd1;
                        end
                    end
                    2'd1: begin
                        out_sysex_vld  <= in_sysex_vld[1];
                        out_sysex_byte <= in_sysex_byte[15:8];
                        out_sysex_err  <= in_sysex_err[1];
                        if (in_sysex_vld[1]) begin
                            in_sysex_ack <= 4'b0010;
                            if (sx_left <= 7'd1) sx_last <= 1'b1;
                            else                 sx_left <= sx_left - 7'd1;
                        end
                    end
                    2'd2: begin
                        out_sysex_vld  <= in_sysex_vld[2];
                        out_sysex_byte <= in_sysex_byte[23:16];
                        out_sysex_err  <= in_sysex_err[2];
                        if (in_sysex_vld[2]) begin
                            in_sysex_ack <= 4'b0100;
                            if (sx_left <= 7'd1) sx_last <= 1'b1;
                            else                 sx_left <= sx_left - 7'd1;
                        end
                    end
                    default: begin
                        out_sysex_vld  <= in_sysex_vld[3];
                        out_sysex_byte <= in_sysex_byte[31:24];
                        out_sysex_err  <= in_sysex_err[3];
                        if (in_sysex_vld[3]) begin
                            in_sysex_ack <= 4'b1000;
                            if (sx_left <= 7'd1) sx_last <= 1'b1;
                            else                 sx_left <= sx_left - 7'd1;
                        end
                    end
                endcase
                if (sx_last) begin                        // 已透传出去 → 释放
                    sx_busy <= 1'b0;
                    sx_last <= 1'b0;
                end
            end

            //================================================================
            // 三、仲裁：消息优先；都没有才接受新的 SysEx
            //================================================================
            if (!sx_busy && !msg_busy) begin
                if (any_msg) begin
                    msg_busy    <= 1'b1;
                    msg_acked   <= 1'b0;
                    msg_owner   <= msel;
                    out_msg_vld <= 1'b1;
                    out_msg_port<= msel;
                    case (msel)
                        2'd0: begin
                            out_msg_status <= in_msg_status[7:0];
                            out_msg_d0     <= in_msg_d0[7:0];
                            out_msg_d1     <= in_msg_d1[7:0];
                        end
                        2'd1: begin
                            out_msg_status <= in_msg_status[15:8];
                            out_msg_d0     <= in_msg_d0[15:8];
                            out_msg_d1     <= in_msg_d1[15:8];
                        end
                        2'd2: begin
                            out_msg_status <= in_msg_status[23:16];
                            out_msg_d0     <= in_msg_d0[23:16];
                            out_msg_d1     <= in_msg_d1[23:16];
                        end
                        default: begin
                            out_msg_status <= in_msg_status[31:24];
                            out_msg_d0     <= in_msg_d0[31:24];
                            out_msg_d1     <= in_msg_d1[31:24];
                        end
                    endcase
                end
                else if (any_sysex) begin
                    sx_busy         <= 1'b1;
                    sx_owner        <= ssel;
                    out_sysex_start <= 1'b1;
                    case (ssel)
                        2'd0: begin
                            sx_left       <= in_sysex_len[6:0];
                            out_sysex_len <= in_sysex_len[6:0];
                        end
                        2'd1: begin
                            sx_left       <= in_sysex_len[13:7];
                            out_sysex_len <= in_sysex_len[13:7];
                        end
                        2'd2: begin
                            sx_left       <= in_sysex_len[20:14];
                            out_sysex_len <= in_sysex_len[20:14];
                        end
                        default: begin
                            sx_left       <= in_sysex_len[27:21];
                            out_sysex_len <= in_sysex_len[27:21];
                        end
                    endcase
                end
            end
        end
    end

    // 未使用的输入（保留接口，避免综合告警）
    wire _unused = out_sysex_ack;

endmodule
`default_nettype wire
