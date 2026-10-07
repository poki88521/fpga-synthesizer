//============================================================================
//  tb_midi_arb —— midi_arb 单元测试（直接驱动 4 路，不经过 midi_parse）
//
//  覆盖（对应 documents/硬件实现.md §三.一.1 / §三.一.5(2)）：
//    ① 单路请求 → 输出对应端口号与内容
//    ② 多路同时请求 → 固定优先级 0 → 3（用"先拉高再复位"制造确定的并发）
//    ③ 交付保持到下游 ack；ack 后回落源路 ack；源撤 vld 后释放
//    ④ SysEx 多拍流：锁定选中路逐字节透传（含最后一个字节）
//    ⑤ 释放后可换另一路继续
//
//  ⚠ 本 TB 踩过的四个坑（写在这里，其它 TB 也要照这个规矩来）：
//    ① 驱动输入一律在 **negedge** 更新（或边沿之后），绝不在 posedge 附近直接改
//       —— 否则与 DUT 的 posedge 采样竞争，结果不确定。
//    ② 要制造"多路同时请求"，先把输入摆好再**复位** DUT，让它在复位释放后的
//       第一拍同时看到全部请求。
//    ③ DUT 的单拍脉冲（out_sysex_start 等）要用 always 捕获，不要在几拍之后
//       才去等它 —— 会错过。
//    ④ 不要用 reg 向量做「变量 indexed part-select 赋值」驱动，改为每路一份
//       数组 + 连续赋值拼接。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_midi_arb;
    reg clk = 0;
    always #10 clk = ~clk;                 // 本模块与位定时无关，50 MHz 足够

    reg rst_n = 0;

    // ---- 每路独立的源 ----
    reg        s_vld [0:3];
    reg [7:0]  s_st  [0:3];
    reg [7:0]  s_d0  [0:3];
    reg [7:0]  s_d1  [0:3];
    reg        s_ss  [0:3];
    reg [6:0]  s_sl  [0:3];
    reg        s_sv  [0:3];
    reg [7:0]  s_sb  [0:3];

    wire [3:0]  in_msg_vld     = {s_vld[3], s_vld[2], s_vld[1], s_vld[0]};
    wire [31:0] in_msg_status  = {s_st[3],  s_st[2],  s_st[1],  s_st[0]};
    wire [31:0] in_msg_d0      = {s_d0[3],  s_d0[2],  s_d0[1],  s_d0[0]};
    wire [31:0] in_msg_d1      = {s_d1[3],  s_d1[2],  s_d1[1],  s_d1[0]};
    wire [3:0]  in_sysex_start = {s_ss[3],  s_ss[2],  s_ss[1],  s_ss[0]};
    wire [27:0] in_sysex_len   = {s_sl[3],  s_sl[2],  s_sl[1],  s_sl[0]};
    wire [3:0]  in_sysex_vld   = {s_sv[3],  s_sv[2],  s_sv[1],  s_sv[0]};
    wire [31:0] in_sysex_byte  = {s_sb[3],  s_sb[2],  s_sb[1],  s_sb[0]};
    wire [3:0]  in_sysex_err   = 4'd0;

    reg out_msg_ack = 0;

    wire [3:0]  in_msg_ack, in_sysex_ack;
    wire        out_msg_vld, out_sysex_start, out_sysex_vld, out_sysex_err;
    wire [7:0]  out_msg_status, out_msg_d0, out_msg_d1, out_sysex_byte;
    wire [1:0]  out_msg_port;
    wire [6:0]  out_sysex_len;

    midi_arb dut (
        .clk(clk), .rst_n_sync(rst_n),
        .in_msg_vld(in_msg_vld), .in_msg_status(in_msg_status),
        .in_msg_d0(in_msg_d0), .in_msg_d1(in_msg_d1),
        .in_sysex_start(in_sysex_start), .in_sysex_len(in_sysex_len),
        .in_sysex_vld(in_sysex_vld), .in_sysex_byte(in_sysex_byte),
        .in_sysex_err(in_sysex_err),
        .in_msg_ack(in_msg_ack), .in_sysex_ack(in_sysex_ack),
        .out_msg_vld(out_msg_vld), .out_msg_status(out_msg_status),
        .out_msg_d0(out_msg_d0), .out_msg_d1(out_msg_d1), .out_msg_port(out_msg_port),
        .out_msg_ack(out_msg_ack),
        .out_sysex_start(out_sysex_start), .out_sysex_len(out_sysex_len),
        .out_sysex_vld(out_sysex_vld), .out_sysex_byte(out_sysex_byte),
        .out_sysex_err(out_sysex_err), .out_sysex_ack(1'b0)
    );

    // ---- 单拍脉冲捕获（不要在几拍之后才去等它）----
    reg        cap_start_seen = 0;
    reg [6:0]  cap_start_len  = 0;
    reg [7:0]  cap_sxb [0:7];
    integer    cap_sxn = 0;
    always @(posedge clk) begin
        if (out_sysex_start) begin
            cap_start_seen <= 1'b1;
            cap_start_len  <= out_sysex_len;
        end
        if (out_sysex_vld && cap_sxn < 8) begin
            cap_sxb[cap_sxn] <= out_sysex_byte;
            cap_sxn          <= cap_sxn + 1;
        end
    end

    integer errors = 0;
    integer i;

    task clr_src;
        begin
            for (i = 0; i < 4; i = i + 1) begin
                s_vld[i] = 1'b0; s_st[i] = 8'd0; s_d0[i] = 8'd0; s_d1[i] = 8'd0;
                s_ss[i]  = 1'b0; s_sl[i] = 7'd0; s_sv[i] = 1'b0; s_sb[i] = 8'd0;
            end
        end
    endtask

    // 等 arb 空闲（没有正在交付的消息、也没有挂起的消息请求）
    task wait_idle;
        integer g;
        begin
            g = 0;
            while ((out_msg_vld || (|in_msg_vld)) && g < 200) begin @(posedge clk); g = g + 1; end
            repeat (4) @(posedge clk);
        end
    endtask

    // 驱动一路消息，并完整走完一次握手（输入只在 negedge 更新）
    task drive_msg(input [1:0] port, input [7:0] st, input [7:0] d0, input [7:0] d1,
                    input [255:0] name);
        integer guard;
        begin
            @(negedge clk);
            s_vld[port] = 1'b1; s_st[port] = st; s_d0[port] = d0; s_d1[port] = d1;

            guard = 0;
            while (!(out_msg_vld && out_msg_port == port) && guard < 200) begin
                @(posedge clk); guard = guard + 1;
            end
            if (guard >= 200) begin
                errors = errors + 1;
                $display("FAIL  %0s : no out_msg for port %0d", name, port);
            end else if (out_msg_status !== st || out_msg_d0 !== d0 || out_msg_d1 !== d1) begin
                errors = errors + 1;
                $display("FAIL  %0s : got %02x %02x %02x, exp %02x %02x %02x",
                         name, out_msg_status, out_msg_d0, out_msg_d1, st, d0, d1);
            end else begin
                $display("  ok  %0s : port=%0d %02x %02x %02x", name, out_msg_port, st, d0, d1);
            end

            @(negedge clk); out_msg_ack = 1'b1;
            @(negedge clk); out_msg_ack = 1'b0;

            guard = 0;
            while (!in_msg_ack[port] && guard < 20) begin @(posedge clk); guard = guard + 1; end
            if (!in_msg_ack[port]) begin
                errors = errors + 1;
                $display("FAIL  %0s : no in_msg_ack[%0d]", name, port);
            end

            @(negedge clk); s_vld[port] = 1'b0;
            repeat (6) @(posedge clk);
            if (out_msg_vld) begin
                errors = errors + 1;
                $display("FAIL  %0s : out_msg_vld not released", name);
            end
        end
    endtask

    // SysEx 多拍透传：按 midi_parse 的真实时序（start 单拍，随后 len 拍连续 vld）
    task drive_sysex(input [1:0] port, input [6:0] len,
                     input [7:0] b0, input [7:0] b1, input [7:0] b2,
                     input [255:0] name);
        integer k;
        reg [7:0] expb;
        begin
            cap_start_seen = 1'b0;
            cap_sxn        = 0;

            // start 单拍（negedge 更新，posedge 时稳定）
            @(negedge clk);
            s_sl[port] = len;
            s_ss[port] = 1'b1;
            @(negedge clk);
            s_ss[port] = 1'b0;

            // 随后 len 拍连续 vld，每字节恰好一拍
            for (k = 0; k < len; k = k + 1) begin
                case (k)
                    0: expb = b0;
                    1: expb = b1;
                    default: expb = b2;
                endcase
                s_sb[port] = expb;
                s_sv[port] = 1'b1;
                @(negedge clk);
                s_sv[port] = 1'b0;
            end
            repeat (6) @(posedge clk);

            if (!cap_start_seen) begin
                errors = errors + 1;
                $display("FAIL  %0s : no out_sysex_start", name);
            end else if (cap_start_len !== len) begin
                errors = errors + 1;
                $display("FAIL  %0s : start len=%0d exp=%0d", name, cap_start_len, len);
            end
            if (cap_sxn !== len) begin
                errors = errors + 1;
                $display("FAIL  %0s : relayed %0d bytes, exp %0d", name, cap_sxn, len);
            end else if (cap_sxb[0] !== b0 || cap_sxb[1] !== b1 || cap_sxb[len-1] !== b2) begin
                errors = errors + 1;
                $display("FAIL  %0s : bytes %02x %02x .. %02x, exp %02x %02x .. %02x",
                         name, cap_sxb[0], cap_sxb[1], cap_sxb[len-1], b0, b1, b2);
            end else begin
                $display("  ok  %0s : %0d bytes relayed, len=%0d", name, cap_sxn, cap_start_len);
            end
        end
    endtask

    initial begin
        $dumpfile("tb_midi_arb.vcd");
        $dumpvars(0, tb_midi_arb);

        clr_src;
        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (5) @(posedge clk);

        //--------------------------------------------------------------
        $display("== 1. single request per port ==");
        drive_msg(2'd0, 8'h90, 8'h3C, 8'h64, "port0");
        drive_msg(2'd3, 8'hB0, 8'h07, 8'h64, "port3");

        //--------------------------------------------------------------
        $display("== 2. priority: all four request simultaneously ==");
        // 先把 4 路请求摆好，再复位 arb —— 它在复位释放后的第一拍一定同时看到 4 路
        wait_idle;
        clr_src;
        for (i = 0; i < 4; i = i + 1) s_vld[i] = 1'b1;
        s_st[0] = 8'h90; s_d0[0] = 8'h11; s_d1[0] = 8'h22;
        s_st[1] = 8'h91; s_d0[1] = 8'h33; s_d1[1] = 8'h44;
        s_st[2] = 8'h92; s_d0[2] = 8'h55; s_d1[2] = 8'h66;
        s_st[3] = 8'h93; s_d0[3] = 8'h77; s_d1[3] = 8'h88;
        @(negedge clk); rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        repeat (5) @(posedge clk);
        if (out_msg_vld && out_msg_port == 2'd0 && out_msg_d0 == 8'h11) begin
            $display("  ok  priority : port0 (highest) selected");
        end else begin
            errors = errors + 1;
            $display("FAIL  priority : port=%0d d0=%02x (exp port0 d0=11)", out_msg_port, out_msg_d0);
        end

        // 交付路 0 并撤掉它 → 接下来应选路 1
        @(negedge clk); out_msg_ack = 1'b1; @(negedge clk); out_msg_ack = 1'b0;
        repeat (6) @(posedge clk);
        @(negedge clk); s_vld[0] = 1'b0;
        repeat (8) @(posedge clk);
        if (out_msg_vld && out_msg_port == 2'd1 && out_msg_d0 == 8'h33) begin
            $display("  ok  priority : port1 selected next");
        end else begin
            errors = errors + 1;
            $display("FAIL  priority : next port=%0d d0=%02x (exp port1 d0=33)", out_msg_port, out_msg_d0);
        end
        clr_src;
        @(negedge clk); out_msg_ack = 1'b1; @(negedge clk); out_msg_ack = 1'b0;
        repeat (10) @(posedge clk);

        //--------------------------------------------------------------
        $display("== 3. sysex multi-byte relay ==");
        wait_idle;
        drive_sysex(2'd1, 7'd3, 8'h7D, 8'h01, 8'h02, "sysex port1");
        wait_idle;
        drive_sysex(2'd3, 7'd3, 8'h7F, 8'h7F, 8'h04, "sysex port3");

        if (errors == 0) $display("PASS  tb_midi_arb");
        else             $display("FAIL  tb_midi_arb : %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
