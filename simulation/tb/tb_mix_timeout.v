//============================================================================
//  tb_mix_timeout —— main_mix 的 ST_WAIT 超时兜底验证
//
//  背景（2026-10-06）：main_mix 原来在 ST_WAIT 死等 fx_vld，只要丢一次就永久卡住，
//  主混音输出冻结成常数（demo 里实测 main_l 201 拍只变 4 次）。
//  加了 WAIT_MAX=1024 拍超时兜底后，需要验证：
//
//      1) 正常路径：ch 流 + fx_vld 按时到 → 输出 = dry + fx（与之前一致）
//      2) 效果失联：ch 流照常、**fx_vld 一直不来** → 超时后按干声输出，且 mix_vld 照发
//      3) 失联恢复：之后 fx_vld 再来 → 能正常回到"dry + fx"路径
//      4) 任何情况下 mix_vld 的次数 == 输入帧数（不丢帧、不僵死）
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_mix_timeout;
    localparam integer NCH = 16;
    localparam integer AW  = 24;
    localparam integer GAP = 200;        // 通道流之间的间隔（每帧 16 个通道）

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg                    ch_vld = 0;
    reg  [3:0]             ch_addr = 0;
    reg  signed [AW-1:0]   ch_l = 0, ch_r = 0;
    reg  signed [AW-1:0]   fx_l = 0, fx_r = 0;
    reg                    fx_vld = 0;
    wire                   mix_vld;
    wire signed [AW-1:0]   main_l, main_r;

    main_mix #(.NCH(NCH), .AW(AW)) dut (
        .clk(clk), .rst_n(rst_n), .frame_stb(1'b0),
        .ch_vld(ch_vld), .ch_addr(ch_addr), .ch_l(ch_l), .ch_r(ch_r),
        .fx_l(fx_l), .fx_r(fx_r), .fx_vld(fx_vld),
        .mix_vld(mix_vld), .main_l(main_l), .main_r(main_r)
    );

    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    integer n_frame = 0;      // 发出的帧数
    integer n_out   = 0;      // 收到的 mix_vld 次数
    integer errs    = 0;

    always @(posedge clk) if (mix_vld) n_out = n_out + 1;

    // 发一帧 16 个通道（每个通道值 = base + i）
    task send_frame;
        input integer base;
        integer i;
        begin
            for (i = 0; i < NCH; i = i + 1) begin
                @(negedge clk);
                ch_vld  = 1;
                ch_addr = i[3:0];
                ch_l    = base + i;
                ch_r    = base + i;
                @(negedge clk);
                ch_vld  = 0;
            end
            n_frame = n_frame + 1;
        end
    endtask

    // 发一次效果返回
    task send_fx;
        input integer v;
        begin
            @(negedge clk);
            fx_vld = 1; fx_l = v; fx_r = v;
            @(negedge clk);
            fx_vld = 0;
        end
    endtask

    integer i, expect_dry, got_sum;
    integer out_before, out_after;

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // ---------------- 1) 正常路径 ----------------
        $display("=== 1) 正常路径：ch 流 + fx_vld 按时到 ===");
        fork
            send_frame(1000);
            begin
                repeat (16*2 + 40) @(negedge clk);   // 等通道流走完
                send_fx(500);
            end
        join
        repeat (20) @(posedge clk);
        $display("  发出帧数=%0d  收到 mix_vld=%0d", n_frame, n_out);
        if (n_out != n_frame) begin $display("  FAIL: 正常路径下丢帧"); errs = errs + 1; end

        // 干声和 = 1000..1015 之和 = 16*1000 + 120 = 16120；加 fx 500 → 16620
        expect_dry = 16*1000 + (0+15)*16/2;
        $display("  干声理论值 = %0d，+fx(500) = %0d，实测 main_l = %0d（差 %0d）",
                 expect_dry, expect_dry+500, main_l, main_l - (expect_dry+500));
        if (main_l != expect_dry + 500) begin
            $display("  FAIL: 正常路径下 main_l 不等于 dry+fx"); errs = errs + 1;
        end

        // ---------------- 2) 效果失联（fx_vld 一直不来）----------------
        $display("");
        $display("=== 2) 效果失联：fx_vld 一直不来，应超时按干声输出 ===");
        out_before = n_out;
        send_frame(2000);
        // 等超时（WAIT_MAX=1024 拍）+ 余量
        repeat (1200) @(posedge clk);
        $display("  失联后新增 mix_vld = %0d（期望 1）", n_out - out_before);
        if (n_out - out_before != 1) begin
            $display("  FAIL: 失联时没有输出（或输出次数不对）→ 会僵死"); errs = errs + 1;
        end
        expect_dry = 16*2000 + (0+15)*16/2;
        $display("  干声理论值 = %0d，实测 main_l = %0d", expect_dry, main_l);
        if (main_l != expect_dry) begin
            $display("  FAIL: 超时输出不等于干声"); errs = errs + 1;
        end
        $display("  → 失联不再僵死 ✓");

        // ---------------- 3) 失联恢复 ----------------
        $display("");
        $display("=== 3) 失联恢复：之后 fx_vld 再来应恢复正常 ===");
        out_before = n_out;
        fork
            send_frame(3000);
            begin
                repeat (16*2 + 40) @(negedge clk);
                send_fx(700);
            end
        join
        repeat (30) @(posedge clk);
        $display("  恢复后新增 mix_vld = %0d（期望 1）", n_out - out_before);
        if (n_out - out_before != 1) begin $display("  FAIL: 恢复后没有输出"); errs = errs + 1; end
        expect_dry = 16*3000 + (0+15)*16/2;
        $display("  干声理论值 = %0d，+fx(700) = %0d，实测 main_l = %0d",
                 expect_dry, expect_dry+700, main_l);
        if (main_l != expect_dry + 700) begin
            $display("  FAIL: 恢复后 main_l 不等于 dry+fx"); errs = errs + 1;
        end

        // ---------------- 4) 总结 ----------------
        $display("");
        $display("=== 4) 总计 ===");
        $display("  发出帧数=%0d  收到 mix_vld=%0d  %s", n_frame, n_out,
                 (n_out == n_frame) ? "一一对应 OK" : "不匹配！");
        if (n_out != n_frame) begin $display("  FAIL: 有丢帧"); errs = errs + 1; end

        if (errs == 0) $display("\nPASS  tb_mix_timeout: 正常/失联/恢复 三态全过");
        else           $display("\nFAIL  tb_mix_timeout: %0d 项", errs);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL  tb_mix_timeout: 超时  n_frame=%0d n_out=%0d", n_frame, n_out);
        $finish;
    end

endmodule
`default_nettype wire
