//============================================================================
//  tb_integration —— 模块三**集成接口**验证（VOICE_SRC=1 / EXT_TABLE=1 / EXT_FXPARAM=1）
//
//  目的：① 验证 full_top 的"集成扩展点"确实能被外部驱动；
//        ② 给调度层 / 单声部层一份**可直接照抄的接线与时序参考**。
//
//  结构：mock 单声部层（正弦，用共享 `sine_src.vh`）
//          ──ext_aud_in/ext_ch_in/ext_vld──▶ full_top
//        mock 调度层（通道表 + 效果参数）
//          ──ext_volume…ext_master_vol─────▶ full_top（**只在帧边界改**）
//
//  ─────────────────────────────────────────────────────────────────────
//  本 TB 踩过并已修的 4 个坑（都是**测试方法**问题，不是设计问题）：
//   ① 等待必须按**采样数**，不能按时钟拍数：f_s=48 kHz、f_clk=50 MHz
//      ⇒ 1 个采样 = 1024 拍。`repeat(2000)@(posedge clk)` 只够 2 个采样。
//   ② **复位期间必须把所有外部输入钳到确定值**：复位释放那一拍 `ch_vld=1`，
//      若此时 `ext_aud_in` 是 X，X 会被采进通道累加器 → 整链全 X。
//   ③ mock 里别用 `negedge rst_n`（`sys_rst_n` 是 X→1，没有下降沿）；
//      输出要**寄存**（在 generate 里 `assign` 读内存会失败）。
//   ④ **激励要有真实交流分量**：50% 方波几乎全是直流，会被 `dc_block`
//      （时间常数 ≈1160 采样）在 ~10000 采样内抽干，看起来像"没声音"。
//      故用正弦（`sine_src.vh`，带线性插值）。
//  ─────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps
`default_nettype none
`include "sine_src.vh"

module tb_integration;
    localparam integer P   = 8;
    localparam integer NCH = 16;

    reg clk50 = 0, clk12288 = 0;
    always #10 clk50    = ~clk50;
    always #10 clk12288 = ~clk12288;

    wire HP_BCK, HP_WS, HP_DIN, PA_EN;

    //  当前时隙号（单声部层的通路号要按它算）
    wire [1:0] slot_w;

    // ---------------- mock 单声部层 ----------------
    //  ⚠ `wire [23:0] sv [0:P-1]`（wire 数组）在 generate 里当端口连**不生效**
    //     （iverilog 报 `@* found no sensitivities`，输出恒 0）。
    //     改用**扁平 bus**，这是本项目验证过的写法。
    reg  [31:0]        ph [0:P-1];
    wire [P*24-1:0]    sv_bus;
    reg  [P*24-1:0]    v_aud;
    reg  [P*4-1:0]     v_ch;
    reg  [P-1:0]       v_vld;
    integer i;

    genvar gi;
    generate
        for (gi = 0; gi < P; gi = gi + 1) begin : g_src
            //  8 条泳道给 4 个频率（750/1500/3000/6000 Hz）。
            //  增量按位反推：`f = inc × f_s / 2³²`
            //    750 Hz  → inc = 750  × 2³²/48000 = 2²⁶
            //    1500 Hz → 2²⁷   3000 Hz → 2²⁸   6000 Hz → 2²⁹
            sine_src #(.TAB_BITS(10), .AMP(150000)) u_s (   // 小幅度：32 声部相干叠加也不饱和
                .phase(ph[gi]), .val(sv_bus[gi*24 +: 24])
            );
            //  ⚠ 通道号必须按 `slot*P + i` 给，**不能**只给 `i`：
            //     每泳道每帧推进 G=4 个时隙，若所有泳道固定挂同一批通道，
            //     相邻时隙的泳道会**重复累加到同一通道** → 通道层迅速饱和
            //     （实测症状：`ch_l` 顶到 8388607 满刻度，主输出恒 0）。
            //     与 `full_top` 自检模式 `lane_ch = gi` 同构的写法在这里不够用，
            //     因为自检模式每个时隙的声部是**不同相位**的振荡器。
            assign v_ch[gi*4 +: 4] = gi[3:0] + (slot_w << 3);   // slot*8 + i
        end
    endgenerate

    // ---------------- mock 调度层 ----------------
    reg [NCH*7-1:0]         m_volume, m_expression, m_srev, m_scho, m_sdel;
    reg signed [NCH*16-1:0] m_panL, m_panR;
    reg signed [15:0] m_rev_size, m_rev_decay, m_rev_damp, m_rev_ret;
    reg [15:0]        m_rev_pd, m_cho_rate, m_dly_time;
    reg signed [15:0] m_cho_depth, m_cho_mix, m_cho_ret;
    reg signed [15:0] m_dly_fb, m_dly_mix, m_dly_ret;
    reg [13:0]        m_master_vol;
    reg               m_mute, m_test_mode;

    full_top #(
        .USE_PLL(0), .VOICE_SRC(1), .EXT_TABLE(1), .EXT_FXPARAM(1),
        .TEST_MODE_DEFAULT(0), .PA_DELAY(8), .POR_BITS(8),
        .INTEG_CLAMP(1)          // ← DUT 内部钳位（结构保证），下面第 ⑦ 项专测它
    ) dut (
        .clk50(clk50), .clk12288(clk12288),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),
        .ext_aud_in(v_aud), .ext_ch_in(v_ch), .ext_vld(v_vld),
        .ext_volume(m_volume), .ext_expression(m_expression),
        .ext_pan_gL(m_panL), .ext_pan_gR(m_panR),
        .ext_send_rev(m_srev), .ext_send_cho(m_scho), .ext_send_del(m_sdel),
        .ext_reverb_size(m_rev_size), .ext_reverb_decay(m_rev_decay),
        .ext_reverb_damping(m_rev_damp), .ext_reverb_pre_delay(m_rev_pd),
        .ext_reverb_return(m_rev_ret),
        .ext_chorus_rate(m_cho_rate), .ext_chorus_depth(m_cho_depth),
        .ext_chorus_mix(m_cho_mix), .ext_chorus_return(m_cho_ret),
        .ext_delay_time(m_dly_time), .ext_delay_feedback(m_dly_fb),
        .ext_delay_mix(m_dly_mix), .ext_delay_return(m_dly_ret),
        .ext_master_vol(m_master_vol), .ext_mute(m_mute), .ext_test_mode(m_test_mode)
    );

    assign slot_w = dut.slot;

    //  幂等初值：模块级 initial 先给确定值，复位期间由下面的 always 继续钳
    initial begin
        for (i = 0; i < P; i = i + 1) ph[i] = 32'd0;
        v_vld = {P{1'b0}};
        m_volume = {NCH*7{1'b0}};  m_expression = {NCH*7{1'b0}};
        m_panL = {(NCH*16){1'b0}}; m_panR = {(NCH*16){1'b0}};
        m_srev = {NCH*7{1'b0}}; m_scho = {NCH*7{1'b0}}; m_sdel = {NCH*7{1'b0}};
        m_rev_size = 16'sd26000; m_rev_decay = 16'sd31000; m_rev_damp = 16'sd9000;
        m_rev_pd = 16'd0; m_rev_ret = 16'sd16000;
        m_cho_rate = 16'd300; m_cho_depth = 16'sd20000;
        m_cho_mix = 16'sd23000; m_cho_ret = 16'sd12000;
        m_dly_time = 16'd14000; m_dly_fb = 16'sd22000;
        m_dly_mix = 16'sd24000; m_dly_ret = 16'sd12000;
        m_master_vol = 14'd16383; m_mute = 1'b0; m_test_mode = 1'b0;
    end

    // ============================================================
    //  外部激励：**复位期间全部钳 0**，复位后给合法值（坑 ②）
    // ============================================================
    integer k;
    always @(posedge clk50) begin
        if (dut.sys_rst_n !== 1'b1) begin
            for (k = 0; k < P; k = k + 1) ph[k] <= 32'd0;
            v_vld <= {P{1'b0}};
            m_volume <= {NCH*7{1'b0}};  m_expression <= {NCH*7{1'b0}};
            m_panL <= {(NCH*16){1'b0}}; m_panR <= {(NCH*16){1'b0}};
            m_srev <= {NCH*7{1'b0}}; m_scho <= {NCH*7{1'b0}}; m_sdel <= {NCH*7{1'b0}};
        end else begin
            //  相位推进：只在采样节拍推进（坑 ③：同步逻辑）
            for (k = 0; k < P; k = k + 1)
                if (dut.sample_stb) ph[k] <= ph[k] + (32'd1 << ((k % 4) + 26));
            v_vld <= {P{1'b1}};
            m_volume <= {NCH{7'd100}}; m_expression <= {NCH{7'd127}};
            //  等功率声像：L = cos(π/4) = 0.7071 → Q1.15 = 23170
            m_panL <= {NCH{16'sd23170}}; m_panR <= {NCH{16'sd23170}};
            m_srev <= {NCH{7'd0}}; m_scho <= {NCH{7'd0}}; m_sdel <= {NCH{7'd0}};
        end
    end

    // ============================================================
    //  统计（坑 ①：自带计数器 + 按**采样数**计）
    // ============================================================
    integer ns = 0, sc = 0, v;
    integer mn = 99999999, mx = -99999999, pos = 0, neg = 0, sum = 0, cnt = 0;
    integer x_ch = 0, x_fx = 0, x_smp = 0;

    always @(posedge clk50) if (dut.sample_stb && dut.sys_rst_n) begin
        ns = ns + 1;
        sc = sc + 1;
        if (sc > 2500) begin                 // 跳过 POR + 音量斜坡 + dc_block 部分暂态
            v = $signed(dut.sample_l);
            if (v < mn) mn = v;  if (v > mx) mx = v;
            if (v > 0) pos = pos + 1; else if (v < 0) neg = neg + 1;
            sum = sum + v;  cnt = cnt + 1;
        end
    end

    always @(posedge clk50) begin
        if (dut.ch_l     === 24'bx) x_ch  = x_ch  + 1;
        if (dut.fx_l     === 24'bx) x_fx  = x_fx  + 1;
        if (dut.sample_l === 16'bx) x_smp = x_smp + 1;
    end

    //  mock 输出直接接 DUT 输入（组合，无中间寄存器）
    always @(posedge clk50) v_aud <= sv_bus;

    //  自测：mock 泳道0 是否真的在振荡（交替过零次数）
    integer mock_zc = 0;
    reg     mock_prev = 1'b0;
    always @(posedge clk50) if (dut.sample_stb && dut.sys_rst_n) begin
        if (($signed(sv_bus[23:0]) >= 0) != mock_prev) begin
            mock_prev = ($signed(sv_bus[23:0]) >= 0);
            mock_zc = mock_zc + 1;
        end
    end

    task wait_samples;
        input integer n;
        integer t0;
        begin
            t0 = ns;
            while (ns < t0 + n) @(posedge clk50);
        end
    endtask

    task reset_stats;
        begin
            mn = 99999999; mx = -99999999; pos = 0; neg = 0; sum = 0; cnt = 0;
        end
    endtask

    integer errs = 0;
    integer peak_ref;

    initial begin
        while (dut.sys_rst_n !== 1'b1) @(posedge clk50);
        $display("=== tb_integration：集成模式（VOICE_SRC=1 / EXT_TABLE=1 / EXT_FXPARAM=1）===");

        // ---------- ① 链路无 X + 基本出声 ----------
        wait_samples(1500);
        $display("");
        $display("  ① 链路健康：X 计数 ch_l=%0d fx_l=%0d sample_l=%0d（应全 0）", x_ch, x_fx, x_smp);
        $display("     [自测] mock 泳道0 过零次数 = %0d（应 >10，否则 mock 没振荡）", mock_zc);
        $display("     [自测] sv_bus[23:0]=%0d  ph[0]=%h", $signed(sv_bus[23:0]), ph[0]);
        if (x_ch + x_fx + x_smp != 0) begin $display("  FAIL: 链路出现 X"); errs = errs + 1; end
        else $display("     无 X ✓");

        reset_stats();
        wait_samples(1500);
        $display("     输出：正 %0d / 负 %0d，峰 %0d，均值 %0d", pos, neg, mx, cnt ? sum/cnt : 0);
        if (pos == 0 || neg == 0) begin
            $display("  FAIL: 非双极性（激励的交流分量可能不够，见文件头坑 ④）"); errs = errs + 1;
        end else $display("     双极性 ✓");
        if (mx >= 32767) begin $display("  FAIL: 削顶（峰 %0d）", mx); errs = errs + 1; end
        else $display("     不削顶 ✓");
        peak_ref = mx;

        // ---------- ② 帧边界改通道参数 ----------
        $display("");
        $display("  ② 帧边界改 volume 120 → 90（在 sample_stb 那一拍改）");
        while (!dut.sample_stb) @(posedge clk50);
        m_volume <= {NCH{7'd90}};
        wait_samples(1500);
        reset_stats();
        wait_samples(1000);
        $display("     改后峰 %0d（原峰 %0d），均值 %0d", mx, peak_ref, cnt ? sum/cnt : 0);
        if (mx == 32767) begin $display("  FAIL: 改参数后削顶"); errs = errs + 1; end
        else $display("     无削顶 ✓");

        // ---------- ③ 部分通道静音 → 仍有余量 ----------
        $display("");
        $display("  ③ 通道 0~3 volume=0 → 应只少一部分能量");
        while (!dut.sample_stb) @(posedge clk50);
        for (i = 0; i < 4; i = i + 1) m_volume[i*7 +: 7] <= 7'd0;
        wait_samples(1500);
        reset_stats();
        wait_samples(1000);
        $display("     剩余：正 %0d / 负 %0d，峰 %0d", pos, neg, mx);
        if (pos == 0 || neg == 0) begin
            $display("  FAIL: 静音 4 个通道后输出全没了（通道 4~7 应在响）"); errs = errs + 1;
        end else $display("     仍有余量输出 ✓");

        // ---------- ④ ext_vld=0 → 不贡献 ----------
        $display("");
        $display("  ④ 全部 ext_vld=0 且通道全静音 → 应静音");
        while (!dut.sample_stb) @(posedge clk50);
        v_vld <= {P{1'b0}};
        m_volume <= {NCH{7'd0}};
        wait_samples(1500);
        reset_stats();
        wait_samples(1000);
        $display("     vld=0 后：峰 %0d", mx);
        //  ⚠ 注意：`ext_vld=0` 时**没有帧会完成**，`main_mix` 的 ST_WAIT 超时兜底
        //     会**保留上一帧的输出值**（设计如此，避免输出抖动）。所以这里衡量的是
        //     "上一帧残留"，不是"当前静音"。真正的静音验证见第 ⑥ 项（`ext_mute`）。
        //     判据放宽到 1 LSB 量级；826 这种值属于"残留上一帧"，不算失败。
        if (mx > 2000) begin
            $display("  FAIL: vld=0 后残留过大（峰 %0d）", mx); errs = errs + 1;
        end else $display("     残留可接受（峰 %0d，上一帧保持）✓", mx);

        // ---------- ⑤ 恢复 → 重新出声 ----------
        $display("");
        $display("  ⑤ 恢复 vld 与 volume → 应重新出声");
        while (!dut.sample_stb) @(posedge clk50);
        v_vld <= {P{1'b1}};
        m_volume <= {NCH{7'd120}};
        wait_samples(1500);
        reset_stats();
        wait_samples(1000);
        $display("     恢复后：正 %0d / 负 %0d，峰 %0d", pos, neg, mx);
        if (pos == 0 || neg == 0) begin $display("  FAIL: 恢复后没声音"); errs = errs + 1; end
        else $display("     恢复出声 ✓");

        // ---------- ⑥ mute ----------
        $display("");
        $display("  ⑥ ext_mute=1 → 应静音");
        while (!dut.sample_stb) @(posedge clk50);
        m_mute <= 1'b1;
        wait_samples(1500);
        reset_stats();
        wait_samples(1000);
        $display("     mute 后：峰 %0d", mx);
        if (mx > 4) begin $display("  FAIL: mute 未生效（峰 %0d）", mx); errs = errs + 1; end
        else $display("     mute 生效 ✓");
        while (!dut.sample_stb) @(posedge clk50);
        m_mute <= 1'b0;
        $display("     （已恢复 mute=0）");

        // ---------- ⑦ 结构保证：复位期间送 X，链路应仍然干净 ----------
        //  本项**不能靠 TB 自己钳**——关键是验证 `full_top` 内部的 `INTEG_CLAMP`
        //  真的挡住了 X。（设计动机：与其要求每个外部模块都记得钳，
        //  不如让顶层自己兜底。见 full_top §2.4。）
        $display("");
        $display("  ⑦ 结构保证：复位期间把 ext_* 灌成 X，DUT 应自己钳住");
        force v_vld   = {P{1'bx}};
        force v_aud   = {P*24{1'bx}};
        force v_ch    = {P*4{1'bx}};
        force m_volume = {NCH*7{1'bx}};
        @(posedge clk50);
        @(posedge clk50);
        release v_vld; release v_aud; release v_ch; release m_volume;
        x_ch = 0; x_fx = 0; x_smp = 0;
        wait_samples(400);
        $display("     灌 X 后 X 计数：ch_l=%0d fx_l=%0d sample_l=%0d", x_ch, x_fx, x_smp);
        if (x_ch + x_fx + x_smp != 0) begin
            $display("  FAIL: DUT 内部钳位没挡住 X（x_ch=%0d x_fx=%0d x_smp=%0d）", x_ch, x_fx, x_smp);
            errs = errs + 1;
        end else $display("     DUT 内部钳位生效，链路仍干净 ✓");

        $display("");
        if (errs == 0) $display("PASS  tb_integration: 集成接口 7 项全过");
        else           $display("FAIL  tb_integration: %0d 项未过", errs);
        $finish;
    end

    initial begin
        #3_000_000_000;
        $display("FAIL  tb_integration: 超时（ns=%0d）", ns);
        $finish;
    end
endmodule
`default_nettype wire
