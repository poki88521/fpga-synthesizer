//============================================================================
//  tb_voice_fetch —— 声部取数器单元测试
//
//  覆盖（documents/硬件实现.md §三.八 / §三.九）：
//    ① 分配写请求：voice_alloc 的 awr_* 先进队列，**frame_stb 之后**才写进表
//    ② 预取：slot_vld 之后 pf_* 更新为"下一时隙"的参数字段
//    ③ 运行状态回写：rs_wr/rs_id/rs_data → 写回缓冲 → frame_stb 落盘
//    ④ 扫描口：scan_req 后打一拍返回该声部的 env_state
//    ⑤ 分配类字段与运行状态字段互不覆盖（同一帧都提交时地址不重叠）
//
//  驱动规范：输入一律在 negedge 更新。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_voice_fetch;
    parameter P = 8, G = 4, N = 32;

    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_n = 0;
    reg frame_stb = 0;
    reg [1:0] slot = 0;
    reg       slot_vld = 0;

    reg        awr = 0;
    reg [4:0]  awr_id = 0;
    reg [6:0]  awr_note = 0, awr_vel = 0;
    reg [3:0]  awr_ch = 0;
    reg [2:0]  awr_timbre = 0;
    reg        awr_gate = 0;
    reg [15:0] awr_vel_gain = 0;
    reg [7:0]  awr_age = 0;
    reg        awr_fast_rel = 0;
    wire       awr_ready;

    reg         rs_wr = 0;
    reg [4:0]   rs_id = 0;
    reg [138:0] rs_data = 0;

    reg  [4:0]  scan_addr = 0;
    reg         scan_req = 0;
    wire [2:0]  scan_env_state;
    reg  [15:0] ch_sust_pedal = 0;      // 16 个通道的延音踏板状态

    wire [P*32-1:0] pf_phase_inc;
    wire [P*3-1:0]  pf_timbre;
    wire [P*7-1:0]  pf_note;
    wire [P*16-1:0] pf_vel_gain, pf_vca_gain;
    wire [P*4-1:0]  pf_ch;
    wire [P-1:0]    pf_gate, pf_fast_rel, pf_sust_pedal;
    wire            pf_vld;

    voice_fetch #(.P(P), .G(G), .N(N)) dut (
        .clk(clk), .rst_n_sync(rst_n), .frame_stb(frame_stb),
        .slot(slot), .slot_vld(slot_vld),
        .awr(awr), .awr_id(awr_id), .awr_note(awr_note), .awr_vel(awr_vel),
        .awr_ch(awr_ch), .awr_timbre(awr_timbre), .awr_gate(awr_gate),
        .awr_vel_gain(awr_vel_gain), .awr_age(awr_age), .awr_fast_rel(awr_fast_rel),
        .awr_ready(awr_ready),
        .rs_wr(rs_wr), .rs_id(rs_id), .rs_data(rs_data),
        .scan_addr(scan_addr), .scan_req(scan_req), .scan_env_state(scan_env_state),
        .ch_sust_pedal(ch_sust_pedal),
        .pf_phase_inc(pf_phase_inc), .pf_timbre(pf_timbre), .pf_note(pf_note),
        .pf_vel_gain(pf_vel_gain), .pf_vca_gain(pf_vca_gain), .pf_ch(pf_ch),
        .pf_gate(pf_gate), .pf_fast_rel(pf_fast_rel),
        .pf_sust_pedal(pf_sust_pedal), .pf_vld(pf_vld)
    );

    integer errors = 0;

    task chk(input cond, input [255:0] name);
        begin
            if (!cond) begin errors = errors + 1; $display("FAIL  %0s", name); end
            else $display("  ok  %0s", name);
        end
    endtask

    // 发一次分配写请求
    task send_awr(input [4:0] id, input [6:0] note, input [6:0] vel,
                  input [3:0] ch, input [2:0] timb, input g, input [15:0] vg);
        begin
            @(negedge clk);
            awr=1; awr_id=id; awr_note=note; awr_vel=vel; awr_ch=ch;
            awr_timbre=timb; awr_gate=g; awr_vel_gain=vg; awr_age=8'd7; awr_fast_rel=0;
            @(negedge clk);
            awr=0;
        end
    endtask

    // 产生一次 frame_stb 并等提交 FSM 跑完（WB 32 拍 + AW 32 拍）
    task do_frame;
        begin
            @(negedge clk); frame_stb = 1'b1;
            @(negedge clk); frame_stb = 1'b0;
            repeat (80) @(posedge clk);
        end
    endtask

    // 扫描读某声部的 env_state
    task scan_chk(input [4:0] id, input [2:0] exp, input [255:0] name);
        begin
            @(negedge clk);
            scan_addr = id; scan_req = 1'b1;
            @(negedge clk);
            scan_req = 1'b0;
            @(posedge clk);
            #1;
            chk(scan_env_state === exp, name);
            $display("       id=%0d env_state=%0d (exp %0d)", id, scan_env_state, exp);
        end
    endtask

    // 触发一次预取（时隙 g），读回 pf_* 的指定泳道
    task do_prefetch(input [1:0] g);
        begin
            @(negedge clk);
            slot = g; slot_vld = 1'b1;
            @(negedge clk);
            slot_vld = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        $dumpfile("tb_voice_fetch.vcd");
        $dumpvars(0, tb_voice_fetch);

        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (5) @(posedge clk);

        //================================================== ④ 扫描口初始
        $display("== 1. scan port (initial all zero) ==");
        scan_chk(5'd0, 3'd0, "voice 0 env_state = 0 (IDLE)");

        //================================================== ① 分配写请求
        $display("== 2. alloc write is deferred to frame boundary ==");
        // 写声部 5（时隙 1、泳道 5）: note=60, gate=1, timbre=3, vel_gain=0x2100
        // voice_id = {slot, lane}，所以 id=5 表示 slot0 / 泳道5。
        // 要观察它必须预取 slot0 —— 让 slot 走 3（3+1 回绕到 0）。
        send_awr(5'd5, 7'd60, 7'd100, 4'd2, 3'd3, 1'b1, 16'h2100);
        do_prefetch(2'd3);      // 读 slot0
        chk(pf_gate[5] === 1'b0, "before frame_stb: gate not yet visible");
        do_frame;
        do_prefetch(2'd3);      // 再读 slot0
        chk(pf_gate[5] === 1'b1, "after frame_stb: gate = 1");
        chk(pf_note[5*7 +: 7] === 7'd60, "after frame_stb: note = 60");
        $display("       note=%0d timbre=%0d vel_gain=%04x",
                 pf_note[5*7 +: 7], pf_timbre[5*3 +: 3], pf_vel_gain[5*16 +: 16]);
        chk(pf_timbre[5*3 +: 3] === 3'd3, "after frame_stb: timbre = 3");
        chk(pf_vel_gain[5*16 +: 16] === 16'h2100, "after frame_stb: vel_gain = 0x2100");

        //================================================== ③ 写回缓冲
        $display("== 3. runtime state write-back at frame boundary ==");
        // 给声部 5 回写 env_state = 3（RELEASE）、env_value = 0x1234
        @(negedge clk);
        rs_wr=1; rs_id=5'd5;
        rs_data = 139'd0;
        rs_data[50:48] = 3'd3;             // env_state
        rs_data[47:32] = 16'h1234;         // env_value
        @(negedge clk);
        rs_wr = 0;
        scan_chk(5'd5, 3'd0, "before frame_stb: env_state still 0");
        do_frame;
        scan_chk(5'd5, 3'd3, "after frame_stb: env_state = 3 (from write-back)");

        //================================================== ⑤ 字段不互相覆盖
        $display("== 4. alloc fields survive a write-back commit ==");
        do_prefetch(2'd3);
        chk(pf_note[5*7 +: 7] === 7'd60, "note still 60 after write-back commit");
        chk(pf_gate[5] === 1'b1, "gate still 1 after write-back commit");

        //================================================== ② 预取下一时隙
        $display("== 5. prefetch reads slot+1 ==");
        // 声部 0 属于 slot0；在 slot 3 预取时应读到 slot0（回绕）
        send_awr(5'd0, 7'd72, 7'd64, 4'd1, 3'd2, 1'b1, 16'h0040);
        do_frame;
        do_prefetch(2'd3);                 // slot3 -> 预取 slot0
        chk(pf_note[0*7 +: 7] === 7'd72, "slot3 prefetch reads slot0 (wrap) note=72");
        $display("       note=%0d", pf_note[0*7 +: 7]);

        //================================================== ⑥ sustain_pedal 通路
        $display("== 6. sustain_pedal carried from channel table ==");
        // 测试 5 里声部 0 被写成 ch=1，所以它会取 ch_sust_pedal[1]
        ch_sust_pedal = 16'd0;
        ch_sust_pedal[1] = 1'b1;
        do_prefetch(2'd3);                       // slot3 -> 预取 slot0
        $display("       voice0.ch=%0d pf_sust_pedal[0]=%b (ch_sust_pedal[1]=1)",
                 pf_ch[0*4 +: 4], pf_sust_pedal[0]);
        chk(pf_sust_pedal[0] === 1'b1, "voice0 (ch1) picks up sustain_pedal");
        ch_sust_pedal = 16'd0;
        do_prefetch(2'd3);
        chk(pf_sust_pedal[0] === 1'b0, "sustain_pedal 跟着通道表清掉");

        if (errors == 0) $display("PASS  tb_voice_fetch");
        else             $display("FAIL  tb_voice_fetch : %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
