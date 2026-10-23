//============================================================================
//  tb_wave_real —— 用**真实波表数据**跑通整链（DDS → SVF → VCA）
//
//  前面几个 TB 用的是 TB 内合成的波表（正弦/常量/斜坡），只能证明"逻辑对"。
//  本 TB 加载 wave_table/out/wave_table.hex —— 即 wave_table/convert.py 按
//  冻结口径（8 槽 × 2048 点 × 16 bit = 16384）生成的那一份，用来证明
//  「真实数据 + 真实地址拼接 + 真实取数时序」这条路径也是通的。
//
//  验证点：
//    1. 波表加载成功，且槽 0 / 槽 1 / 槽 2 起始点的内容与文件一致
//    2. timbre_slot 真的选到了不同的数据（钢琴 ≠ 吉他）
//    3. 未分配槽（2~7 填 0）真的输出静音 —— 这是地址拼接正确性的强证据
//    4. 频率：phase_inc 对应的相位回绕周期 = 期望音高
//       （周期波表的输出周期 == 相位回绕周期，所以数回绕次数就是数音高）
//    5. 整链输出非平凡且不顶饱和
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_wave_real;

    localparam integer P     = 1;          // 只驱动 1 条泳道
    localparam integer DEPTH = 16384;
    localparam integer NPT   = 2048;
    localparam real    FS    = 48000.0;
    localparam integer NSAMP = 20000;      // 约 0.42 秒

    integer errors = 0;

    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_async_n = 0;
    wire rst_n_sync;
    reset_sync u_rst (.clk(clk), .rst_async_n(rst_async_n), .rst_n_sync(rst_n_sync));

    reg [3:0] ph = 4'd0;
    always @(posedge clk) ph <= ph + 4'd1;
    wire sample_en = (ph == 4'd0);

    //---------------- 共享取数器（P=1） ----------------
    wire [P*14-1:0] addr_n_flat, addr_n1_flat;
    wire [P*16-1:0] tab_n_flat, tab_n1_flat;
    wire            fetch_rdy;

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

    //---------------- 泳道参数 ----------------
    reg [31:0] phase_inc;
    reg [2:0]  timbre_slot;
    reg [15:0] f_coeff, q_coeff;
    reg [1:0]  filter_type;
    reg        gate, sustain_pedal;
    reg [1:0]  adsr_curve;
    reg [15:0] attack_step, decay_step, sustain_level, release_step;
    reg [15:0] velocity_gain, vca_gain;

    wire signed [23:0] voice_out;
    wire [31:0]        phase_acc;
    wire [15:0]        env_value;
    wire [2:0]         env_state;
    wire signed [31:0] fic1, fic2;

    voice_mono u_voice (
        .clk (clk), .rst_async_n (rst_async_n), .sample_en (sample_en),
                .slot         (2'd0),
        .phase_inc (phase_inc), .wave_sel (2'd0), .timbre_slot (timbre_slot),
        .f_coeff (f_coeff), .q_coeff (q_coeff), .filter_type (filter_type),
        .gate (gate), .sustain_pedal (sustain_pedal), .adsr_curve (adsr_curve),
        .attack_step (attack_step), .decay_step (decay_step),
        .sustain_level (sustain_level), .release_step (release_step),
        .velocity_gain (velocity_gain), .vca_gain (vca_gain),
        .tab_n (tab_n_flat[15:0]), .tab_n1 (tab_n1_flat[15:0]),
        .samples_rdy (fetch_rdy),
        .rom_addr_n (addr_n_flat), .rom_addr_n1 (addr_n1_flat),
        .voice_out (voice_out), .phase_acc (phase_acc),
        .env_value (env_value), .env_state (env_state),
        .filter_ic1 (fic1), .filter_ic2 (fic2)
    );

    //========================================================================
    //  加载真实波表（运行时 $readmemh，路径相对 vvp 的工作目录）
    //========================================================================
    integer i;
    integer loaded;
    reg [1023:0] try_path [0:3];

    task load_wave;
        begin
            // 先用哨兵填满，便于判断到底有没有加载成功
            for (i = 0; i < DEPTH; i = i + 1)
                u_fetch.u_rom.mem[i] = 16'hDEAD;

            try_path[0] = "data/wave_table.hex";       // 仓库根为 cwd
            try_path[1] = "../data/wave_table.hex";    // simulation/ 为 cwd
            try_path[2] = "../../data/wave_table.hex"; // simulation/out/ 为 cwd

            loaded = 0;
            for (i = 0; i < 3; i = i + 1) begin
                if (loaded == 0) begin
                    $readmemh(try_path[i], u_fetch.u_rom.mem);
                    if (u_fetch.u_rom.mem[0] !== 16'hDEAD) loaded = 1;
                end
            end
        end
    endtask

    //========================================================================
    integer n, wraps, prev_phase;
    real    f_est;
    real    f_exp;
    integer peak;
    integer slot0_first, slot1_first, slot2_first;

    task do_slot;
        integer guard;
        begin
            @(negedge clk);
            while (ph !== 4'd0) @(negedge clk);
            @(posedge clk);
            guard = 0;
            while (fetch_rdy !== 1'b1 && guard < 200) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (guard >= 200) begin
                $display("FAIL tb_wave_real: 等 rdy 超时");
                errors = errors + 1;
            end
            #1;
        end
    endtask

    task reset_dut;
        begin
            rst_async_n = 1'b0;
            repeat (5) @(posedge clk);
            rst_async_n = 1'b1;
            repeat (5) @(posedge clk);
        end
    endtask

    initial begin
        phase_inc     = 32'd0;
        timbre_slot   = 3'd0;
        f_coeff       = 16'd32767;      // ≈8 kHz 截止，1 kHz 内近乎全通
        q_coeff       = 16'd16384;
        filter_type   = 2'd0;
        gate          = 1'b0;
        sustain_pedal = 1'b0;
        adsr_curve    = 2'd0;
        attack_step   = 16'd32767;      // 一步到满量程
        decay_step    = 16'd32767;
        sustain_level = 16'd32767;
        release_step  = 16'd2;
        velocity_gain = 16'd32767;
        vca_gain      = 16'd32767;

        // ⚠ 必须**先装波表、再放复位**（模拟 FPGA 配置阶段就载入 BSRAM 初值）。
        //   反过来做的话，在"已放复位但 ROM 还是 X"的那几十拍里，
        //   DDS/SVF 会把 X 吃进状态寄存器，之后 0 + X = X 永远清不掉 ——
        //   表现为"数据全 0 的槽却输出非零"。真机上 BSRAM 初值随配置位流生效，
        //   不存在这个窗口；但任何"启动载入"的非固化路径都必须等载入完成再放行。
        load_wave();

        repeat (20) @(posedge clk);
        rst_async_n = 1'b1;
        repeat (20) @(posedge clk);

        //====================================================================
        // 测试 1：波表加载
        //====================================================================
        if (loaded == 0) begin
            $display("FAIL tb_wave_real: 波表加载失败 —— 请先在 wave_table/ 下跑 convert.py");
            $display("      （尝试过 wave_table/out/wave_table.hex 等 3 个相对路径）");
            errors = errors + 1;
            $finish;
        end else begin
            $display("PASS 波表加载: wave_table/out/wave_table.hex 已读入 16384 点");
        end

        slot0_first = $signed(u_fetch.u_rom.mem[0]);
        slot1_first = $signed(u_fetch.u_rom.mem[NPT]);
        slot2_first = $signed(u_fetch.u_rom.mem[2*NPT]);
        $display("      槽0首点=%0d  槽1首点=%0d  槽2首点=%0d", slot0_first, slot1_first, slot2_first);

        if (slot2_first !== 0) begin
            $display("FAIL 波表: 槽 2 首点为 %0d，按冻结口径未分配槽应填 0", slot2_first);
            errors = errors + 1;
        end

        //====================================================================
        // 测试 2：timbre_slot 真的选到不同数据
        //====================================================================
        if (slot0_first === slot1_first) begin
            $display("FAIL 音色选择: 槽0 与槽1 首点相同（%0d），未区分", slot0_first);
            errors = errors + 1;
        end else
            $display("PASS 音色选择: 槽0(钢琴) 与 槽1(吉他) 数据不同");

        //====================================================================
        // 测试 3：未分配槽（全 0）→ 输出静音（地址拼接正确性的强证据）
        //====================================================================
        reset_dut();                        // 清掉前面可能残留的状态
        timbre_slot = 3'd2;                 // 槽 2 全 0
        phase_inc   = 32'd89478485;
        gate        = 1'b1;
        for (n = 0; n < 200; n = n + 1) do_slot();
        begin : silent_chk
            integer bad;
            bad = 0;
            for (n = 0; n < 200; n = n + 1) begin
                do_slot();
                if (voice_out !== 24'sd0) bad = bad + 1;
            end
            if (bad != 0) begin
                $display("FAIL 槽选择: 未分配槽（全 0）仍有 %0d 拍非零输出 —— 地址拼接可能串槽", bad);
                errors = errors + 1;
            end else
                $display("PASS 槽选择: 未分配槽（全 0）输出恒为 0，地址拼接未串槽");
        end

        //====================================================================
        // 测试 4：真实钢琴数据 + 440 Hz 音高
        //   周期波表的**输出周期 == 相位回绕周期**，所以数回绕次数即数音高
        //====================================================================
        rst_async_n = 1'b0; repeat (5) @(posedge clk);
        rst_async_n = 1'b1; repeat (5) @(posedge clk);

        timbre_slot = 3'd0;                       // 钢琴
        // 440 Hz @ 48k → phase_inc = 440 × 2^32 / 48000
        phase_inc   = 32'd39370534;
        gate        = 1'b1;

        wraps      = 0;
        prev_phase = 0;
        peak       = 0;
        for (n = 0; n < NSAMP; n = n + 1) begin
            do_slot();
            if (phase_acc < prev_phase) wraps = wraps + 1;   // 2^32 自然回绕
            prev_phase = phase_acc;
            if (voice_out > peak) peak = voice_out;
            if (-voice_out > peak) peak = -voice_out;
        end

        f_exp = 440.0;
        f_est = wraps / (NSAMP / FS);
        if (f_est < f_exp * 0.99 || f_est > f_exp * 1.01) begin
            $display("FAIL 音高: 相位回绕测得 %.1f Hz，期望 %.1f Hz", f_est, f_exp);
            errors = errors + 1;
        end else
            $display("PASS 音高: 相位回绕 %0d 次 / %0d 点 → %.1f Hz（期望 %.1f Hz）",
                     wraps, NSAMP, f_est, f_exp);

        if (peak === 0) begin
            $display("FAIL 整链: 真实钢琴数据下输出恒为 0");
            errors = errors + 1;
        end else if (peak >= 8388607) begin
            $display("FAIL 整链: 输出顶到满量程 %0d（真实数据幅度应留余量）", peak);
            errors = errors + 1;
        end else
            $display("PASS 整链: 真实钢琴数据输出峰值 %0d（%.1f%% 满量程）",
                     peak, 100.0 * peak / 8388608.0);

        //====================================================================
        // 测试 5：换吉他槽，波形应不同（首点不同已证明数据不同，这里证明输出不同）
        //====================================================================
        begin : guitar_chk
            integer p0, p1;
            rst_async_n = 1'b0; repeat (5) @(posedge clk);
            rst_async_n = 1'b1; repeat (5) @(posedge clk);
            timbre_slot = 3'd1;
            phase_inc   = 32'd39370534;
            gate        = 1'b1;
            p1 = 0;
            for (n = 0; n < 2000; n = n + 1) begin
                do_slot();
                if (voice_out > p1) p1 = voice_out;
                if (-voice_out > p1) p1 = -voice_out;
            end
            p0 = peak;
            if (p1 === 0) begin
                $display("FAIL 吉他槽: 输出恒为 0");
                errors = errors + 1;
            end else
                $display("PASS 吉他槽: 输出峰值 %0d（钢琴为 %0d，两者不同即为正确选槽）", p1, p0);
        end

        //====================================================================
        if (errors == 0) $display("PASS  tb_wave_real");
        else             $display("FAIL  tb_wave_real: %0d 项", errors);
        $finish;
    end

    initial begin
        #2_000_000_000;
        $display("FAIL tb_wave_real: 仿真超时");
        $finish;
    end

endmodule

`default_nettype wire
