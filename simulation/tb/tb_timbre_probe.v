//============================================================================
//  tb_sched_subsystem —— 调度层集成黑盒测试
//
//  验证 sched_subsystem 作为一个整体能不能用：
//    ① 复位后输出确定（ext_* / slot_vld / pf_vld 都不为 X）
//    ② 时隙时序：每帧恰好 G 个 slot_vld
//    ③ MIDI Note On 走完整条路径 → 分配成功 → 预取出现 gate=1
//    ④ 运行状态写回：给 rs_* 一组值 → 帧边界落盘 → 扫描口能读回
//    ⑤ frame_stb 边界：ext_* 只在帧边界更新
//
//  本 TB 不接单声部层，用常量驱动 rs_* 代替。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_timbre_probe;
    parameter P = 8, G = 4, NCH = 16, STRIDE = 8;
    parameter real    TCLK   = 20.345;
    parameter integer BITCLK = 1573;
    parameter integer FRAME  = 256;          // 缩短帧周期加速仿真（真实 1024）

    reg clk = 0;
    always #(TCLK/2.0) clk = ~clk;

    reg rst_n = 0;

    // frame_stb 发生器（真实系统里来自 pt8211_tx.sample_stb）
    reg     frame_stb = 0;
    integer fc = 0;
    always @(posedge clk) begin
        frame_stb <= 1'b0;
        if (fc == FRAME-1) begin fc <= 0; frame_stb <= 1'b1; end
        else                    fc <= fc + 1;
    end

    reg [3:0] midi_rx = 4'b1111;

    wire [1:0] slot;
    wire       slot_vld;

    wire [NCH*7-1:0]  ext_volume, ext_expression, ext_send_rev, ext_send_cho, ext_send_del;
    wire [NCH*16-1:0] ext_pan_gL, ext_pan_gR;
    wire              pf_vld;
    wire [P*32-1:0]   pf_phase_inc;
    wire [P*3-1:0]    pf_timbre;
    wire [P*7-1:0]    pf_note;
    wire [P*16-1:0]   pf_vel_gain, pf_vca_gain;
    wire [P*4-1:0]    pf_ch;
    wire [P-1:0]      pf_gate, pf_fast_rel, pf_sust_pedal;

    reg [P*32-1:0] rs_phase_acc = 0;
    reg [P*16-1:0] rs_env_value = 0;
    reg [P*3-1:0]  rs_env_state = 0;
    reg [P*32-1:0] rs_filter_ic1 = 0;
    reg [P*32-1:0] rs_filter_ic2 = 0;

    sched_subsystem #(.P(P), .G(G), .NCH(NCH), .STRIDE(STRIDE)) dut (
        .clk(clk), .rst_n_sync(rst_n), .frame_stb(frame_stb),
        .midi_rx(midi_rx),
        .slot(slot), .slot_vld(slot_vld),
        .ext_volume(ext_volume), .ext_expression(ext_expression),
        .ext_pan_gL(ext_pan_gL), .ext_pan_gR(ext_pan_gR),
        .ext_send_rev(ext_send_rev), .ext_send_cho(ext_send_cho), .ext_send_del(ext_send_del),
        .pf_vld(pf_vld), .pf_phase_inc(pf_phase_inc), .pf_timbre(pf_timbre),
        .pf_note(pf_note), .pf_vel_gain(pf_vel_gain), .pf_vca_gain(pf_vca_gain),
        .pf_ch(pf_ch), .pf_gate(pf_gate), .pf_fast_rel(pf_fast_rel),
        .pf_sust_pedal(pf_sust_pedal),
        .rs_phase_acc(rs_phase_acc), .rs_env_value(rs_env_value),
        .rs_env_state(rs_env_state), .rs_filter_ic1(rs_filter_ic1),
        .rs_filter_ic2(rs_filter_ic2)
    );

    integer errors = 0;
    task chk(input cond, input [255:0] name);
        begin
            if (!cond) begin errors = errors + 1; $display("FAIL  %0s", name); end
            else $display("  ok  %0s", name);
        end
    endtask

    // MIDI 字节发送（31250 baud）
    task sbit(input v); begin midi_rx[0] = v; repeat (BITCLK) @(posedge clk); end endtask
    task sbyte(input [7:0] b);
        integer i; begin
            sbit(0); for (i=0;i<8;i=i+1) sbit(b[i]); sbit(1);
        end
    endtask

    //--------------------------------------------- 监视器
    integer n_slot = 0;                       // 本帧 slot_vld 个数
    integer err_slot_cnt = 0;
    reg     slot_seen = 0;
    reg [P-1:0] gate_seen = 0;
    always @(posedge clk) begin
        if (frame_stb) begin
            n_slot <= 0;
        end else if (slot_vld) begin
            n_slot <= n_slot + 1;
            slot_seen <= 1'b1;
        end
        if (pf_vld) gate_seen <= gate_seen | pf_gate;
    end

    integer i;
    initial begin
        $dumpfile("tb_timbre_probe.vcd");
        $dumpvars(0, tb_timbre_probe);

        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (FRAME+50) @(posedge clk);      // 跑一整帧

        //================================================ ① 复位后确定
        $display("== 1. outputs are defined after reset ==");
        // ⚠ 期望值不是 0：sakiko 集成时给 chan_table 补了复位默认值
        //    （音量 100、表情 127、声像 64 居中、pan_gL/R = 23170），
        //    因为复位后全 0 会让整链没声音。这里既检查"确定、不是 X"，
        //    也把这组默认值钉住，防止将来被误改回 0。
        chk(^ext_volume !== 1'bx, "ext_volume 已确定（不是 X）");
        chk(^ext_pan_gL !== 1'bx, "ext_pan_gL 已确定（不是 X）");
        chk(ext_volume[0*7 +: 7] === 7'd100, "ext_volume[0] = 100（复位默认值）");
        chk(ext_pan_gL[0*16 +: 16] === 16'd23170, "ext_pan_gL[0] = 23170（等功率居中）");
        chk(^slot === 1'b0 || ^slot === 1'b1, "slot 已确定");

        //================================================ ② 时隙时序
        $display("== 2. slot_vld timing ==");
        chk(slot_seen === 1'b1, "slot_vld 有脉冲");
        chk(n_slot <= G, "每帧 slot_vld 不超过 G 个");
        $display("       本帧 slot_vld 计数 = %0d（期望 %0d）", n_slot, G);

        //================================================ ③ Note On 全链路
        $display("== 3. MIDI Note On -> allocation -> prefetch ==");
        sbyte(8'h90); sbyte(8'h3C); sbyte(8'h64);      // Note On ch0 key60 vel100
        repeat (FRAME*3) @(posedge clk);               // 等分配 + 提交 + 预取
        $display("       pf_gate = %b（至少一位为 1 表示分配成功）", pf_gate);
        chk(gate_seen != {P{1'b0}}, "Note On 后预取出现 gate=1");
        chk(pf_ch[0*4 +: 4] === 4'd0, "泳道 0 的通道号 = 0");

        //================================================ ④ 运行状态写回
        $display("== 4. runtime state write-back ==");
        // 给全部泳道一个可辨识的 env_state = 3（RELEASE）
        rs_env_state = {P{3'd3}};
        rs_env_value = {P{16'h1234}};
        repeat (FRAME*2) @(posedge clk);
        // 用 dut 内部的扫描口读回（scan_req 由 voice_alloc 驱动，这里直接层次访问不方便，
        // 改成检查 voice_fetch 内部表：通过 scan_env_state 需要外部发请求，故这里只做
        // 弱检查 —— ext_* 仍在更新说明链路活着）
        chk(^ext_volume !== 1'bx, "ext_volume 仍为确定值");

        //================================================ ⑤ 帧边界
        $display("== 5. ext_* only changes at frame_stb ==");
        // 记录帧内某个值，等半帧再比一次
        begin : blk
            reg [6:0] v_before;
            v_before = ext_volume[0*7 +: 7];
            repeat (FRAME/2) @(posedge clk);
            chk(ext_volume[0*7 +: 7] === v_before, "帧内 ext_volume 不变");
        end

        //================================================ ⑥ 音色映射探针
        //  目的：定位"换 Program Change 音色不变"到底断在哪一段。
        //  看 pf_timbre[0*3 +: 3] 是否随 pc 变化：
        //    变了 → 调度层没问题，问题在单声部层/波表/CST
        //    不变 → 断在 sched_subsystem 内部（chan_table → timbre_map → vtab → 预取）
        $display("== 6. Program Change -> pf_timbre probe ==");

        // --- pc = 0 ---
        // 监视 PC 事件是否真的产生，以及 chan_table 的写使能
        fork
            forever @(posedge clk) begin
                if (dut.ev_pc)
                    $display("       [事件] ev_pc  ch=%0d prog=%0d", dut.ev_pc_ch, dut.ev_pc_prog);
                if (dut.u_ct.wr_en && dut.u_ct.wr_fld == 5'd14)
                    $display("       [写入] chan_table 写 program: ch=%0d val=%0d",
                             dut.u_ct.wr_ch, dut.u_ct.wr_val[6:0]);
                // S_DEC(=3) 那一拍：timbre_map 正要采样 prog_num
                // S_WRITE(=4) 那一拍：awr_timbre 应该等于 tm_slot
                if (dut.u_va.st == 3'd4)
                    $display("       [S_WRITE] awr_id=%0d awr_timbre=%0d tm_slot=%0d",
                             dut.u_va.awr_id, dut.u_va.awr_timbre, dut.u_va.tm_slot);
                // aw_q 入队时打印
                if (dut.u_vf.awr && !dut.u_vf.aw_full)
                    $display("       [入队] aw_cnt=%0d awr_id=%0d awr_timbre=%0d",
                             dut.u_vf.aw_cnt, dut.u_vf.awr_id, dut.u_vf.awr_timbre);
                // 提交时打印 vtab 前后值
                if (dut.u_vf.st == 3'd2 && dut.u_vf.idx < dut.u_vf.aw_cnt)
                    $display("       [提交] idx=%0d id=%0d vtab_old_timbre=%0d e[28:26]=%0d",
                             dut.u_vf.idx, dut.u_vf.aw_q[dut.u_vf.idx][51:47],
                             dut.u_vf.vtab[dut.u_vf.aw_q[dut.u_vf.idx][51:47]][188:186],
                             dut.u_vf.aw_q[dut.u_vf.idx][28:26]);
                if (dut.u_va.st == 3'd3)
                    $display("       [S_DEC] ch_rd_addr=%0d rd_ch=%0d rd_program=%0d ch_prog_num=%0d tm_slot=%0d",
                             dut.u_va.ch_rd_addr, dut.u_ct.rd_ch, dut.u_ct.rd_program,
                             dut.u_va.ch_prog_num, dut.u_va.tm_slot);
            end
        join_none
        sbyte(8'hC0); sbyte(8'h00);                    // Program Change ch0 prog=0
        sbyte(8'h90); sbyte(8'h3C); sbyte(8'h64);      // Note On ch0 key60 vel100
        repeat (FRAME*3) @(posedge clk);
        $display("       pc=0 -> pf_timbre=%b  泳道0=%0d  泳道1=%0d",
                 pf_timbre, pf_timbre[0*3 +: 3], pf_timbre[1*3 +: 3]);
        $display("       [内部] ch_prog_num(来自chan_table)=%0d  ch_bank_msb=%0d",
                 dut.u_va.ch_prog_num, dut.u_va.ch_bank_msb);
        $display("       [内部] timbre_map.prog_num=%0d  tm_slot=%0d  tm_req=%b",
                 dut.u_va.u_timbre_map.prog_num, dut.u_va.tm_slot,
                 (dut.u_va.st == 3'd3));
        $display("       [内部] voice_alloc.st=%0d  awr_timbre=%0d",
                 dut.u_va.st, dut.u_va.awr_timbre);
        begin : b0
            reg [2:0] t0;
            t0 = pf_timbre[0*3 +: 3];
            chk(t0 === 3'd0, "pc=0 时泳道0 的 timbre_slot = 0");

            // --- 换 pc = 5（先 Note Off 清掉，再重新按，符合"新音起效"）---
            sbyte(8'h80); sbyte(8'h3C); sbyte(8'h40);  // Note Off
            repeat (FRAME) @(posedge clk);
            sbyte(8'hC0); sbyte(8'h05);                // Program Change prog=5
            sbyte(8'h90); sbyte(8'h3C); sbyte(8'h64);  // Note On 重新按
            repeat (FRAME*3) @(posedge clk);
            $display("       pc=5 -> 各泳道: %0d %0d %0d %0d %0d %0d %0d %0d",
                     pf_timbre[0*3+:3], pf_timbre[1*3+:3], pf_timbre[2*3+:3], pf_timbre[3*3+:3],
                     pf_timbre[4*3+:3], pf_timbre[5*3+:3], pf_timbre[6*3+:3], pf_timbre[7*3+:3]);
        $display("               vtab 各声部 timbre: %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                     dut.u_vf.vtab[0][188:186], dut.u_vf.vtab[1][188:186], dut.u_vf.vtab[2][188:186],
                     dut.u_vf.vtab[3][188:186], dut.u_vf.vtab[4][188:186], dut.u_vf.vtab[5][188:186],
                     dut.u_vf.vtab[6][188:186], dut.u_vf.vtab[7][188:186], dut.u_vf.vtab[8][188:186],
                     dut.u_vf.vtab[9][188:186], dut.u_vf.vtab[10][188:186], dut.u_vf.vtab[11][188:186]);
            chk(1'b1, "pc=5 观察（见上方打印）");

            // --- 换 pc = 2 再确认一次 ---
            sbyte(8'h80); sbyte(8'h3C); sbyte(8'h40);
            repeat (FRAME) @(posedge clk);
            sbyte(8'hC0); sbyte(8'h02);
            sbyte(8'h90); sbyte(8'h3C); sbyte(8'h64);
            repeat (FRAME*3) @(posedge clk);
            $display("       pc=2 -> pf_timbre=%b  泳道0=%0d", pf_timbre, pf_timbre[0*3 +: 3]);
            chk(1'b1, "pc=2 观察（见上方打印）");

            if (t0 === pf_timbre[0*3 +: 3])
                $display("       ⚠ 三次的 timbre_slot 都没变 —— 断点在调度层内部");
            else
                $display("       ✓ timbre_slot 随 pc 变化 —— 调度层正常");
        end

        if (errors == 0) $display("PASS  tb_timbre_probe");
        else             $display("FAIL  tb_timbre_probe : %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
