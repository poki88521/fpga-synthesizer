//============================================================================
//  tb_chan_table —— 通道状态表单元测试
//
//  覆盖（对应 documents/硬件实现.md §三.四）：
//    ① 复位后配置项载入默认值（default_timbre / max_voices），运行参数归零
//    ② CC → 待写 FIFO → frame_stb 提交 → 读口看到新值
//    ③ 双缓冲：提交前读口仍是旧值，提交后才是新值（不会"半新半旧"）
//    ④ 派生字段 pan_gL / pan_gR（等功率表 + pan[0] 插值）
//    ⑤ 派生字段 bend_ratio（Q2.14，中心 16384 = 1.0）
//    ⑥ note_count 走分配器口，立即生效（不经 FIFO）
//    ⑦ FIFO 溢出：丢弃最旧并置 wr_ovf
//    ⑧ P 个并行读口：不同通道给出各自的参数
//
//  驱动规范（照 tb_midi_arb 的教训）：输入一律在 negedge 更新。
//  运行前需把 pan_gl.hex / pan_gr.hex / bend_exp.hex 放在仿真工作目录下。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_chan_table;
    parameter P = 8;

    reg clk = 0;
    always #10 clk = ~clk;                 // 50 MHz，本模块与位定时无关

    reg rst_n = 0;
    reg frame_stb = 0;

    reg        ev_cc_wr = 0;
    reg [3:0]  ev_cc_ch = 0;
    reg [4:0]  ev_cc_field = 0;
    reg [15:0] ev_cc_val = 0;
    reg        ev_pc = 0;
    reg [3:0]  ev_pc_ch = 0;
    reg [6:0]  ev_pc_prog = 0;

    reg        alloc_wr = 0;
    reg [3:0]  alloc_ch = 0;
    reg [5:0]  alloc_nc = 0;

    reg        cfg_wr = 0;
    reg [3:0]  cfg_ch = 0;
    reg [7:0]  cfg_default_timbre = 0;
    reg [5:0]  cfg_max_voices = 0;

    reg [3:0]  rd_ch = 0;
    reg [P*4-1:0] prd_ch = 0;

    wire [6:0]  rd_volume, rd_pan, rd_expression, rd_program;
    wire [15:0] rd_pan_gL, rd_pan_gR, rd_bend_ratio;
    wire [13:0] rd_bend_value;
    wire [6:0]  rd_bend_range, rd_bank_msb, rd_bank_lsb;
    wire [7:0]  rd_default_timbre;
    wire [5:0]  rd_max_voices, rd_note_count;
    wire        rd_sustain_pedal, rd_sostenuto_pedal;
    wire [6:0]  rd_attack_mod, rd_release_mod, rd_resonance_mod, rd_cutoff_mod;
    wire [6:0]  rd_send_reverb, rd_send_chorus, rd_send_delay;

    wire [P*16-1:0] prd_pan_gL, prd_pan_gR;
    wire [P*7-1:0]  prd_volume, prd_expression, prd_send_reverb, prd_send_chorus, prd_send_delay;
    wire [P-1:0]    prd_sust_pedal;

    wire wr_ovf, dumping, fifo_empty;

    chan_table #(
        .P(P),
        .DEF_MAX_VOICES    (6'd8),
        .DEF_DEFAULT_TIMBRE(8'd3)
    ) dut (
        .clk(clk), .rst_n_sync(rst_n), .frame_stb(frame_stb),
        .ev_cc_wr(ev_cc_wr), .ev_cc_ch(ev_cc_ch), .ev_cc_field(ev_cc_field), .ev_cc_val(ev_cc_val),
        .ev_pc(ev_pc), .ev_pc_ch(ev_pc_ch), .ev_pc_prog(ev_pc_prog),
        .alloc_wr(alloc_wr), .alloc_ch(alloc_ch), .alloc_nc(alloc_nc),
        .cfg_wr(cfg_wr), .cfg_ch(cfg_ch),
        .cfg_default_timbre(cfg_default_timbre), .cfg_max_voices(cfg_max_voices),
        .rd_ch(rd_ch),
        .rd_volume(rd_volume), .rd_pan(rd_pan), .rd_pan_gL(rd_pan_gL), .rd_pan_gR(rd_pan_gR),
        .rd_expression(rd_expression), .rd_bend_ratio(rd_bend_ratio),
        .rd_bend_value(rd_bend_value), .rd_bend_range(rd_bend_range),
        .rd_program(rd_program), .rd_bank_msb(rd_bank_msb), .rd_bank_lsb(rd_bank_lsb),
        .rd_default_timbre(rd_default_timbre), .rd_max_voices(rd_max_voices),
        .rd_note_count(rd_note_count),
        .rd_sustain_pedal(rd_sustain_pedal), .rd_sostenuto_pedal(rd_sostenuto_pedal),
        .rd_attack_mod(rd_attack_mod), .rd_release_mod(rd_release_mod),
        .rd_resonance_mod(rd_resonance_mod), .rd_cutoff_mod(rd_cutoff_mod),
        .rd_send_reverb(rd_send_reverb), .rd_send_chorus(rd_send_chorus), .rd_send_delay(rd_send_delay),
        .prd_ch(prd_ch),
        .prd_pan_gL(prd_pan_gL), .prd_pan_gR(prd_pan_gR),
        .prd_volume(prd_volume), .prd_expression(prd_expression),
        .prd_send_reverb(prd_send_reverb), .prd_send_chorus(prd_send_chorus),
        .prd_send_delay(prd_send_delay), .prd_sust_pedal(prd_sust_pedal),
        .wr_ovf(wr_ovf), .dumping(dumping), .fifo_empty(fifo_empty)
    );

    integer errors = 0;
    integer i;

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

    task cc(input [3:0] ch, input [4:0] fld, input [15:0] val);
        begin
            @(negedge clk);
            ev_cc_wr = 1'b1; ev_cc_ch = ch; ev_cc_field = fld; ev_cc_val = val;
            @(negedge clk);
            ev_cc_wr = 1'b0;
            @(negedge clk);        // 必须留一拍，保证 ev_cc_wr 是"单拍脉冲"（接口约定）
        end
    endtask

    // 产生一次 frame_stb 并等提交完成（复制 1 拍 + 应用 ≤4 拍，10 拍足够）
    task do_frame;
        begin
            @(negedge clk); frame_stb = 1'b1;
            @(negedge clk); frame_stb = 1'b0;
            repeat (10) @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("tb_chan_table.vcd");
        $dumpvars(0, tb_chan_table);

        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (5) @(posedge clk);

        //======================================================== ① 复位默认值
        $display("== 1. reset defaults ==");
        rd_ch = 4'd5;
        #10;
        chk(rd_default_timbre == 8'd3, "default_timbre = 3 (ch5)");
        chk(rd_max_voices     == 6'd8, "max_voices = 8 (ch5)");
        chk(rd_volume         == 7'd0, "volume = 0");
        chk(rd_pan            == 7'd0, "pan = 0");
        chk(rd_note_count     == 6'd0, "note_count = 0");
        chk(rd_bend_ratio     == 16'd0, "bend_ratio = 0 (未设过弯音)");

        //======================================================== ②③ 提交 + 双缓冲
        $display("== 2. CC write -> submit -> visible ==");
        rd_ch = 4'd2;
        #10;
        cc(4'd2, 5'd0, 16'd100);                 // volume = 100
        cc(4'd2, 5'd2, 16'd64);                  // expression = 64
        #10;
        chk(rd_volume == 7'd0,   "before submit: volume still old (0)");
        do_frame;
        #10;
        chk(rd_volume     == 7'd100, "after submit: volume = 100");
        chk(rd_expression == 7'd64,  "after submit: expression = 64");
        chk(fifo_empty, "fifo empty after submit");

        //======================================================== ④ pan 派生
        $display("== 3. pan -> pan_gL/pan_gR (equal power) ==");
        rd_ch = 4'd3;
        cc(4'd3, 5'd1, 16'd64);                  // pan = 64（居中）
        do_frame;
        #10;
        chk(rd_pan_gL == 16'h5a82 && rd_pan_gR == 16'h5a82, "pan=64 -> gL=gR=0x5a82");
        $display("       got gL=%04x gR=%04x", rd_pan_gL, rd_pan_gR);

        cc(4'd3, 5'd1, 16'd0);                   // pan = 0（最左）
        do_frame;
        #10;
        chk(rd_pan_gL == 16'h7fff && rd_pan_gR == 16'h0000, "pan=0 -> gL=7fff gR=0");
        $display("       got gL=%04x gR=%04x", rd_pan_gL, rd_pan_gR);

        cc(4'd3, 5'd1, 16'd127);                 // pan = 127（最右，插值）
        do_frame;
        #10;
        chk(rd_pan_gL < 16'd1000 && rd_pan_gR > 16'd32000, "pan=127 -> gL~0 gR~max");
        $display("       got gL=%04x gR=%04x", rd_pan_gL, rd_pan_gR);

        //======================================================== ⑤ bend_ratio
        $display("== 4. bend_value/bend_range -> bend_ratio (Q2.14) ==");
        rd_ch = 4'd4;
        cc(4'd4, 5'd16, 16'd2);                  // bend_range = 2 半音
        do_frame;
        cc(4'd4, 5'd15, 16'd8192);               // bend_value = 中心
        do_frame;
        #10;
        chk(rd_bend_ratio == 16'd16384, "center bend -> ratio = 16384 (1.0)");
        $display("       got ratio=%0d", rd_bend_ratio);

        cc(4'd4, 5'd15, 16'd16383);              // bend_value = 最大
        do_frame;
        #10;
        // Δsemi = (16383-8192)/8192*2 = 1.9998 半音 → 2^(1.9998/12) = 1.12228 → ×16384 = 18387
        chk(rd_bend_ratio > 16'd18000 && rd_bend_ratio < 16'd18800, "+2 semi -> ratio ~18387");
        $display("       got ratio=%0d", rd_bend_ratio);

        cc(4'd4, 5'd15, 16'd1);                  // bend_value = 最小
        do_frame;
        #10;
        // Δsemi ≈ -2 半音 → 2^(-2/12) = 0.89090 → ×16384 = 14597
        chk(rd_bend_ratio > 16'd14200 && rd_bend_ratio < 16'd15000, "-2 semi -> ratio ~14597");
        $display("       got ratio=%0d", rd_bend_ratio);

        //======================================================== ⑥ note_count 立即生效
        $display("== 5. note_count via alloc port (immediate) ==");
        rd_ch = 4'd7;
        @(negedge clk);
        alloc_wr = 1'b1; alloc_ch = 4'd7; alloc_nc = 6'd5;
        @(negedge clk);
        alloc_wr = 1'b0;
        #10;
        chk(rd_note_count == 6'd5, "note_count = 5 immediately (no fifo)");

        //======================================================== ⑦ FIFO 溢出
        $display("== 6. fifo overflow (> depth 4) ==");
        rd_ch = 4'd9;
        // 连发 6 条（深度 4）→ 应有溢出，且最终只提交最后 4 条中最新的值
        cc(4'd9, 5'd0, 16'd10);
        cc(4'd9, 5'd0, 16'd20);
        cc(4'd9, 5'd0, 16'd30);
        cc(4'd9, 5'd0, 16'd40);
        cc(4'd9, 5'd0, 16'd50);
        cc(4'd9, 5'd0, 16'd60);
        do_frame;
        #10;
        chk(wr_ovf == 1'b1, "wr_ovf asserted on overflow");
        chk(rd_volume == 7'd60, "last write wins: volume = 60");
        $display("       got volume=%0d", rd_volume);

        //======================================================== ⑧ P 并行读口
        $display("== 7. P parallel read ports ==");
        // ch0 volume=11, ch1 volume=22
        cc(4'd0, 5'd0, 16'd11);
        cc(4'd1, 5'd0, 16'd22);
        do_frame;
        prd_ch[0*4 +: 4] = 4'd0;
        prd_ch[1*4 +: 4] = 4'd1;
        prd_ch[2*4 +: 4] = 4'd2;
        #10;
        chk(prd_volume[0*7 +: 7] == 7'd11, "prd[0].volume = 11");
        chk(prd_volume[1*7 +: 7] == 7'd22, "prd[1].volume = 22");
        chk(prd_volume[2*7 +: 7] == 7'd100, "prd[2].volume = 100 (前面写的)");

        //======================================================== 收尾
        if (errors == 0) $display("PASS  tb_chan_table");
        else             $display("FAIL  tb_chan_table : %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
