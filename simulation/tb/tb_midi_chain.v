//============================================================================
//  tb_midi_chain —— 解析 → 汇流 → 过滤 联调（调度层事件路径）
//
//  结构：midi_parse ×2（乐器 port1 → arb 路 0；混音器 port3 → arb 路 3）
//         → midi_arb → midi_filter
//
//  覆盖：
//    ① 乐器端口 Note On/Off（含力度 0 的 Note On → Note Off）
//    ② 通道号：状态字节低 4 位即 ch_addr（0~15），如 0x9A → ch 10
//    ③ 乐器端口混音类 CC 7/10/91/93/94 → 丢弃（drop_vld）
//    ④ 混音器端口同一批 CC → 正常写入（field_id 正确）
//    ⑤ 乐器端口演奏类 CC（11/64/66/71~74）→ 正常写入
//    ⑥ Program Change
//    ⑦ Pitch Bend → field 15，值 = MSB×128 + LSB
//    ⑧ RPN 0,0（CC101/100/6）→ field 16 bend_range
//    ⑨ SysEx 效果参数（混音器）→ ev_par_wr（grp/idx/data）
//    ⑩ SysEx 主音量 → ev_par_wr（grp=3, idx=0）
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_midi_chain;
    localparam real    TCLK   = 20.345;
    localparam integer BITCLK = 1573;

    reg clk = 0;
    always #(TCLK/2.0) clk = ~clk;

    reg rst_n = 0, midi_tick = 0;
    reg rx_inst = 1;                 // 乐器端口（→ arb 路 0）
    reg rx_mix  = 1;                 // 混音器端口（→ arb 路 3）

    integer tc = 0;
    always @(posedge clk) begin
        midi_tick <= 1'b0;
        if (tc == BITCLK-1) begin tc <= 0; midi_tick <= 1'b1; end
        else                     tc <= tc + 1;
    end

    // arb 回给 parse 的握手（必须在 parse 例化之前声明）
    wire [3:0]  a_in_msg_ack, a_in_sx_ack;

    //------------------------------------------------------------- parse ×2
    wire        p1_msg_vld, p1_msg_drop, p1_msg_ovf, p1_frame_err;
    wire [7:0]  p1_status, p1_d0, p1_d1;
    wire [1:0]  p1_port;
    wire        p1_sysex_start, p1_sysex_vld, p1_sysex_err;
    wire [6:0]  p1_sysex_len;
    wire [7:0]  p1_sysex_byte;

    wire        p3_msg_vld, p3_msg_drop, p3_msg_ovf, p3_frame_err;
    wire [7:0]  p3_status, p3_d0, p3_d1;
    wire [1:0]  p3_port;
    wire        p3_sysex_start, p3_sysex_vld, p3_sysex_err;
    wire [6:0]  p3_sysex_len;
    wire [7:0]  p3_sysex_byte;

    midi_parse #(.PORT_ID(2'd1)) u_parse_inst (
        .clk(clk), .rst_n_sync(rst_n), .midi_tick(midi_tick), .rx(rx_inst),
        .msg_ack(a_in_msg_ack[0]), .sysex_ack(a_in_sx_ack[0]),
        .msg_vld(p1_msg_vld), .msg_status(p1_status), .msg_d0(p1_d0), .msg_d1(p1_d1),
        .msg_port(p1_port), .msg_drop(p1_msg_drop), .msg_ovf(p1_msg_ovf),
        .sysex_start(p1_sysex_start), .sysex_len(p1_sysex_len), .sysex_vld(p1_sysex_vld),
        .sysex_byte(p1_sysex_byte), .sysex_err(p1_sysex_err), .frame_err(p1_frame_err)
    );

    midi_parse #(.PORT_ID(2'd3)) u_parse_mix (
        .clk(clk), .rst_n_sync(rst_n), .midi_tick(midi_tick), .rx(rx_mix),
        .msg_ack(a_in_msg_ack[3]), .sysex_ack(a_in_sx_ack[3]),
        .msg_vld(p3_msg_vld), .msg_status(p3_status), .msg_d0(p3_d0), .msg_d1(p3_d1),
        .msg_port(p3_port), .msg_drop(p3_msg_drop), .msg_ovf(p3_msg_ovf),
        .sysex_start(p3_sysex_start), .sysex_len(p3_sysex_len), .sysex_vld(p3_sysex_vld),
        .sysex_byte(p3_sysex_byte), .sysex_err(p3_sysex_err), .frame_err(p3_frame_err)
    );

    //------------------------------------------------------------- arb
    // 注意拼接顺序：{a,b,c,d} 中 a 是**最高位（位 3）**。
    // parse#3（混音器）必须落在**位 3**，arb 输出的 port 才是 3、filter 才认它是混音器端口。
    wire [3:0]  in_msg_vld    = {p3_msg_vld, 1'b0, 1'b0, p1_msg_vld};
    wire [31:0] in_msg_status = {p3_status, 8'd0, 8'd0, p1_status};
    wire [31:0] in_msg_d0     = {p3_d0, 8'd0, 8'd0, p1_d0};
    wire [31:0] in_msg_d1     = {p3_d1, 8'd0, 8'd0, p1_d1};
    wire [3:0]  in_sx_start   = {p3_sysex_start, 1'b0, 1'b0, p1_sysex_start};
    wire [27:0] in_sx_len     = {p3_sysex_len, 7'd0, 7'd0, p1_sysex_len};
    wire [3:0]  in_sx_vld     = {p3_sysex_vld, 1'b0, 1'b0, p1_sysex_vld};
    wire [31:0] in_sx_byte    = {p3_sysex_byte, 8'd0, 8'd0, p1_sysex_byte};
    wire [3:0]  in_sx_err     = {p3_sysex_err, 1'b0, 1'b0, p1_sysex_err};

    wire        a_msg_vld, a_sx_start, a_sx_vld, a_sx_err;
    wire [7:0]  a_status, a_d0, a_d1, a_sx_byte;
    wire [1:0]  a_port;
    wire [6:0]  a_sx_len;
    wire        f_msg_ack;

    midi_arb u_arb (
        .clk(clk), .rst_n_sync(rst_n),
        .in_msg_vld(in_msg_vld), .in_msg_status(in_msg_status),
        .in_msg_d0(in_msg_d0), .in_msg_d1(in_msg_d1),
        .in_sysex_start(in_sx_start), .in_sysex_len(in_sx_len),
        .in_sysex_vld(in_sx_vld), .in_sysex_byte(in_sx_byte), .in_sysex_err(in_sx_err),
        .in_msg_ack(a_in_msg_ack), .in_sysex_ack(a_in_sx_ack),
        .out_msg_vld(a_msg_vld), .out_msg_status(a_status), .out_msg_d0(a_d0),
        .out_msg_d1(a_d1), .out_msg_port(a_port), .out_msg_ack(f_msg_ack),
        .out_sysex_start(a_sx_start), .out_sysex_len(a_sx_len), .out_sysex_vld(a_sx_vld),
        .out_sysex_byte(a_sx_byte), .out_sysex_err(a_sx_err), .out_sysex_ack(1'b0)
    );

    //------------------------------------------------------------- filter
    wire       ev_note, ev_note_on, ev_cc_wr, ev_pc, ev_par_wr, drop_vld;
    wire [3:0] ev_note_ch, ev_cc_ch, ev_pc_ch, ev_par_idx;
    wire [4:0] ev_cc_field;                       // 注意：field_id 是 5 位
    wire [6:0] ev_note_key, ev_note_vel, ev_pc_prog;
    wire [15:0] ev_cc_val, ev_par_data;
    wire [1:0] ev_par_grp;

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

    //------------------------------------------------------------- 捕获
    reg        cap_note, cap_note_on, cap_cc, cap_pc, cap_par, cap_drop;
    reg [3:0]  cap_note_ch, cap_cc_ch, cap_pc_ch, cap_par_idx;
    reg [4:0]  cap_cc_field;                      // field_id 是 5 位
    reg [6:0]  cap_note_key, cap_note_vel, cap_pc_prog;
    reg [15:0] cap_cc_val, cap_par_data;
    reg [1:0]  cap_par_grp;

    always @(posedge clk) begin
        if (ev_note)   begin cap_note  <= 1'b1; cap_note_on  <= ev_note_on;
                             cap_note_ch <= ev_note_ch; cap_note_key <= ev_note_key;
                             cap_note_vel <= ev_note_vel; end
        if (ev_cc_wr)  begin cap_cc    <= 1'b1; cap_cc_ch <= ev_cc_ch;
                             cap_cc_field <= ev_cc_field; cap_cc_val <= ev_cc_val; end
        if (ev_pc)     begin cap_pc    <= 1'b1; cap_pc_ch <= ev_pc_ch; cap_pc_prog <= ev_pc_prog; end
        if (ev_par_wr) begin cap_par   <= 1'b1; cap_par_grp <= ev_par_grp;
                             cap_par_idx <= ev_par_idx; cap_par_data <= ev_par_data; end
        if (drop_vld)  begin cap_drop  <= 1'b1; end
    end

    task clr_caps;
        begin
            // 必须在时钟边沿之后再清：cap_* 由 always 块用非阻塞赋值驱动，
            // 若在边沿同一时刻用阻塞赋值清零，会被本拍的 NBA 更新覆盖（残留上一轮的标志）。
            @(posedge clk);
            #1;
            cap_note=0; cap_note_on=0; cap_cc=0; cap_pc=0; cap_par=0; cap_drop=0;
            cap_note_ch=0; cap_note_key=0; cap_note_vel=0;
            cap_cc_ch=0; cap_cc_field=0; cap_cc_val=0;
            cap_pc_ch=0; cap_pc_prog=0; cap_par_grp=0; cap_par_idx=0; cap_par_data=0;
        end
    endtask

    integer errors = 0;

    task chk(input cond, input [255:0] name);
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("FAIL  %0s", name);
            end else begin
                $display("  ok  %0s", name);
            end
        end
    endtask

    //------------------------------------------------------------- 驱动
    task sbit_i(input v); begin rx_inst = v; repeat (BITCLK) @(posedge clk); end endtask
    task sbyte_i(input [7:0] b);
        integer i; begin
            sbit_i(0); for (i=0;i<8;i=i+1) sbit_i(b[i]); sbit_i(1);
        end
    endtask
    task sbit_m(input v); begin rx_mix = v; repeat (BITCLK) @(posedge clk); end endtask
    task sbyte_m(input [7:0] b);
        integer i; begin
            sbit_m(0); for (i=0;i<8;i=i+1) sbit_m(b[i]); sbit_m(1);
        end
    endtask

    integer i;
    initial begin
        $dumpfile("tb_midi_chain.vcd");
        $dumpvars(0, tb_midi_chain);

        repeat (10) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (5) @(posedge clk);

        //======================================================== ① Note
        $display("== 1. note on / note off ==");
        clr_caps;
        sbyte_i(8'h90); sbyte_i(8'h3C); sbyte_i(8'h64);
        repeat (50) @(posedge clk);
        chk(cap_note && cap_note_on && cap_note_key==7'h3C && cap_note_vel==7'h64 && cap_note_ch==4'h0,
            "note on ch0 key3C vel64");

        clr_caps;
        sbyte_i(8'h90); sbyte_i(8'h3D); sbyte_i(8'h00);      // 力度 0 的 Note On
        repeat (50) @(posedge clk);
        chk(cap_note && !cap_note_on && cap_note_key==7'h3D, "vel-0 note on -> note off");

        clr_caps;
        sbyte_i(8'h8A); sbyte_i(8'h3C); sbyte_i(8'h40);      // ch = 0xA = 10
        repeat (50) @(posedge clk);
        chk(cap_note && !cap_note_on && cap_note_ch==4'hA, "note off ch10 (0x8A)");

        //======================================================== ③④ CC 过滤
        $display("== 2. mix-CC filtering: instrument vs mixer port ==");
        clr_caps;
        sbyte_i(8'hB0); sbyte_i(8'h07); sbyte_i(8'h64);      // 乐器端口 CC7
        repeat (50) @(posedge clk);
        chk(cap_drop && !cap_cc, "instrument port CC7 dropped");

        clr_caps;
        sbyte_m(8'hB1); sbyte_m(8'h07); sbyte_m(8'h64);      // 混音器端口 CC7
        repeat (50) @(posedge clk);
        $display("    [dbg] cap_cc=%b cap_drop=%b field=%0d val=%0d ch=%0d",
                 cap_cc, cap_drop, cap_cc_field, cap_cc_val, cap_cc_ch);
        chk(cap_cc && !cap_drop && cap_cc_field==5'd0 && cap_cc_val==16'd100 && cap_cc_ch==4'h1,
            "mixer port CC7 -> volume(0) = 100");

        clr_caps;
        sbyte_i(8'hB2); sbyte_i(8'h5E); sbyte_i(8'h1E);      // 乐器端口 CC94
        repeat (50) @(posedge clk);
        chk(cap_drop && !cap_cc, "instrument port CC94 dropped");

        clr_caps;
        sbyte_m(8'hB3); sbyte_m(8'h5E); sbyte_m(8'h1E);      // 混音器端口 CC94（30）
        repeat (50) @(posedge clk);
        chk(cap_cc && cap_cc_field==5'd11 && cap_cc_val==16'd30, "mixer port CC94 -> send_delay(11) = 30");

        //======================================================== ⑤ 演奏类 CC
        $display("== 3. performance CC on instrument port ==");
        clr_caps;
        sbyte_i(8'hB0); sbyte_i(8'h0B); sbyte_i(8'h32);      // CC11 expression = 50
        repeat (50) @(posedge clk);
        chk(cap_cc && cap_cc_field==5'd2 && cap_cc_val==16'd50, "CC11 -> expression(2) = 50");

        clr_caps;
        sbyte_i(8'hB0); sbyte_i(8'h4A); sbyte_i(8'h7F);      // CC74 cutoff mod = 127
        repeat (50) @(posedge clk);
        chk(cap_cc && cap_cc_field==5'd8 && cap_cc_val==16'd127, "CC74 -> cutoff_mod(8) = 127");

        clr_caps;
        sbyte_i(8'hB0); sbyte_i(8'h40); sbyte_i(8'h7F);      // CC64 sustain = 127
        repeat (50) @(posedge clk);
        chk(cap_cc && cap_cc_field==5'd3 && cap_cc_val==16'd127, "CC64 -> sustain(3) = 127");

        //======================================================== ⑥ PC
        $display("== 4. program change ==");
        clr_caps;
        sbyte_i(8'hC5); sbyte_i(8'h07);
        repeat (50) @(posedge clk);
        chk(cap_pc && cap_pc_ch==4'h5 && cap_pc_prog==7'd7, "PC ch5 prog7");

        //======================================================== ⑦ Pitch Bend
        $display("== 5. pitch bend ==");
        clr_caps;
        sbyte_i(8'hE2); sbyte_i(8'h00); sbyte_i(8'h40);      // LSB=0, MSB=0x40 → 8192
        repeat (50) @(posedge clk);
        chk(cap_cc && cap_cc_field==5'd15 && cap_cc_val==16'd8192, "pitch bend center = 8192");

        clr_caps;
        sbyte_i(8'hE2); sbyte_i(8'h01); sbyte_i(8'h40);      // 0x40*128 + 1 = 8193
        repeat (50) @(posedge clk);
        chk(cap_cc && cap_cc_field==5'd15 && cap_cc_val==16'd8193, "pitch bend 8193 (LSB first)");

        //======================================================== ⑧ RPN
        $display("== 6. RPN 0,0 -> bend range ==");
        clr_caps;
        sbyte_i(8'hB0); sbyte_i(8'h65); sbyte_i(8'h00);      // CC101 = 0 (RPN MSB)
        sbyte_i(8'hB0); sbyte_i(8'h64); sbyte_i(8'h00);      // CC100 = 0 (RPN LSB)
        sbyte_i(8'hB0); sbyte_i(8'h06); sbyte_i(8'h0C);      // CC6   = 12
        repeat (80) @(posedge clk);
        chk(cap_cc && cap_cc_field==5'd16 && cap_cc_val==16'd12, "RPN 0,0 data 12 -> bend_range(16) = 12");

        //======================================================== ⑨⑩ SysEx
        $display("== 7. sysex (mixer port) ==");
        clr_caps;
        sbyte_m(8'hF0); sbyte_m(8'h7D); sbyte_m(8'h01); sbyte_m(8'h02);
        sbyte_m(8'h12); sbyte_m(8'h34); sbyte_m(8'hF7);
        repeat (80) @(posedge clk);
        chk(cap_par && cap_par_grp==2'd1 && cap_par_idx==4'd2 && cap_par_data==16'h0934,
            "effect sysex -> grp1 idx2 data 0x0934");

        clr_caps;
        sbyte_m(8'hF0); sbyte_m(8'h7F); sbyte_m(8'h7F); sbyte_m(8'h04);
        sbyte_m(8'h01); sbyte_m(8'h00); sbyte_m(8'h40); sbyte_m(8'hF7);
        repeat (80) @(posedge clk);
        chk(cap_par && cap_par_grp==2'd3 && cap_par_idx==4'd0 && cap_par_data==16'h2000,
            "master volume sysex -> grp3 idx0 data 0x2000 (50%)");

        if (errors == 0) $display("PASS  tb_midi_chain");
        else             $display("FAIL  tb_midi_chain : %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
