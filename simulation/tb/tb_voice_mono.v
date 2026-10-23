//============================================================================
//  tb_voice_mono —— 单声部集成测试（2 泳道 + 共享波表取数器）
//
//  用 P = 2 跑，既验证 wave_fetch 的「时隙内串行读 + 寄存器缓存」，
//  又验证两条泳道各自寻址互不干扰，再跑通 DDS → SVF → VCA 整链。
//
//  验证点：
//    1. wave_fetch 串行读：rdy 后 tab_n / tab_n1 等于波表中对应地址的内容
//    2. 多泳道隔离：泳道 0 用槽 0、泳道 1 用槽 1，各自取到自己的数据
//    3. 槽内回绕：索引 2047 的相邻点取本槽首点（不是下一槽）
//    4. 整链：DDS → SVF → VCA 输出非平凡波形，幅度量级正确
//    5. 包络：gate 按住后 env 升到满量程，声音幅度随之变化
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_voice_mono;

    localparam integer P    = 2;
    localparam integer DEPTH = 16384;
    localparam integer NPT   = 2048;

    integer errors = 0;

    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_async_n = 0;

    reg [3:0] ph = 4'd0;
    always @(posedge clk) ph <= ph + 4'd1;
    wire sample_en = (ph == 4'd0);

    //---------------- 每泳道参数 ----------------
    reg [31:0] phase_inc     [0:P-1];
    reg [1:0]  wave_sel      [0:P-1];
    reg [2:0]  timbre_slot   [0:P-1];
    reg [15:0] f_coeff       [0:P-1];
    reg [15:0] q_coeff       [0:P-1];
    reg [1:0]  filter_type   [0:P-1];
    reg        gate          [0:P-1];
    reg        sustain_pedal [0:P-1];
    reg [1:0]  adsr_curve    [0:P-1];
    reg [15:0] attack_step   [0:P-1];
    reg [15:0] decay_step    [0:P-1];
    reg [15:0] sustain_level [0:P-1];
    reg [15:0] release_step  [0:P-1];
    reg [15:0] velocity_gain [0:P-1];
    reg [15:0] vca_gain      [0:P-1];

    //---------------- 展平信号 ----------------
    wire [P*14-1:0] addr_n_flat, addr_n1_flat;
    wire [P*16-1:0] tab_n_flat, tab_n1_flat;
    wire            fetch_rdy;

    wire signed [23:0] voice_out [0:P-1];
    wire [31:0]        phase_acc [0:P-1];
    wire [15:0]        env_value [0:P-1];
    wire [2:0]         env_state [0:P-1];
    wire signed [31:0] fic1      [0:P-1];
    wire signed [31:0] fic2      [0:P-1];

    //---------------- 复位同步（整个测试平台共用一份） ----------------
    wire rst_n_sync;
    reset_sync u_rst_fetch (.clk(clk), .rst_async_n(rst_async_n), .rst_n_sync(rst_n_sync));

    //---------------- 共享波表取数器（全局 1 份） ----------------
    wave_fetch #(.P(P)) u_fetch (
        .clk           (clk),
        .rst_n_sync    (rst_n_sync),
        .sample_en     (sample_en),
        .addr_n_flat   (addr_n_flat),
        .addr_n1_flat  (addr_n1_flat),
        .rdy           (fetch_rdy),
        .tab_n_flat    (tab_n_flat),
        .tab_n1_flat   (tab_n1_flat)
    );

    //---------------- P 条泳道 ----------------
    genvar gi;
    generate
        for (gi = 0; gi < P; gi = gi + 1) begin : g_lane
            voice_mono u_voice (
                .clk           (clk),
                .rst_async_n   (rst_async_n),
                .sample_en     (sample_en),
                .slot         (2'd0),
                .phase_inc     (phase_inc[gi]),
                .wave_sel      (wave_sel[gi]),
                .timbre_slot   (timbre_slot[gi]),
                .f_coeff       (f_coeff[gi]),
                .q_coeff       (q_coeff[gi]),
                .filter_type   (filter_type[gi]),
                .gate          (gate[gi]),
                .sustain_pedal (sustain_pedal[gi]),
                .adsr_curve    (adsr_curve[gi]),
                .attack_step   (attack_step[gi]),
                .decay_step    (decay_step[gi]),
                .sustain_level (sustain_level[gi]),
                .release_step  (release_step[gi]),
                .velocity_gain (velocity_gain[gi]),
                .vca_gain      (vca_gain[gi]),
                .tab_n         (tab_n_flat [gi*16 +: 16]),
                .tab_n1        (tab_n1_flat[gi*16 +: 16]),
                .samples_rdy   (fetch_rdy),
                .rom_addr_n    (addr_n_flat [gi*14 +: 14]),
                .rom_addr_n1   (addr_n1_flat[gi*14 +: 14]),
                .voice_out     (voice_out[gi]),
                .phase_acc     (phase_acc[gi]),
                .env_value     (env_value[gi]),
                .env_state     (env_state[gi]),
                .filter_ic1    (fic1[gi]),
                .filter_ic2    (fic2[gi])
            );
        end
    endgenerate

    //========================================================================
    //  合成波表：槽 0 正弦、槽 1 常量 12345、槽 2 斜坡（用于回绕）
    //========================================================================
    integer i;
    real    ang;
    initial begin
        for (i = 0; i < NPT; i = i + 1) begin
            ang = 2.0 * 3.14159265358979 * i / NPT;
            u_fetch.u_rom.mem[i] = $rtoi(32767.0 * $sin(ang));
        end
        for (i = NPT; i < 2*NPT; i = i + 1)
            u_fetch.u_rom.mem[i] = 16'sd12345;
        for (i = 2*NPT; i < 3*NPT; i = i + 1)
            u_fetch.u_rom.mem[i] = $signed(i - 2*NPT) - 16'sd1024;
        for (i = 3*NPT; i < DEPTH; i = i + 1)
            u_fetch.u_rom.mem[i] = 16'sd0;
    end

    //========================================================================
    //  驱动
    //========================================================================
    integer k;
    integer guard;

    task do_slot;
        begin
            @(negedge clk);
            while (ph !== 4'd0) @(negedge clk);
            @(posedge clk);                 // sample_en 生效这一沿
            guard = 0;
            while (fetch_rdy !== 1'b1 && guard < 200) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (guard >= 200) begin
                $display("FAIL wave_fetch: 等待 rdy 超时");
                errors = errors + 1;
            end
            #1;                             // rdy 高时 tab_*_flat 有效
        end
    endtask

    task pdefaults;
        begin
            for (k = 0; k < P; k = k + 1) begin
                phase_inc[k]     = 32'd0;
                wave_sel[k]      = 2'd0;
                timbre_slot[k]   = k[2:0];
                f_coeff[k]       = 16'd4287;      // fc ≈ 1 kHz
                q_coeff[k]       = 16'd16384;     // Q = 2
                filter_type[k]   = 2'd0;          // LP
                gate[k]          = 1'b0;
                sustain_pedal[k] = 1'b0;
                adsr_curve[k]    = 2'd0;
                attack_step[k]   = 16'd5;
                decay_step[k]    = 16'd1;
                sustain_level[k] = 16'd32767;
                release_step[k]  = 16'd2;
                velocity_gain[k] = 16'd32767;
                vca_gain[k]      = 16'd32767;
            end
        end
    endtask

    task do_reset;
        begin
            rst_async_n = 1'b0;
            repeat (5) @(posedge clk);
            rst_async_n = 1'b1;
            repeat (5) @(posedge clk);
        end
    endtask

    //========================================================================
    integer lane, a0, a1;
    integer exp_n, exp_n1, got_n, got_n1;
    integer peak [0:P-1];
    integer envmax [0:P-1];

    initial begin
        pdefaults();
        do_reset();

        //====================================================================
        // 测试 1：串行读 + 多泳道隔离
        //   两条泳道 phase_inc = 0 → phase_acc 恒 0 → idx = 0, frac = 0
        //   泳道 0 → 槽 0：tab_n = sine[0] = 0,      tab_n1 = sine[1]
        //   泳道 1 → 槽 1：tab_n = 12345,            tab_n1 = 12345
        //====================================================================
        for (k = 0; k < P; k = k + 1) phase_inc[k] = 32'd0;
        do_slot();

        for (k = 0; k < P; k = k + 1) begin
            got_n  = $signed(tab_n_flat [k*16 +: 16]);
            got_n1 = $signed(tab_n1_flat[k*16 +: 16]);
            if (k == 0) begin
                exp_n  = $signed(u_fetch.u_rom.mem[0]);
                exp_n1 = $signed(u_fetch.u_rom.mem[1]);
            end else begin
                exp_n  = $signed(u_fetch.u_rom.mem[NPT + 0]);
                exp_n1 = $signed(u_fetch.u_rom.mem[NPT + 1]);
            end
            if (got_n !== exp_n || got_n1 !== exp_n1) begin
                $display("FAIL wave_fetch 泳道%0d: tab_n=%0d(期望%0d) tab_n1=%0d(期望%0d)",
                         k, got_n, exp_n, got_n1, exp_n1);
                errors = errors + 1;
            end else
                $display("PASS wave_fetch 泳道%0d: 槽%0d 取到 tab_n=%0d tab_n1=%0d（独立寻址正确）",
                         k, k, got_n, got_n1);
        end

        //====================================================================
        // 测试 2：槽内回绕 —— 把泳道 1 的相位强制到 idx=2047，并改用**斜坡槽 2**
        //   槽 2：rom[2·2048+2047] = +1023，rom[2·2048+0] = −1024，rom[3·2048+0] = 0
        //   正确（槽内回绕）：tab_n = +1023, tab_n1 = −1024
        //   错误（跨到槽 3）  ：tab_n1 = 0 —— 本用例能区分这两种
        //====================================================================
        do_reset();
        g_lane[1].u_voice.u_dds.phase_r[0] = 32'd2047 << 21;   // 方案 A：phase_acc 已是 wire，改写 slot0 的状态    // idx = 2047, frac = 0
        for (k = 0; k < P; k = k + 1) phase_inc[k] = 32'd0;
        timbre_slot[1] = 3'd2;                                 // 斜坡槽
        do_slot();

        got_n  = $signed(tab_n_flat [1*16 +: 16]);
        got_n1 = $signed(tab_n1_flat[1*16 +: 16]);
        exp_n  = $signed(u_fetch.u_rom.mem[2*NPT + 2047]);
        exp_n1 = $signed(u_fetch.u_rom.mem[2*NPT + 0]);        // 回绕到**本槽**首点
        if (got_n !== exp_n || got_n1 !== exp_n1) begin
            $display("FAIL wave_fetch 回绕: tab_n=%0d(期望%0d) tab_n1=%0d(期望%0d)",
                     got_n, exp_n, got_n1, exp_n1);
            errors = errors + 1;
        end else if (got_n1 === $signed(u_fetch.u_rom.mem[3*NPT + 0])) begin
            $display("FAIL wave_fetch 回绕: tab_n1 取到了下一槽首点 %0d，本用例无区分力",
                     got_n1);
            errors = errors + 1;
        end else
            $display("PASS wave_fetch 回绕: idx=2047 → tab_n=%0d tab_n1=%0d（本槽末点→本槽首点，未跨到槽 3 的 %0d）",
                     got_n, got_n1, $signed(u_fetch.u_rom.mem[3*NPT + 0]));
        timbre_slot[1] = 3'd1;

        //====================================================================
        // 测试 3：整链 —— DDS → SVF → VCA
        //   跑 3000 个采样，看输出是否为非平凡波形、幅度是否合理
        //====================================================================
        do_reset();
        pdefaults();
        for (k = 0; k < P; k = k + 1) begin
            timbre_slot[k]   = 3'd0;               // 都用正弦槽
            phase_inc[k]     = 32'd89478485;       // ≈1000 Hz @48k
            gate[k]          = 1'b1;
            // attack_step=5 需要 6554 拍才爬到满量程，本用例只跑 3000 拍，
            // 故把 attack 调快（200/拍 → 164 拍到顶）以便在窗口内看到满包络
            attack_step[k]   = 16'd200;
            f_coeff[k]       = 16'd32767;          // fc 抬高到 ≈8 kHz，1 kHz 近乎全通
            velocity_gain[k] = 16'd16384;          // 力度 0.5，避免叠加谐振后顶到满量程
            peak[k]          = 0;
            envmax[k]        = 0;
        end

        for (i = 0; i < 3000; i = i + 1) begin
            do_slot();
            for (k = 0; k < P; k = k + 1) begin
                if (voice_out[k] > peak[k]) peak[k] = voice_out[k];
                if (-voice_out[k] > peak[k]) peak[k] = -voice_out[k];
                if (env_value[k] > envmax[k]) envmax[k] = env_value[k];
            end
        end

        for (k = 0; k < P; k = k + 1) begin
            if (envmax[k] !== 16'd32767) begin
                $display("FAIL 整链 泳道%0d: env 峰值 %0d，期望 32767", k, envmax[k]);
                errors = errors + 1;
            end else
                $display("PASS 整链 泳道%0d: env 升到满量程 32767", k);

            // DDS 幅度 ≈ 8388352（插值后 100% 满量程）
            // × 力度增益 0.5（velocity_gain=16384, vca_gain=32767 → g_vt≈16383）
            // × LP 在 1kHz / 截止 8kHz 的增益 ≈ 1.02
            // ≈ 4278000 ≈ 51% 满量程。给一个 45%~58% 的区间。
            if (peak[k] < 8388608 * 45 / 100 || peak[k] > 8388608 * 58 / 100) begin
                $display("FAIL 整链 泳道%0d: 输出峰值 %0d（%.1f%%），期望约 51%% 满量程",
                         k, peak[k], 100.0 * peak[k] / 8388608.0);
                errors = errors + 1;
            end else
                $display("PASS 整链 泳道%0d: 输出峰值 %0d（%.1f%% 满量程，期望约 51%%）",
                         k, peak[k], 100.0 * peak[k] / 8388608.0);
        end

        // 两条泳道参数完全相同，输出应当逐位一致（共享取数器未串扰）
        if (voice_out[0] !== voice_out[1]) begin
            $display("FAIL 整链 串扰: 泳道0=%0d 泳道1=%0d（参数相同却不一致）",
                     voice_out[0], voice_out[1]);
            errors = errors + 1;
        end else
            $display("PASS 整链 无串扰: 两泳道参数相同时输出逐位一致（%0d）", voice_out[0]);

        //====================================================================
        // 测试 4：包络真的在起作用 —— 松键后输出应衰减到 0
        //====================================================================
        for (k = 0; k < P; k = k + 1) gate[k] = 1'b0;
        for (i = 0; i < 30000; i = i + 1) do_slot();      // release 需 32767/2 ≈ 16383 步
        for (k = 0; k < P; k = k + 1) begin
            if (env_value[k] !== 16'd0) begin
                $display("FAIL 整链 释放: 泳道%0d env=%0d，应为 0", k, env_value[k]);
                errors = errors + 1;
            end else if (voice_out[k] !== 24'sd0) begin
                $display("FAIL 整链 释放: 泳道%0d 包络归零但输出仍为 %0d", k, voice_out[k]);
                errors = errors + 1;
            end else
                $display("PASS 整链 释放: 泳道%0d 包络归零后输出为 0", k);
        end

        //====================================================================
        if (errors == 0) $display("PASS  tb_voice_mono");
        else             $display("FAIL  tb_voice_mono: %0d 项", errors);
        $finish;
    end

    initial begin
        #2_000_000_000;
        $display("FAIL tb_voice_mono: 仿真超时");
        $finish;
    end

endmodule

`default_nettype wire
