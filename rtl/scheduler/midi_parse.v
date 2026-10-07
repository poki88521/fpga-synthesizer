//============================================================================
//  midi_parse —— 单路 MIDI 解析器（调度层 · 事件类）
//
//  依据：documents/硬件实现.md
//    §三.二.2  位定时：f_clk / 31250 = 1572.864 → 固定 1573（误差 0.0086%）
//              接收：检测 1→0 起始位 → 等 1.5 bit → 按位间隔采 8 位 → 采停止位校验
//    §三.二.3  解析 FSM：ST_IDLE / ST_D1 / ST_D2 / ST_SYSEX / ST_SYSEX_SKIP
//              运行状态：通道状态字节「替换」、System Common/SysEx「清除」、
//                        实时字节（F8–FE）「不影响」且可就地旁路、FF「清除并复位」
//              边界：数据字节多余 → 按运行状态解析；不足 → 等下一个状态字节并重置
//    §三.二.4  消息输出：msg_vld 保持到 msg_ack
//    §三.二.5  SysEx 保护：长度上限 64 字节、字节间超时 10 ms（312 个 midi_tick）
//              校验全部通过后才交付（先缓存、后交付）
//
//  设计要点：
//    · 接收器内部用 clk 计数（不依赖 midi_tick），因为要采"位中心"需要 1.5 bit 精度；
//       midi_tick 只用于 SysEx 超时计数（312 ≈ 10 ms，9~10 位计数器即可）。
//    · 相位累加器式的"不清零"规则与本模块无关；本模块所有状态在 rst_n_sync 下清零。
//    · 实时字节可就地旁路：判断放在**每个字节入口**，而不是消息边界。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module midi_parse #(
    parameter [1:0]  PORT_ID    = 2'd0,      // 端口号：0~2 乐器、3 混音器
    parameter        INV_INPUT  = 1'b0,      // 1 = 输入取反（光耦极性，上板一位切换）
    parameter [11:0] BIT_TICK   = 12'd1573,  // 1 bit 的 clk 数
    parameter [11:0] START_DLY  = 12'd2359,  // 起始沿后到 d0 位中心的 clk 数（1.5 bit）
    parameter [6:0]  SYSEX_MAX  = 7'd64,     // SysEx 数据字节上限（不含 F0 / F7）
    parameter [9:0]  SYSEX_TO   = 10'd312    // 字节间超时（midi_tick 数，312 ≈ 10 ms）
)(
    input  wire       clk,
    input  wire       rst_n_sync,
    input  wire       midi_tick,        // 位节拍（÷1573），仅用于 SysEx 超时计数
    input  wire       rx,               // 串行输入（外部已两级触发器同步）
    input  wire       msg_ack,          // 下游已接收本条消息
    input  wire       sysex_ack,        // SysEx 已接收完（当前仅作调试计数，交付为自动流式）

    // ——— 非 SysEx 消息 ———
    output reg        msg_vld,          // 保持到 msg_ack
    output reg  [7:0] msg_status,       // 状态字节（含通道号）
    output reg  [7:0] msg_d0,
    output reg  [7:0] msg_d1,
    output wire [1:0] msg_port,
    output reg        msg_drop,         // 未完成消息被重置（调试计数）
    output reg        msg_ovf,          // 上一条尚未 ack 又来一条（调试计数，正常不会发生）

    // ——— SysEx ———
    output reg        sysex_start,      // 单拍脉冲，同拍 sysex_len 有效
    output reg  [6:0] sysex_len,        // 后续字节数（不含 F0 / F7）
    output reg        sysex_vld,        // 每拍一个字节
    output reg  [7:0] sysex_byte,
    output reg        sysex_err,        // 超长 / 超时（整条丢弃）
    output reg        frame_err         // 停止位校验失败（该字节丢弃）
);
    assign msg_port = PORT_ID;

    //========================================================================
    // 一、输入同步与极性
    //========================================================================
    reg rx_s0, rx_s1;
    always @(posedge clk or negedge rst_n_sync)
        if (!rst_n_sync) begin rx_s0 <= 1'b1; rx_s1 <= 1'b1; end
        else             begin rx_s0 <= rx;    rx_s1 <= rx_s0; end

    wire rx_in = INV_INPUT ? ~rx_s1 : rx_s1;

    //========================================================================
    // 二、字节接收（位定时）
    //   RX_IDLE 等起始位 → RX_WAIT 等 1.5 bit 采 d0 → RX_DATA 每 1 bit 采一位
    //   → RX_STOP 采停止位并校验
    //========================================================================
    localparam [1:0] RX_IDLE = 2'd0, RX_WAIT = 2'd1, RX_DATA = 2'd2, RX_STOP = 2'd3;

    reg  [1:0]  rxst;
    reg  [11:0] rxcnt;
    reg  [2:0]  biti;
    reg  [7:0]  shreg;
    reg         byte_vld;

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            rxst     <= RX_IDLE;
            rxcnt    <= 12'd0;
            biti     <= 3'd0;
            shreg    <= 8'd0;
            byte_vld <= 1'b0;
            frame_err<= 1'b0;
        end else begin
            byte_vld <= 1'b0;
            case (rxst)
                RX_IDLE: if (!rx_in) begin              // 起始位下降沿
                             rxst  <= RX_WAIT;
                             rxcnt <= 12'd0;
                         end
                RX_WAIT: begin                          // 等 1.5 bit → 采 d0（位中心）
                             if (rxcnt == START_DLY - 12'd1) begin
                                 shreg[0] <= rx_in;
                                 rxcnt    <= 12'd0;
                                 biti     <= 3'd1;
                                 rxst     <= RX_DATA;
                             end else rxcnt <= rxcnt + 12'd1;
                         end
                RX_DATA: begin                          // 每 1 bit 采一位，共 8 位
                             if (rxcnt == BIT_TICK - 12'd1) begin
                                 rxcnt <= 12'd0;
                                 if (biti == 3'd7) begin
                                     shreg[7] <= rx_in;
                                     rxst     <= RX_STOP;
                                 end else begin
                                     shreg[biti] <= rx_in;
                                     biti        <= biti + 3'd1;
                                 end
                             end else rxcnt <= rxcnt + 12'd1;
                         end
                RX_STOP: begin                          // 采停止位（位中心）
                             if (rxcnt == BIT_TICK - 12'd1) begin
                                 rxcnt <= 12'd0;
                                 rxst  <= RX_IDLE;
                                 if (rx_in) byte_vld <= 1'b1;     // 停止位为 1 → 字节有效
                                 else       frame_err<= 1'b1;     // 停止位为 0 → 丢弃该字节
                             end else rxcnt <= rxcnt + 12'd1;
                         end
                default: rxst <= RX_IDLE;
            endcase
        end
    end

    wire [7:0] rx_byte = shreg;

    //========================================================================
    // 三、字节解析 FSM
    //========================================================================
    localparam [2:0] ST_IDLE       = 3'd0,
                     ST_D1         = 3'd1,
                     ST_D2         = 3'd2,
                     ST_SYSEX      = 3'd3,
                     ST_SYSEX_SKIP = 3'd4;

    reg [2:0] st;
    reg [7:0] run_status;      // 运行状态（当前有效的状态字节）
    reg       run_valid;
    reg       run_2byte;       // 当前运行状态消息需要 2 个数据字节
    reg [7:0] d0_buf;          // 第 1 个数据字节

    // SysEx 缓冲与交付
    reg [7:0] sxbuf [0:63];
    reg [6:0] sxlen;           // 已收字节数
    reg [9:0] sxto;            // 超时计数（midi_tick）
    reg       txing;           // 交付中
    reg [6:0] txidx;           // 交付索引

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            st           <= ST_IDLE;
            run_status   <= 8'd0;
            run_valid    <= 1'b0;
            run_2byte    <= 1'b0;
            d0_buf       <= 8'd0;
            msg_vld      <= 1'b0;
            msg_status   <= 8'd0;
            msg_d0       <= 8'd0;
            msg_d1       <= 8'd0;
            msg_drop     <= 1'b0;
            msg_ovf      <= 1'b0;
            sxlen        <= 7'd0;
            sxto         <= 10'd0;
            txing        <= 1'b0;
            txidx        <= 7'd0;
            sysex_start  <= 1'b0;
            sysex_len    <= 7'd0;
            sysex_vld    <= 1'b0;
            sysex_byte   <= 8'd0;
            sysex_err    <= 1'b0;
        end else begin
            // ---- 默认脉冲 ----
            msg_drop    <= 1'b0;
            sysex_err   <= 1'b0;
            sysex_start <= 1'b0;
            sysex_vld   <= 1'b0;

            // ---- msg_ack 清除 msg_vld ----
            if (msg_vld && msg_ack) msg_vld <= 1'b0;

            if (txing) begin
                //----------------------------------------------------------
                // SysEx 交付：sysex_start 之后每拍一个字节，共 sysex_len 拍
                //----------------------------------------------------------
                sysex_vld  <= 1'b1;
                sysex_byte <= sxbuf[txidx[5:0]];
                if (txidx == sxlen - 7'd1) begin
                    txing <= 1'b0;
                    st    <= ST_IDLE;
                end else begin
                    txidx <= txidx + 7'd1;
                end
            end
            else if (byte_vld) begin
                //----------------------------------------------------------
                // 一个字节收完 → 分类处理
                //----------------------------------------------------------
                if (rx_byte >= 8'hF8) begin
                    // 实时字节（F8–FE）与 FF：就地旁路
                    //   F8–FE 不影响运行状态、不打断当前消息；
                    //   FF（System Reset）按 §三.二.3 应「清除运行状态并复位解析器」
                    if (rx_byte == 8'hFF) begin
                        run_valid <= 1'b0;
                        st        <= ST_IDLE;
                    end
                    // 其余实时字节：什么都不做
                end
                else if (rx_byte >= 8'h80) begin
                    //-------------------- 状态字节 --------------------
                    if (rx_byte == 8'hF0) begin
                        // SysEx 开始
                        st        <= ST_SYSEX;
                        sxlen     <= 7'd0;
                        sxto      <= 10'd0;
                        run_valid <= 1'b0;
                    end
                    else if (rx_byte == 8'hF7 && st == ST_SYSEX) begin
                        // SysEx 正常结束 → 校验通过才交付
                        run_valid <= 1'b0;
                        if (sxlen != 7'd0) begin
                            sysex_start <= 1'b1;
                            sysex_len   <= sxlen;
                            txing       <= 1'b1;
                            txidx       <= 7'd0;
                        end else begin
                            st <= ST_IDLE;
                        end
                    end
                    else if (rx_byte >= 8'hF1 && rx_byte <= 8'hF7) begin
                        // System Common（F1–F7，非 SysEx）
                        //   注意：条件必须从 F1 起，否则会连通道消息（0x80–0xEF）一起吃掉
                        run_valid <= 1'b0;
                        if (rx_byte <= 8'hF3) begin
                            // F1 / F2 / F3 带数据字节：按 2 字节消息收
                            run_status <= rx_byte;
                            run_2byte  <= 1'b1;
                            st         <= ST_D1;
                        end else begin
                            // F4 / F5 / F6 / F7：丢弃
                            st <= ST_IDLE;
                        end
                    end
                    else begin
                        // 通道消息（80–EF）：替换运行状态
                        if (st == ST_D1 || st == ST_D2) msg_drop <= 1'b1;  // 未完成消息被重置
                        run_status <= rx_byte;
                        run_valid  <= 1'b1;
                        run_2byte  <= !((rx_byte[7:4] == 4'hC) || (rx_byte[7:4] == 4'hD));
                        st         <= ST_D1;
                    end
                end
                else begin
                    //-------------------- 数据字节 --------------------
                    case (st)
                        ST_D1: begin
                            d0_buf <= rx_byte;
                            if (run_2byte) begin
                                st <= ST_D2;
                            end else begin
                                // 单数据字节消息（0xCn / 0xDn）→ 发射
                                msg_status <= run_status;
                                msg_d0     <= rx_byte;
                                msg_d1     <= 8'd0;
                                msg_vld    <= 1'b1;
                                if (msg_vld) msg_ovf <= 1'b1;
                                st         <= ST_IDLE;
                            end
                        end
                        ST_D2: begin
                            msg_status <= run_status;
                            msg_d0     <= d0_buf;
                            msg_d1     <= rx_byte;
                            msg_vld    <= 1'b1;
                            if (msg_vld) msg_ovf <= 1'b1;
                            st         <= ST_IDLE;
                        end
                        ST_IDLE: begin
                            // 多余数据字节：视为「下一条运行状态消息的开头」
                            if (run_valid) begin
                                d0_buf <= rx_byte;
                                if (run_2byte) begin
                                    st <= ST_D2;
                                end else begin
                                    msg_status <= run_status;
                                    msg_d0     <= rx_byte;
                                    msg_d1     <= 8'd0;
                                    msg_vld    <= 1'b1;
                                    if (msg_vld) msg_ovf <= 1'b1;
                                    st         <= ST_IDLE;
                                end
                            end
                            // run_valid = 0：无运行状态可用 → 丢弃
                        end
                        ST_SYSEX: begin
                            if (sxlen < SYSEX_MAX) begin
                                sxbuf[sxlen[5:0]] <= rx_byte;
                                sxlen             <= sxlen + 7'd1;
                                sxto              <= 10'd0;
                            end else begin
                                // 超长 → 丢弃整条
                                sysex_err <= 1'b1;
                                st        <= ST_SYSEX_SKIP;
                            end
                        end
                        ST_SYSEX_SKIP: begin
                            // 丢弃剩余数据，等 F7 结束
                        end
                        default: st <= ST_IDLE;
                    endcase
                end
            end
            else if (midi_tick && (st == ST_SYSEX || st == ST_SYSEX_SKIP)) begin
                //----------------------------------------------------------
                // SysEx 字节间超时（10 ms ≈ 312 个 midi_tick）
                //----------------------------------------------------------
                if (sxto >= SYSEX_TO - 10'd1) begin
                    sxto <= 10'd0;
                    if (st == ST_SYSEX) begin
                        sysex_err <= 1'b1;
                        st        <= ST_SYSEX_SKIP;
                    end else begin
                        st <= ST_IDLE;          // SKIP 里也等不到 F7 → 放弃
                    end
                end else begin
                    sxto <= sxto + 10'd1;
                end
            end
        end
    end

    // 调试：sysex_ack 仅用于观测（交付为自动流式，不等 ack）
    // verilator lint_off UNUSED
    wire _unused_sysex_ack = sysex_ack;
    // verilator lint_on UNUSED

endmodule
`default_nettype wire
