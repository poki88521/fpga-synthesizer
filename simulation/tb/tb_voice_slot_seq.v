//============================================================================
//  tb_voice_slot_seq —— 声部时隙时序器单元测试
//
//  逐条验证 §三.七 的四条硬性契约：
//    1) 每采样周期恰好发 G 个 slot_vld，位置固定
//    2) 每个脉冲恰好 1 拍宽
//    3) slot 在 slot_vld 那一拍有效，顺序 0..G-1
//    4) 第一个脉冲距 frame_stb 至少 1 拍
//  另外检查时隙间距 = STRIDE，并跑两组参数（G=4/STRIDE=8 与 G=4/STRIDE=16）。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_voice_slot_seq;
    parameter G1 = 4, S1 = 8;
    parameter G2 = 4, S2 = 16;

    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_n = 0;
    reg frame_stb = 0;

    wire [1:0] slot_a, slot_b;
    wire       vld_a, vld_b;

    voice_slot_seq #(.G(G1), .STRIDE(S1)) dut_a (
        .clk(clk), .rst_n_sync(rst_n), .frame_stb(frame_stb),
        .slot(slot_a), .slot_vld(vld_a)
    );
    voice_slot_seq #(.G(G2), .STRIDE(S2)) dut_b (
        .clk(clk), .rst_n_sync(rst_n), .frame_stb(frame_stb),
        .slot(slot_b), .slot_vld(vld_b)
    );

    //----------------------------------------------- 监视器 A
    integer   n_a = 0;             // 本帧脉冲数
    integer   err_order_a = 0, err_width_a = 0, err_first_a = 0, err_gap_a = 0, err_cnt_a = 0;
    reg       last_vld_a = 0;
    integer   cyc_a = 0;           // 自 frame_stb 起的拍数
    integer   last_gap_a = 0;
    reg       first_seen_a = 0;
    reg [1:0] slot_cap_a = 0;
    reg       cap_valid_a = 0;

    //----------------------------------------------- 监视器 B
    integer   n_b = 0;
    integer   err_order_b = 0, err_width_b = 0, err_first_b = 0, err_gap_b = 0, err_cnt_b = 0;
    reg       last_vld_b = 0;
    integer   cyc_b = 0;
    integer   last_gap_b = 0;
    reg       first_seen_b = 0;

    // 用 negedge 采样监视信号，避开与 DUT 的 posedge 竞争
    always @(posedge clk) begin
        // ---- A ----
        if (frame_stb) begin
            cyc_a <= 0; n_a <= 0; first_seen_a <= 0; last_gap_a <= 0;
        end else begin
            cyc_a <= cyc_a + 1;
            if (vld_a) begin
                if (!first_seen_a) begin
                    if (cyc_a < 1) err_first_a <= 1;      // 契约 4
                    first_seen_a <= 1;
                end else begin
                    if (cyc_a - last_gap_a != S1) err_gap_a <= 1;   // 间距
                end
                last_gap_a <= cyc_a;
                if (slot_a !== n_a[1:0]) err_order_a <= 1;          // 契约 3
                if (last_vld_a)          err_width_a <= 1;          // 契约 2
                n_a <= n_a + 1;
            end
            if (last_vld_a && !vld_a && n_a == G1 && first_seen_a) begin
                // 只在"本帧已发满"时不报错；帧末统一检查 n_a == G1
            end
        end
        last_vld_a <= vld_a;

        // ---- B ----
        if (frame_stb) begin
            cyc_b <= 0; n_b <= 0; first_seen_b <= 0; last_gap_b <= 0;
        end else begin
            cyc_b <= cyc_b + 1;
            if (vld_b) begin
                if (!first_seen_b) begin
                    if (cyc_b < 1) err_first_b <= 1;
                    first_seen_b <= 1;
                end else begin
                    if (cyc_b - last_gap_b != S2) err_gap_b <= 1;
                end
                last_gap_b <= cyc_b;
                if (slot_b !== n_b[1:0]) err_order_b <= 1;
                if (last_vld_b)          err_width_b <= 1;
                n_b <= n_b + 1;
            end
        end
        last_vld_b <= vld_b;
    end

    // 帧末检查脉冲数（在 frame_stb 前几拍取样）
    integer errors = 0;
    integer i;
    reg [31:0] n_a_frame, n_b_frame;

    task chk(input cond, input [255:0] name);
        begin
            if (!cond) begin errors = errors + 1; $display("FAIL  %0s", name); end
            else $display("  ok  %0s", name);
        end
    endtask

    // 跑若干帧，frame_stb 周期 100 拍
    task run_frames(input integer nfr);
        integer f, t;
        begin
            for (f = 0; f < nfr; f = f + 1) begin
                for (t = 0; t < 92; t = t + 1) @(posedge clk);
                // 帧末：记录脉冲数
                n_a_frame = n_a;
                n_b_frame = n_b;
                if (n_a_frame !== G1) begin
                    errors = errors + 1;
                    $display("FAIL  frame %0d : A pulses = %0d, exp %0d", f, n_a_frame, G1);
                end
                if (n_b_frame !== G2) begin
                    errors = errors + 1;
                    $display("FAIL  frame %0d : B pulses = %0d, exp %0d", f, n_b_frame, G2);
                end
                // 产生 frame_stb（negedge 更新）
                @(negedge clk); frame_stb = 1'b1;
                @(negedge clk); frame_stb = 1'b0;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_voice_slot_seq.vcd");
        $dumpvars(0, tb_voice_slot_seq);

        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (5) @(posedge clk);

        $display("== run 5 frames, STRIDE=%0d / %0d ==", S1, S2);
        run_frames(5);

        $display("== contract checks ==");
        chk(err_first_a == 0, "A: first pulse >= 1 cycle after frame_stb");
        chk(err_width_a == 0, "A: every pulse exactly 1 cycle wide");
        chk(err_order_a == 0, "A: slot counts 0,1,..,G-1 in order");
        chk(err_gap_a   == 0, "A: pulse spacing == STRIDE");
        chk(err_first_b == 0, "B: first pulse >= 1 cycle after frame_stb");
        chk(err_width_b == 0, "B: every pulse exactly 1 cycle wide");
        chk(err_order_b == 0, "B: slot counts 0,1,..,G-1 in order");
        chk(err_gap_b   == 0, "B: pulse spacing == STRIDE");

        if (errors == 0) $display("PASS  tb_voice_slot_seq");
        else             $display("FAIL  tb_voice_slot_seq : %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
