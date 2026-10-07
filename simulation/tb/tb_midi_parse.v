//============================================================================
//  tb_midi_parse —— midi_parse 单元测试
//
//  覆盖（对应 documents/硬件实现.md §三.二）：
//    ① 普通 3 字节消息（Note On / Note Off）
//    ② Running Status：后续消息省略状态字节
//    ③ 实时字节（F8）插入数据字节之间 → 不打断、不影响运行状态
//    ④ 单数据字节消息（0xCn / 0xDn）+ 其运行状态
//    ⑤ 数据字节「多余」→ 视为下一条运行状态消息的开头
//    ⑥ 数据字节「不足」→ 遇新状态字节时重置（msg_drop）
//    ⑦ 0xFF System Reset → 清除运行状态并复位解析器
//    ⑧ 停止位错误 → frame_err，该字节丢弃
//
//  位定时：49.152 MHz（周期 20.345 ns），1 bit = 1573 clk = 31250 baud
//  复位释放统一在 negedge（避免与 posedge 抢拍）
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_midi_parse;
    localparam real    TCLK    = 20.345;     // ns，≈49.152 MHz
    localparam integer BITCLK  = 1573;       // 1 bit 的 clk 数

    reg clk = 0;
    always #(TCLK/2.0) clk = ~clk;

    reg rst_n     = 0;
    reg rx        = 1;
    reg msg_ack   = 0;
    reg midi_tick = 0;

    wire       msg_vld;
    wire [7:0] msg_status, msg_d0, msg_d1;
    wire [1:0] msg_port;
    wire       msg_drop, msg_ovf;
    wire       sysex_start, sysex_vld, sysex_err, frame_err;
    wire [6:0] sysex_len;
    wire [7:0] sysex_byte;

    midi_parse #(
        .PORT_ID  (2'd1),
        .INV_INPUT(1'b0)
    ) dut (
        .clk         (clk),
        .rst_n_sync  (rst_n),
        .midi_tick   (midi_tick),
        .rx          (rx),
        .msg_ack     (msg_ack),
        .sysex_ack   (1'b1),
        .msg_vld     (msg_vld),
        .msg_status  (msg_status),
        .msg_d0      (msg_d0),
        .msg_d1      (msg_d1),
        .msg_port    (msg_port),
        .msg_drop    (msg_drop),
        .msg_ovf     (msg_ovf),
        .sysex_start (sysex_start),
        .sysex_len   (sysex_len),
        .sysex_vld   (sysex_vld),
        .sysex_byte  (sysex_byte),
        .sysex_err   (sysex_err),
        .frame_err   (frame_err)
    );

    //--------------------------------------------------------------- midi_tick
    integer tc = 0;
    always @(posedge clk) begin
        midi_tick <= 1'b0;
        if (tc == BITCLK-1) begin tc <= 0; midi_tick <= 1'b1; end
        else                     tc <= tc + 1;
    end

    //--------------------------------------------------------------- 驱动任务
    task send_bit(input v);
        begin
            rx = v;
            repeat (BITCLK) @(posedge clk);
        end
    endtask

    // 31250 baud，LSB 先出
    task send_byte(input [7:0] b);
        integer i;
        begin
            send_bit(1'b0);
            for (i = 0; i < 8; i = i + 1) send_bit(b[i]);
            send_bit(1'b1);
        end
    endtask

    integer errors = 0;

    task check_msg(input [7:0] e_st, input [7:0] e_d0, input [7:0] e_d1,
                   input [255:0] name);
        integer guard;
        begin
            guard = 0;
            while (!msg_vld && guard < 3000) begin @(posedge clk); guard = guard + 1; end
            if (!msg_vld) begin
                errors = errors + 1;
                $display("FAIL  %0s : no msg_vld", name);
            end else if (msg_status !== e_st || msg_d0 !== e_d0 || msg_d1 !== e_d1) begin
                errors = errors + 1;
                $display("FAIL  %0s : got %02x %02x %02x, exp %02x %02x %02x",
                         name, msg_status, msg_d0, msg_d1, e_st, e_d0, e_d1);
            end else begin
                $display("  ok  %0s : %02x %02x %02x", name, msg_status, msg_d0, msg_d1);
            end
            @(posedge clk); msg_ack = 1'b1;
            @(posedge clk); msg_ack = 1'b0;
        end
    endtask

    task expect_no_msg(input integer cycles, input [255:0] name);
        begin
            repeat (cycles) @(posedge clk);
            if (msg_vld) begin
                errors = errors + 1;
                $display("FAIL  %0s : unexpected msg %02x %02x %02x",
                         name, msg_status, msg_d0, msg_d1);
            end else begin
                $display("  ok  %0s : no message", name);
            end
        end
    endtask

    //--------------------------------------------------------------- 测试
    initial begin
        $dumpfile("tb_midi_parse.vcd");
        $dumpvars(0, tb_midi_parse);

        repeat (10) @(posedge clk);
        @(negedge clk); rst_n = 1;              // 复位在 negedge 释放
        repeat (5)  @(posedge clk);

        $display("== 1. plain 3-byte messages ==");
        send_byte(8'h90); send_byte(8'h3C); send_byte(8'h64);
        check_msg(8'h90, 8'h3C, 8'h64, "NoteOn ch0");
        send_byte(8'h80); send_byte(8'h3C); send_byte(8'h40);
        check_msg(8'h80, 8'h3C, 8'h40, "NoteOff ch0");

        $display("== 2. running status ==");
        send_byte(8'h90); send_byte(8'h40); send_byte(8'h50);
        check_msg(8'h90, 8'h40, 8'h50, "NoteOn ch0 (full)");
        send_byte(8'h41); send_byte(8'h60);          // 省略状态字节
        check_msg(8'h90, 8'h41, 8'h60, "running status");
        send_byte(8'h42); send_byte(8'h61);
        check_msg(8'h90, 8'h42, 8'h61, "running status 2");

        $display("== 3. real-time byte F8 between data bytes ==");
        send_byte(8'h90); send_byte(8'hF8); send_byte(8'h43);
        send_byte(8'hF8); send_byte(8'h70);
        check_msg(8'h90, 8'h43, 8'h70, "F8 inserted");
        send_byte(8'h44); send_byte(8'h71);          // 运行状态仍在
        check_msg(8'h90, 8'h44, 8'h71, "running status after F8");

        $display("== 4. single-data-byte messages (C0 / D0) ==");
        send_byte(8'hC0); send_byte(8'h05);
        check_msg(8'hC0, 8'h05, 8'h00, "ProgramChange ch0");
        send_byte(8'h06);                             // C0 的运行状态
        check_msg(8'hC0, 8'h06, 8'h00, "running status C0");
        send_byte(8'hD2); send_byte(8'h33);
        check_msg(8'hD2, 8'h33, 8'h00, "ChannelPressure ch2");

        $display("== 5. extra data byte -> next running-status message ==");
        send_byte(8'h90); send_byte(8'h45); send_byte(8'h72);
        check_msg(8'h90, 8'h45, 8'h72, "msg 1");
        send_byte(8'h46); send_byte(8'h73);           // 多余的 46 开头
        check_msg(8'h90, 8'h46, 8'h73, "extra data byte");

        $display("== 6. incomplete message -> reset (msg_drop) ==");
        send_byte(8'h90); send_byte(8'h47);           // 缺 d1
        repeat (5) @(posedge clk);
        send_byte(8'h80); send_byte(8'h48); send_byte(8'h30);
        check_msg(8'h80, 8'h48, 8'h30, "after incomplete");
        // msg_drop 应在收到 0x80 那一拍出现过（此处只报告，不断言历史）
        $display("  info msg_drop seen = %b", msg_drop);

        $display("== 7. 0xFF System Reset clears running status ==");
        send_byte(8'h90); send_byte(8'h49); send_byte(8'h31);
        check_msg(8'h90, 8'h49, 8'h31, "before FF");
        send_byte(8'hFF);                             // 清运行状态 + 复位解析器
        repeat (5) @(posedge clk);
        send_byte(8'h4A); send_byte(8'h32);           // 无运行状态 → 应被丢弃
        expect_no_msg(3000, "data after FF");

        $display("== 8. framing error (stop bit = 0) ==");
        send_bit(1'b0);                               // 起始位
        send_bit(1'b1); send_bit(1'b0); send_bit(1'b1); send_bit(1'b0);
        send_bit(1'b1); send_bit(1'b0); send_bit(1'b1); send_bit(1'b0);
        send_bit(1'b0);                               // 停止位错误（rx 仍为 0）
        rx = 1'b1;                                    // 立即恢复空闲线
        repeat (20) @(posedge clk);
        if (!frame_err) begin
            errors = errors + 1;
            $display("FAIL  framing : frame_err not asserted");
        end else begin
            $display("  ok  framing : frame_err asserted");
        end
        // 接收器回 IDLE 后会把残留的 0 再误判成一次起始位（数据全 1 → 收到一个 FF 字节，
        // 而 FF 是 System Reset，正好把运行状态清掉，无害）。等它走完这个垃圾字节再发消息。
        repeat (BITCLK*15) @(posedge clk);
        send_byte(8'h90); send_byte(8'h4B); send_byte(8'h33);
        check_msg(8'h90, 8'h4B, 8'h33, "recovers after framing error");

        if (errors == 0) $display("PASS  tb_midi_parse");
        else             $display("FAIL  tb_midi_parse : %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
