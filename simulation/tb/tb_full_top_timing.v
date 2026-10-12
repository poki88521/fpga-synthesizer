//============================================================================
//  tb_full_top_timing —— `full_top` 每采样拍数剖视
//
//  目的：文档写"每采样 1024 拍预算"，各环节占用是**估算**的
//        （通道层约 52、效果发送 65、效果运算 130、主混音 17…）。
//        本 TB **实测**每个环节的握手间隔，验证预算是否真的够用。
//
//  原理：`full_top` 是一条流水线，各段用握手传递：
//        sample_stb → slot_vld×4 → ch_vld×16 → bus_vld → fx_vld → mix_vld → 下一拍 sample_stb
//        在 `sample_stb` 那一拍把各信号的到达拍号记下来，相减即各段耗时。
//
//  ⚠ **基准点必须写清**，否则会算错：
//     `效果发送` 要从 **ch_vld 首次**（不是末次）算起，因为 send_bus 是
//     "边收边存"（ST_CAP 16 拍与 ch_vld 的 16 拍重叠）。从末次算会少 15 拍，
//     把 65 拍误读成 50 拍（本 TB 第一版就报错了这个数）。
//
//  验证点：
//    ① 各段拍数（打印实测值）
//    ② 总占用 ≤ 1024 拍（否则时隙会撞上下一个采样帧 → 功能错乱）
//    ③ 每帧恰好 1 次 sample_stb、4 次 slot_vld、16 次 ch_vld、1 次 bus_vld/fx_vld/mix_vld
//    ④ 顺序正确：slot_vld 早于 ch_vld 早于 bus_vld 早于 fx_vld 早于 mix_vld
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_full_top_timing;
    localparam integer HALF_NS = 10;

    reg clk50 = 0, clk12288 = 0;
    always #HALF_NS clk50    = ~clk50;
    always #HALF_NS clk12288 = ~clk12288;

    wire HP_BCK, HP_WS, HP_DIN, PA_EN;

    full_top #(
        .USE_PLL(0),
        .TEST_MODE_DEFAULT(0),      // 关测试模式，走真实音频通路
        .PA_DELAY(8), .POR_BITS(8)
    ) dut (
        .clk50(clk50), .clk12288(clk12288),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN)
    );

    // 以 sample_stb 为帧基准的拍计数
    //  ⚠ 必须用**帧内标志**做隔离，不能用"基准拍号>=0"判断：
    //     sample_stb 与 slot_vld 在同一个 always 块里被检测，
    //     清零与计数同拍发生，会把上一帧的尾巴算进来（本 TB 第一版踩过）
    integer cyc = 0;
    integer fbase = 0;             // 本帧 sample_stb 的拍号（只用于相对拍号）
    reg     in_frame = 0;
    always @(posedge clk50) cyc = cyc + 1;

    // 本帧内各信号的首次到达拍号（相对 base）
    integer t_slot   = -1, t_ch = -1, t_bus = -1, t_fx = -1, t_mix = -1;
    integer n_slot = 0, n_ch = 0, n_bus = 0, n_fx = 0, n_mix = 0, n_frame = 0;
    integer last_slot = -1, last_ch = -1, last_bus = -1, last_fx = -1, last_mix = -1;
    // 上一帧的统计（等下一帧开始时结算）
    integer p_slot = 0, p_ch = 0, p_bus = 0, p_fx = 0, p_mix = 0;
    integer p_tslot = 0, p_tch = 0, p_tbus = 0, p_tfx = 0, p_tmix = 0;
    integer p_lslot = 0, p_lch = 0;

    integer errs = 0;
    integer frames_done = 0;

    always @(posedge clk50) begin
        if (dut.sample_stb) begin
            // 结算上一帧（该帧已完整走完）
            if (n_frame > 0) begin
                p_slot = n_slot; p_ch = n_ch; p_bus = n_bus; p_fx = n_fx; p_mix = n_mix;
                p_tslot = t_slot; p_tch = t_ch; p_tbus = t_bus; p_tfx = t_fx; p_tmix = t_mix;
                p_lslot = last_slot; p_lch = last_ch;
                frames_done = frames_done + 1;
            end
            fbase = cyc;
            n_slot = 0; n_ch = 0; n_bus = 0; n_fx = 0; n_mix = 0;
            last_slot = -1; last_ch = -1; last_bus = -1; last_fx = -1; last_mix = -1;
            t_slot = -1; t_ch = -1; t_bus = -1; t_fx = -1; t_mix = -1;
            n_frame = n_frame + 1;
            in_frame = 1;
        end else if (in_frame) begin
            if (dut.slot_vld) begin
                n_slot = n_slot + 1;
                if (t_slot < 0) t_slot = cyc - fbase;
                last_slot = cyc - fbase;
            end
            if (dut.ch_vld) begin
                n_ch = n_ch + 1;
                if (t_ch < 0) t_ch = cyc - fbase;
                last_ch = cyc - fbase;
            end
            if (dut.bus_vld) begin
                n_bus = n_bus + 1;
                if (t_bus < 0) t_bus = cyc - fbase;
                last_bus = cyc - fbase;
            end
            if (dut.fx_vld) begin
                n_fx = n_fx + 1;
                if (t_fx < 0) t_fx = cyc - fbase;
                last_fx = cyc - fbase;
            end
            if (dut.mix_vld) begin
                n_mix = n_mix + 1;
                if (t_mix < 0) t_mix = cyc - fbase;
                last_mix = cyc - fbase;
            end
        end
    end

    integer i;
    initial begin
        wait (dut.por_rst_n == 1'b1);
        // 跑 40 帧
        wait (frames_done >= 40);
        repeat (2) @(posedge clk50);

        $display("");
        $display("=== full_top 每采样拍数剖视（40 帧稳定后）===");
        $display("");
        $display("  各握手信号：每帧次数 / 首次到达拍 / 末次到达拍");
        $display("    sample_stb   : 1 次（帧基准，拍 0）");
        $display("    slot_vld     : %0d 次   首次 %0d 拍   末次 %0d 拍", p_slot, p_tslot, p_lslot);
        $display("    ch_vld       : %0d 次   首次 %0d 拍   末次 %0d 拍", p_ch,   p_tch,   p_lch);
        $display("    bus_vld      : %0d 次   首次 %0d 拍（单次）", p_bus,  p_tbus);
        $display("    fx_vld       : %0d 次   首次 %0d 拍（单次）", p_fx,   p_tfx);
        $display("    mix_vld      : %0d 次   首次 %0d 拍（单次）", p_mix,  p_tmix);
        $display("");
        $display("  各段实测耗时（拍）——**注意基准点**：");
        $display("    声部时隙段   slot_vld 首→末               = %0d", p_lslot - p_tslot);
        $display("    通道层       slot_vld 末 → ch_vld 首      = %0d", p_tch - p_lslot);
        $display("    通道层输出   ch_vld 首→末                 = %0d", p_lch - p_tch);
        $display("    效果发送     ch_vld 首次 → bus_vld      = %0d   ← 对应文档的 捕获16+计算48+输出1 = 65",
                 p_tbus - p_tch);
        $display("    效果运算     bus_vld → fx_vld             = %0d   ← 对应文档 LAT_MAX(128)+2=130",
                 p_tfx - p_tbus);
        $display("    主混音       fx_vld → mix_vld             = %0d", p_tmix - p_tfx);
        $display("    **全程占用   mix_vld 到达拍          = %0d / 1024 拍**", p_tmix);
        $display("    余量         1024 − 全程             = %0d 拍（%0d%%）",
                 1024 - p_tmix, (1024 - p_tmix) * 100 / 1024);

        $display("");
        $display("=== 自检 ===");
        if (p_slot != 4) begin $display("  FAIL: slot_vld 每帧 %0d 次（应 4）", p_slot); errs = errs + 1; end
        else $display("  slot_vld 每帧 4 次 ✓");
        if (p_ch != 16) begin $display("  FAIL: ch_vld 每帧 %0d 次（应 16）", p_ch); errs = errs + 1; end
        else $display("  ch_vld 每帧 16 次 ✓");
        if (p_bus != 1) begin $display("  FAIL: bus_vld 每帧 %0d 次（应 1）", p_bus); errs = errs + 1; end
        else $display("  bus_vld 每帧 1 次 ✓");
        if (p_fx != 1) begin $display("  FAIL: fx_vld 每帧 %0d 次（应 1）", p_fx); errs = errs + 1; end
        else $display("  fx_vld 每帧 1 次 ✓");
        if (p_mix != 1) begin $display("  FAIL: mix_vld 每帧 %0d 次（应 1）", p_mix); errs = errs + 1; end
        else $display("  mix_vld 每帧 1 次 ✓");

        if (!(p_tslot < p_lslot && p_lslot <= p_tch && p_tch <= p_lch &&
              p_lch <= p_tbus && p_tbus <= p_tfx && p_tfx <= p_tmix)) begin
            $display("  FAIL: 握手顺序不对");
            errs = errs + 1;
        end else $display("  握手顺序 正确 ✓");

        if (p_tmix > 1024) begin
            $display("  FAIL: 全程 %0d 拍 > 1024，会撞下一帧！", p_tmix);
            errs = errs + 1;
        end else $display("  全程 %0d 拍 ≤ 1024，预算够用 ✓（余量 %0d%%）",
                          p_tmix, (1024 - p_tmix) * 100 / 1024);

        $display("");
        if (errs == 0) $display("PASS  tb_full_top_timing: 拍数剖视完成");
        else           $display("FAIL  tb_full_top_timing: %0d 项", errs);
        $finish;
    end

    initial begin
        #600_000_000;
        $display("FAIL  tb_full_top_timing: 超时（frames=%0d）", frames_done);
        $finish;
    end
endmodule
`default_nettype wire
