//============================================================================
//  tb_midi_sysex —— midi_parse 的 SysEx 保护测试
//
//  覆盖（对应 documents/硬件实现.md §三.二.5）：
//    ① 正常 SysEx：主音量 F0 7F 7F 04 01 00 40 F7（len = 6）
//    ② 正常 SysEx：效果参数 F0 7D 01 02 12 34 F7（len = 5）
//    ③ 长度上限：> 64 字节 → sysex_err，整条丢弃
//    ④ 字节间超时：> 312 个 midi_tick → sysex_err，整条丢弃
//    ⑤ 空 SysEx（F0 F7）→ 不交付、不报错
//    ⑥ 校验通过后才交付：交付期间逐字节与源数据一致
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_midi_sysex;
    localparam real    TCLK   = 20.345;
    localparam integer BITCLK = 1573;

    reg clk = 0;
    always #(TCLK/2.0) clk = ~clk;

    reg rst_n = 0, rx = 1, msg_ack = 0, midi_tick = 0;

    wire       msg_vld;
    wire [7:0] msg_status, msg_d0, msg_d1;
    wire [1:0] msg_port;
    wire       msg_drop, msg_ovf;
    wire       sysex_start, sysex_vld, sysex_err, frame_err;
    wire [6:0] sysex_len;
    wire [7:0] sysex_byte;

    midi_parse #(.PORT_ID(2'd3)) dut (
        .clk(clk), .rst_n_sync(rst_n), .midi_tick(midi_tick), .rx(rx),
        .msg_ack(msg_ack), .sysex_ack(1'b1),
        .msg_vld(msg_vld), .msg_status(msg_status), .msg_d0(msg_d0), .msg_d1(msg_d1),
        .msg_port(msg_port), .msg_drop(msg_drop), .msg_ovf(msg_ovf),
        .sysex_start(sysex_start), .sysex_len(sysex_len), .sysex_vld(sysex_vld),
        .sysex_byte(sysex_byte), .sysex_err(sysex_err), .frame_err(frame_err)
    );

    integer tc = 0;
    always @(posedge clk) begin
        midi_tick <= 1'b0;
        if (tc == BITCLK-1) begin tc <= 0; midi_tick <= 1'b1; end
        else                     tc <= tc + 1;
    end

    // 单拍脉冲的"曾经出现"监视
    reg sysex_err_seen = 0;
    reg sysex_start_seen = 0;
    always @(posedge clk) begin
        if (sysex_err)   sysex_err_seen   <= 1'b1;
        if (sysex_start) sysex_start_seen <= 1'b1;
    end

    task send_bit(input v);
        begin rx = v; repeat (BITCLK) @(posedge clk); end
    endtask

    task send_byte(input [7:0] b);
        integer i;
        begin
            send_bit(1'b0);
            for (i = 0; i < 8; i = i + 1) send_bit(b[i]);
            send_bit(1'b1);
        end
    endtask

    integer errors = 0;
    reg [7:0] got [0:63];
    integer   got_n;

    // 等 sysex_start，记录长度并逐拍收字节
    task collect_sysex(input integer exp_len, input [255:0] name);
        integer guard;
        begin
            got_n = 0;
            guard = 0;
            while (!sysex_start && guard < 300000) begin @(posedge clk); guard = guard + 1; end
            if (!sysex_start) begin
                errors = errors + 1;
                $display("FAIL  %0s : no sysex_start", name);
            end else begin
                if (sysex_len !== exp_len[6:0]) begin
                    errors = errors + 1;
                    $display("FAIL  %0s : len=%0d exp=%0d", name, sysex_len, exp_len);
                end
                @(posedge clk);                        // sysex_start 之后下一拍才开始出字节
                while (sysex_vld && got_n < 64) begin
                    got[got_n] = sysex_byte;
                    got_n = got_n + 1;
                    @(posedge clk);
                end
                if (got_n !== exp_len) begin
                    errors = errors + 1;
                    $display("FAIL  %0s : collected %0d bytes, exp %0d", name, got_n, exp_len);
                end else begin
                    $display("  ok  %0s : %0d bytes delivered", name, got_n);
                end
            end
            repeat (4) @(posedge clk);
        end
    endtask

    task chk_byte(input integer idx, input [7:0] e, input [255:0] name);
        begin
            if (got[idx] !== e) begin
                errors = errors + 1;
                $display("FAIL  %0s [%0d] : got %02x exp %02x", name, idx, got[idx], e);
            end
        end
    endtask

    integer i;
    initial begin
        $dumpfile("tb_midi_sysex.vcd");
        $dumpvars(0, tb_midi_sysex);

        repeat (10) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (5) @(posedge clk);

        //--------------------------------------------------------------
        $display("== 1. master volume sysex  F0 7F 7F 04 01 00 40 F7 ==");
        // 发送与收集必须并行：SysEx 交付只有几拍，等发完再找 sysex_start 会错过
        fork
            collect_sysex(6, "master volume");
            begin
                send_byte(8'hF0);
                send_byte(8'h7F); send_byte(8'h7F); send_byte(8'h04);
                send_byte(8'h01); send_byte(8'h00); send_byte(8'h40);
                send_byte(8'hF7);
            end
        join
        chk_byte(0, 8'h7F, "master volume");
        chk_byte(1, 8'h7F, "master volume");
        chk_byte(2, 8'h04, "master volume");
        chk_byte(3, 8'h01, "master volume");
        chk_byte(4, 8'h00, "master volume");
        chk_byte(5, 8'h40, "master volume");

        //--------------------------------------------------------------
        $display("== 2. effect param sysex  F0 7D 01 02 12 34 F7 ==");
        fork
            collect_sysex(5, "effect param");
            begin
                send_byte(8'hF0);
                send_byte(8'h7D); send_byte(8'h01); send_byte(8'h02);
                send_byte(8'h12); send_byte(8'h34);
                send_byte(8'hF7);
            end
        join
        chk_byte(0, 8'h7D, "effect param");
        chk_byte(1, 8'h01, "effect param");
        chk_byte(4, 8'h34, "effect param");

        //--------------------------------------------------------------
        $display("== 3. empty sysex  F0 F7 ==");
        sysex_start_seen = 1'b0;
        send_byte(8'hF0); send_byte(8'hF7);
        repeat (200) @(posedge clk);
        if (sysex_start_seen) begin
            errors = errors + 1;
            $display("FAIL  empty sysex : unexpected delivery");
        end else if (sysex_err_seen) begin
            errors = errors + 1;
            $display("FAIL  empty sysex : unexpected error");
        end else begin
            $display("  ok  empty sysex : no delivery, no error");
        end

        //--------------------------------------------------------------
        $display("== 4. too long (> 64 bytes) -> sysex_err ==");
        sysex_err_seen   = 1'b0;
        sysex_start_seen = 1'b0;
        send_byte(8'hF0);
        for (i = 0; i < 65; i = i + 1) send_byte(8'h11);   // 65 > 64
        send_byte(8'hF7);
        repeat (400) @(posedge clk);
        if (!sysex_err_seen) begin
            errors = errors + 1;
            $display("FAIL  too long : sysex_err not asserted");
        end else if (sysex_start_seen) begin
            errors = errors + 1;
            $display("FAIL  too long : should not deliver");
        end else begin
            $display("  ok  too long : error asserted, nothing delivered");
        end

        //--------------------------------------------------------------
        $display("== 5. byte-gap timeout (> 312 midi_tick) -> sysex_err ==");
        sysex_err_seen   = 1'b0;
        sysex_start_seen = 1'b0;
        send_byte(8'hF0);
        send_byte(8'h7D); send_byte(8'h01);      // 只发 2 个字节，然后停下
        repeat (340 * BITCLK) @(posedge clk);    // 等超过 10 ms
        if (!sysex_err_seen) begin
            errors = errors + 1;
            $display("FAIL  timeout : sysex_err not asserted");
        end else if (sysex_start_seen) begin
            errors = errors + 1;
            $display("FAIL  timeout : should not deliver");
        end else begin
            $display("  ok  timeout : error asserted, nothing delivered");
        end

        //--------------------------------------------------------------
        $display("== 6. recovers after errors ==");
        fork
            collect_sysex(3, "after errors");
            begin
                send_byte(8'hF0);
                send_byte(8'h7D); send_byte(8'h02); send_byte(8'h2B);
                send_byte(8'hF7);
            end
        join
        chk_byte(0, 8'h7D, "after errors");
        chk_byte(2, 8'h2B, "after errors");

        if (errors == 0) $display("PASS  tb_midi_sysex");
        else             $display("FAIL  tb_midi_sysex : %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
