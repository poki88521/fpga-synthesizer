//============================================================================
//  tb_voice_alloc —— 声部分配器单元测试
//
//  覆盖（documents/硬件实现.md §三.六）：
//    ① 空闲分配：连续 Note On 依次拿编号最小的空闲声部
//    ② 重触发（优先①）：同通道 + 同 note + gate=1 → 复用同一声部
//    ③ Note Off：只写 gate = 0，并产生 op=1(释放) 事件
//    ④ 抢断（优先③）：无空闲、且同通道已有该 note 时，抢断本通道最老的声部
//    ⑤ note_count 写回通道表
//    ⑥ CC123：该通道全部声部 gate → 0
//
//  TB 侧模拟 voice_fetch 的扫描口：收到 scan_req 后**打一拍**返回 env_state。
//  驱动规范：输入一律在 negedge 更新。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_voice_alloc;
    parameter N = 8;                       // 小配置便于填满
    parameter SW = 3;                      // log2(N)

    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_n = 0;
    reg frame_stb = 0;

    reg        ev_note = 0;
    reg        ev_note_on = 0;
    reg [3:0]  ev_note_ch = 0;
    reg [6:0]  ev_note_key = 0;
    reg [6:0]  ev_note_vel = 0;
    reg [1:0]  cc_action = 0;
    reg [3:0]  cc_ch = 0;

    wire [3:0] ch_rd_addr;
    reg  [5:0] ch_max_voices = 6'd8;
    wire       nc_wr;
    wire [3:0] nc_ch;
    wire [5:0] nc_val;
    wire [4:0] scan_addr;
    wire       scan_req;
    reg  [2:0] scan_env_state;
    wire       awr;
    wire [4:0] awr_id;
    wire [6:0] awr_note, awr_vel;
    wire [3:0] awr_ch;
    wire [2:0] awr_timbre;
    wire       awr_gate;
    wire [15:0] awr_vel_gain;
    wire [7:0] awr_age;
    wire       awr_fast_rel;
    wire [6:0] evt_dout;
    wire       evt_empty, evt_full;
    reg        evt_rd = 0;

    voice_alloc #(.P(2), .G(4), .N(N), .NCH(16)) dut (
        .clk(clk), .rst_n_sync(rst_n), .frame_stb(frame_stb),
        .ev_note(ev_note), .ev_note_on(ev_note_on), .ev_note_ch(ev_note_ch),
        .ev_note_key(ev_note_key), .ev_note_vel(ev_note_vel),
        .cc_action(cc_action), .cc_ch(cc_ch),
        .ch_rd_addr(ch_rd_addr), .ch_max_voices(ch_max_voices),
        .nc_wr(nc_wr), .nc_ch(nc_ch), .nc_val(nc_val),
        .scan_addr(scan_addr), .scan_req(scan_req), .scan_env_state(scan_env_state),
        .awr(awr), .awr_id(awr_id), .awr_note(awr_note), .awr_vel(awr_vel),
        .awr_ch(awr_ch), .awr_timbre(awr_timbre), .awr_gate(awr_gate),
        .awr_vel_gain(awr_vel_gain), .awr_age(awr_age), .awr_fast_rel(awr_fast_rel),
        .evt_dout(evt_dout), .evt_empty(evt_empty), .evt_full(evt_full), .evt_rd(evt_rd)
    );

    //--------------------------------------------- 模拟 voice_fetch 扫描返回
    reg [2:0] estbl [0:N-1];               // 每个声部的 env_state（0 = IDLE）
    always @(posedge clk) begin
        if (scan_req) scan_env_state <= estbl[scan_addr[SW-1:0]];
        else          scan_env_state <= 3'd0;
    end

    //--------------------------------------------- 监视器（单拍脉冲必须捕获）
    reg        cap_awr = 0;
    reg [4:0]  cap_id = 0;
    reg [6:0]  cap_note = 0, cap_vel = 0;
    reg [3:0]  cap_ch = 0;
    reg        cap_gate = 0, cap_fast = 0, cap_nc = 0;
    reg [5:0]  cap_ncval = 0;
    reg [6:0]  cap_evt = 0;
    reg        cap_evt_v = 0;

    always @(posedge clk) begin
        if (awr) begin
            cap_awr  <= 1'b1;
            cap_id   <= awr_id;
            cap_note <= awr_note;
            cap_vel  <= awr_vel;
            cap_ch   <= awr_ch;
            cap_gate <= awr_gate;
            cap_fast <= awr_fast_rel;
        end
        if (nc_wr) begin
            cap_nc    <= 1'b1;
            cap_ncval <= nc_val;
        end
        // 事件 FIFO 非空时抓第一条（随后读走）
        if (!evt_empty && !cap_evt_v) begin
            cap_evt   <= evt_dout;
            cap_evt_v <= 1'b1;
        end
    end

    integer errors = 0;

    task chk(input cond, input [255:0] name);
        begin
            if (!cond) begin errors = errors + 1; $display("FAIL  %0s", name); end
            else $display("  ok  %0s", name);
        end
    endtask

    task clr_caps;
        begin
            cap_awr=0; cap_nc=0; cap_evt_v=0; cap_id=0; cap_note=0; cap_gate=0; cap_fast=0;
        end
    endtask

    task note_on(input [3:0] ch, input [6:0] key, input [6:0] vel);
        begin
            @(negedge clk);
            ev_note=1; ev_note_on=1; ev_note_ch=ch; ev_note_key=key; ev_note_vel=vel;
            @(negedge clk);
            ev_note=0;
            repeat (90) @(posedge clk);        // 扫描 32×2 拍 + 收尾
        end
    endtask

    task note_off(input [3:0] ch, input [6:0] key);
        begin
            @(negedge clk);
            ev_note=1; ev_note_on=0; ev_note_ch=ch; ev_note_key=key; ev_note_vel=0;
            @(negedge clk);
            ev_note=0;
            repeat (90) @(posedge clk);
        end
    endtask

    // 把事件 FIFO 读空
    task drain_evt;
        integer g;
        begin
            g = 0;
            while (!evt_empty && g < 20) begin
                @(negedge clk); evt_rd = 1'b1;
                @(negedge clk); evt_rd = 1'b0;
                g = g + 1;
            end
        end
    endtask

    integer i;
    initial begin
        $dumpfile("tb_voice_alloc.vcd");
        $dumpvars(0, tb_voice_alloc);

        for (i = 0; i < N; i = i + 1) estbl[i] = 3'd0;   // 全部 IDLE

        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (5) @(posedge clk);
        drain_evt;

        //================================================== ① 空闲分配
        $display("== 1. allocate idle voices in ascending order ==");
        clr_caps;
        note_on(4'd0, 7'd60, 7'd100);
        chk(cap_awr && cap_id == 5'd0 && cap_note == 7'd60 && cap_gate == 1'b1,
            "first note on -> voice 0 (idle, lowest)");
        $display("       id=%0d note=%0d gate=%b fast=%b", cap_id, cap_note, cap_gate, cap_fast);
        chk(cap_evt_v && cap_evt[1:0] == 2'd0, "event op = 0 (alloc)");
        drain_evt;

        clr_caps;
        note_on(4'd0, 7'd62, 7'd100);
        chk(cap_awr && cap_id == 5'd1 && cap_note == 7'd62,
            "second note on -> voice 1");
        drain_evt;

        //================================================== ② 重触发
        $display("== 2. retrigger: same ch + same note ==");
        clr_caps;
        note_on(4'd0, 7'd60, 7'd80);
        chk(cap_awr && cap_id == 5'd0 && cap_vel == 7'd80 && cap_gate == 1'b1,
            "same note -> reuses voice 0 with new velocity");
        $display("       id=%0d vel=%0d", cap_id, cap_vel);
        drain_evt;

        //================================================== ③ Note Off
        $display("== 3. note off -> gate = 0, op = 1 (release) ==");
        clr_caps;
        note_off(4'd0, 7'd62);
        chk(cap_awr && cap_id == 5'd1 && cap_gate == 1'b0, "note off -> voice 1 gate=0");
        $display("       [evt] v=%b dout=%07b id=%0d op=%0d  fifo_empty=%b",
                 cap_evt_v, cap_evt, cap_evt[6:2], cap_evt[1:0], evt_empty);
        chk(cap_evt_v && cap_evt[1:0] == 2'd1, "event op = 1 (release)");
        drain_evt;

        //================================================== ⑤ note_count
        $display("== 4. note_count written back ==");
        chk(cap_nc == 1'b1, "nc_wr asserted");
        $display("       nc_ch=%0d nc_val=%0d", nc_ch, cap_ncval);

        //================================================== ④ 抢断
        $display("== 5. steal oldest in same channel ==");
        // 先把 8 个声部占满（全部 ch0），且让 env_state 全部非 IDLE
        clr_caps;
        for (i = 0; i < N; i = i + 1) begin
            estbl[i] = 3'd1;               // 非 IDLE -> 空闲判定不再成立
        end
        // 依次用 8 个不同 note 占满（此时前两个已占用，会复用/抢断）
        // 为使状态确定，直接按 note 61..67 分配
        clr_caps;
        note_on(4'd0, 7'd61, 7'd100);      // 会复用 voice1（已 gate=0）
        drain_evt;
        clr_caps;
        note_on(4'd0, 7'd63, 7'd100);
        drain_evt;
        clr_caps;
        note_on(4'd0, 7'd64, 7'd100);
        drain_evt;
        clr_caps;
        note_on(4'd0, 7'd65, 7'd100);
        drain_evt;
        clr_caps;
        note_on(4'd0, 7'd66, 7'd100);
        drain_evt;
        clr_caps;
        note_on(4'd0, 7'd67, 7'd100);
        drain_evt;
        clr_caps;
        note_on(4'd0, 7'd68, 7'd100);
        drain_evt;
        // 现在 8 个声部都应被占用（ch0），再发新 note 必须抢断
        clr_caps;
        note_on(4'd0, 7'd70, 7'd100);
        chk(cap_awr && cap_gate == 1'b1 && cap_fast == 1'b1,
            "no idle -> steal (fast release flag set)");
        $display("       steal id=%0d note=%0d fast=%b", cap_id, cap_note, cap_fast);
        $display("       [evt] v=%b dout=%07b id=%0d op=%0d  fifo_empty=%b",
                 cap_evt_v, cap_evt, cap_evt[6:2], cap_evt[1:0], evt_empty);
        chk(cap_evt_v && cap_evt[1:0] == 2'd2, "event op = 2 (steal)");
        drain_evt;

        //================================================== ⑥ CC123
        $display("== 6. CC123 all notes off ==");
        clr_caps;
        @(negedge clk);
        cc_action = 2'd2; cc_ch = 4'd0;
        @(negedge clk);
        cc_action = 2'd0;
        repeat (200) @(posedge clk);
        chk(cap_awr && cap_gate == 1'b0 && cap_fast == 1'b0,
            "CC123 -> gate=0 with normal release (fast=0)");
        drain_evt;

        if (errors == 0) $display("PASS  tb_voice_alloc");
        else             $display("FAIL  tb_voice_alloc : %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
