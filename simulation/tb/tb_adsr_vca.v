//============================================================================
//  tb_adsr_vca —— ADSR 状态机 + VCA 定点 单元测试
//
//  验证点（documents/技术文档.md §五.1.6、硬件实现.md §五.5.3）：
//    1. 复位后 env_state = IDLE、env_value = 0
//    2. Attack：env 单调升到满量程 32767 后转 DECAY（**不是** 65535）
//    3. Attack 时长符合 attack_step = 32768/(ms×fs/1000)
//    4. Decay → SUSTAIN，稳定在 sustain_level
//    5. 无踏板松键：SUSTAIN → RELEASE → IDLE
//    6. 有踏板松键：SUSTAIN → PENDING_RELEASE；
//         踏板松开 → RELEASE；期间重新按下 → 回到 SUSTAIN
//    7. env_value 全程不越界（0 ~ 32767）
//    8. VCA：env=vel=vca=满量程时增益 ≈ 1（输出 ≈ 输入）
//    9. VCA 饱和：满量程输入不回绕
//   10. 指数曲线（adsr_curve=1）同样能到达满量程并推进状态机
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_adsr_vca;

    localparam [2:0] IDLE=3'd0, ATTACK=3'd1, DECAY=3'd2, SUSTAIN=3'd3,
                     PENDING_RELEASE=3'd4, RELEASE=3'd5;
    localparam [15:0] MAX_ENV = 16'd32767;

    integer errors = 0;
    integer err_env_oor = 0;      // env_value 越界次数

    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_async_n = 0;
    wire rst_n_sync;
    reset_sync u_rst (.clk(clk), .rst_async_n(rst_async_n), .rst_n_sync(rst_n_sync));

    reg [3:0] ph = 4'd0;
    always @(posedge clk) ph <= ph + 4'd1;
    wire sample_en = (ph == 4'd0);

    reg signed [23:0] audio_in;
    reg        gate, sustain_pedal;
    reg [1:0]  adsr_curve;
    reg [15:0] attack_step, decay_step, sustain_level, release_step;
    reg [15:0] velocity_gain, vca_gain;

    wire signed [23:0] audio_out;
    wire [15:0] env_value;
    wire [2:0]  env_state;

    adsr_vca u_adsr (
        .clk (clk), .rst_n_sync (rst_n_sync), .sample_en (sample_en),
        .slot (2'd0),
        .audio_in (audio_in), .gate (gate), .sustain_pedal (sustain_pedal),
        .adsr_curve (adsr_curve),
        .attack_step (attack_step), .decay_step (decay_step),
        .sustain_level (sustain_level), .release_step (release_step),
        .velocity_gain (velocity_gain), .vca_gain (vca_gain),
        .audio_out (audio_out), .env_value (env_value), .env_state (env_state)
    );

    //---------------- 单步驱动 ----------------
    integer nstep;

    task step;
        input g, sp;
        begin
            @(negedge clk);
            while (ph !== 4'd0) @(negedge clk);
            gate = g; sustain_pedal = sp;
            @(posedge clk);
            #1;
            nstep = nstep + 1;
            if (env_value > MAX_ENV) err_env_oor = err_env_oor + 1;
        end
    endtask

    // 跑 n 步，返回用时（步数）
    task run;
        input g, sp;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) step(g, sp);
        end
    endtask

    // 跑到条件满足或超时，返回消耗步数（-1 = 超时）
    reg cond_ok;
    task run_until_state;
        input g, sp;
        input [2:0] want;
        input integer limit;
        integer k;
        begin
            cond_ok = 0;
            for (k = 0; k < limit; k = k + 1) begin
                step(g, sp);
                if (env_state === want) begin
                    cond_ok = 1;
                    k = limit;
                end
            end
        end
    endtask

    //---------------- 初始化与复位 ----------------
    task do_reset;
        begin
            rst_async_n = 1'b0;
            repeat (5) @(posedge clk);
            rst_async_n = 1'b1;
            repeat (5) @(posedge clk);
        end
    endtask

    integer t_attack, t_decay, t_release;
    integer i;
    reg [15:0] prev_env;
    integer max_seen;

    initial begin
        // 默认参数（钢琴 125/500/0.5/300 ms）
        audio_in = 24'sd0;
        gate = 1'b0; sustain_pedal = 1'b0; adsr_curve = 2'd0;
        attack_step = 16'd5;       // 32768/(125×48) ≈ 5
        decay_step  = 16'd1;
        sustain_level = 16'd16423; // 钢琴 −6 dB
        release_step = 16'd2;
        velocity_gain = 16'd32767;
        vca_gain = 16'd32767;
        nstep = 0;

        do_reset();

        //================================================================
        // 测试 1：复位状态
        //================================================================
        if (env_state !== IDLE || env_value !== 16'd0) begin
            $display("FAIL adsr 复位: state=%0d env=%0d，应为 IDLE / 0", env_state, env_value);
            errors = errors + 1;
        end else
            $display("PASS adsr 复位: env_state=IDLE, env_value=0");

        //================================================================
        // 测试 2/3：Attack 到满量程 + 时长
        //================================================================
        // 先数出到达 DECAY 用了多少步
        t_attack = 0;
        prev_env = 16'd0;
        for (i = 0; i < 20000; i = i + 1) begin
            step(1'b1, 1'b0);
            t_attack = t_attack + 1;
            if (env_value < prev_env) begin
                $display("FAIL adsr Attack 单调性: 第 %0d 步 env 从 %0d 下降", i, prev_env);
                errors = errors + 1;
                i = 99999;
            end
            prev_env = env_value;
            if (env_state === DECAY) i = 99999;
        end
        // attack_step=5 → 32767/5 = 6554 步（上取整）
        if (t_attack < 6500 || t_attack > 6600) begin
            $display("FAIL adsr Attack 时长: %0d 步，期望约 6554 步（32767/5）", t_attack);
            errors = errors + 1;
        end else
            $display("PASS adsr Attack: %0d 步到达满量程后转 DECAY（attack_step=5）", t_attack);

        if (prev_env !== MAX_ENV) begin
            $display("FAIL adsr Attack 终值: env 峰值 %0d，应为 32767（Q1.15 满量程）", prev_env);
            errors = errors + 1;
        end else
            $display("PASS adsr Attack 终值: env = 32767（Q1.15 满量程，不是 65535）");

        //================================================================
        // 测试 4：Decay → SUSTAIN 停在 sustain_level
        //================================================================
        run_until_state(1'b1, 1'b0, SUSTAIN, 40000);
        if (!cond_ok) begin
            $display("FAIL adsr Decay: 未在限定步数内到达 SUSTAIN");
            errors = errors + 1;
        end else begin
            // 在 SUSTAIN 多待几步，确认稳定在 sustain_level
            run(1'b1, 1'b0, 20);
            if (env_value !== sustain_level) begin
                $display("FAIL adsr Sustain: 稳定值 %0d，期望 %0d", env_value, sustain_level);
                errors = errors + 1;
            end else
                $display("PASS adsr Decay→Sustain: 稳定在 sustain_level = %0d", env_value);
        end

        //================================================================
        // 测试 5：无踏板松键 SUSTAIN → RELEASE → IDLE
        //================================================================
        run_until_state(1'b0, 1'b0, RELEASE, 50);
        if (!cond_ok) begin
            $display("FAIL adsr 松键: 无踏板时未进入 RELEASE");
            errors = errors + 1;
        end else
            $display("PASS adsr 松键: 无踏板 → RELEASE");

        t_release = 0;
        for (i = 0; i < 40000; i = i + 1) begin
            step(1'b0, 1'b0);
            t_release = t_release + 1;
            if (env_state === IDLE) i = 99999;
        end
        // sustain_level=16423, release_step=2 → 约 8212 步
        if (t_release < 8100 || t_release > 8300) begin
            $display("FAIL adsr Release 时长: %0d 步，期望约 8212 步（16423/2）", t_release);
            errors = errors + 1;
        end else
            $display("PASS adsr Release: %0d 步回到 IDLE（release_step=2）", t_release);

        if (env_value !== 16'd0) begin
            $display("FAIL adsr Release 终值: env=%0d，应为 0", env_value);
            errors = errors + 1;
        end else
            $display("PASS adsr Release 终值: env = 0");

        //================================================================
        // 测试 6：延音踏板全流程
        //================================================================
        do_reset();
        run_until_state(1'b1, 1'b1, SUSTAIN, 40000);        // 按住 + 踩踏板
        if (!cond_ok) begin
            $display("FAIL adsr 踏板: 未能到达 SUSTAIN");
            errors = errors + 1;
        end

        // 松键但踏板仍踩着 → 应进 PENDING_RELEASE（而不是 RELEASE）
        run_until_state(1'b0, 1'b1, PENDING_RELEASE, 50);
        if (!cond_ok) begin
            $display("FAIL adsr 踏板: 有踏板松键未进入 PENDING_RELEASE");
            errors = errors + 1;
        end else
            $display("PASS adsr 踏板: 有踏板松键 → PENDING_RELEASE（包络保持在 sustain）");

        // 在 PENDING_RELEASE 里重新按下 → 应回 SUSTAIN
        run_until_state(1'b1, 1'b1, SUSTAIN, 50);
        if (!cond_ok) begin
            $display("FAIL adsr 踏板: PENDING_RELEASE 期间重按未回到 SUSTAIN");
            errors = errors + 1;
        end else
            $display("PASS adsr 踏板: PENDING_RELEASE 期间重按 → SUSTAIN");

        // 再松键（踏板仍踩）→ PENDING_RELEASE；这次松开踏板 → RELEASE
        run_until_state(1'b0, 1'b1, PENDING_RELEASE, 50);
        run_until_state(1'b0, 1'b0, RELEASE, 50);
        if (!cond_ok) begin
            $display("FAIL adsr 踏板: 松开踏板后未进入 RELEASE");
            errors = errors + 1;
        end else
            $display("PASS adsr 踏板: 松开踏板 → RELEASE");

        //================================================================
        // 测试 7：指数曲线也能到满量程并推进状态机
        //================================================================
        do_reset();
        adsr_curve = 2'd1;
        run_until_state(1'b1, 1'b0, DECAY, 60000);
        if (!cond_ok) begin
            $display("FAIL adsr 指数曲线: 未在限定步数内走完 ATTACK");
            errors = errors + 1;
        end else
            $display("PASS adsr 指数曲线: ATTACK 走完并转 DECAY（env 到过满量程）");
        adsr_curve = 2'd0;

        //================================================================
        // 测试 8：VCA 定点 —— env=vel=vca=满量程时增益 ≈ 1
        //================================================================
        do_reset();
        // 直接构造 env 满量程：跑完 attack
        run_until_state(1'b1, 1'b0, SUSTAIN, 40000);
        // 把 sustain_level 设成满量程，让 SUSTAIN 期间 env 保持 32767
        sustain_level = MAX_ENV;
        run(1'b1, 1'b0, 5);
        if (env_value !== MAX_ENV) begin
            $display("FAIL vca 前置: env=%0d，期望 32767", env_value);
            errors = errors + 1;
        end

        // 用一个稳定值测增益（用 step 驱动，audio_in 在 step 前设置）
        max_seen = 0;
        begin : vca_gain_check
            integer in_val, out_val, diff;
            in_val = 8388607;                      // Q1.23 正向最大
            audio_in = in_val[23:0];
            step(1'b1, 1'b0);
            out_val = audio_out;
            diff = in_val - out_val;
            // g_vt = (32767×32767)>>>15 = 32766 → 增益 = 32767×32766/2^30 ≈ 0.999908
            // 输出 ≈ 8387836，与输入差约 771 LSB（0.009%）
            if (diff < 0 || diff > 2000) begin
                $display("FAIL vca 增益: in=%0d out=%0d 差 %0d，期望 ≈ 0.99991 倍", in_val, out_val, diff);
                errors = errors + 1;
            end else
                $display("PASS vca 增益: in=%0d → out=%0d（%.5f 倍，符合 Q1.15 满量程 32767）",
                         in_val, out_val, out_val * 1.0 / in_val);

            // 负向
            in_val = -8388608;
            audio_in = in_val[23:0];
            step(1'b1, 1'b0);
            out_val = audio_out;
            diff = in_val - out_val;
            if (diff > 0 || diff < -2000) begin
                $display("FAIL vca 增益(负): in=%0d out=%0d 差 %0d", in_val, out_val, diff);
                errors = errors + 1;
            end else
                $display("PASS vca 增益(负): in=%0d → out=%0d", in_val, out_val);
        end

        //================================================================
        // 测试 9：VCA 饱和不回绕
        //    把 env 压到 0 之外的极端：vel=vca=32767, env=32767, 输入满量程
        //    已在上一步覆盖；这里验证小信号不被"归零"
        //================================================================
        begin : vca_small
            integer in_val, out_val;
            in_val = 1000;
            audio_in = in_val[23:0];
            step(1'b1, 1'b0);
            out_val = audio_out;
            if (out_val < 990 || out_val > 1001) begin
                $display("FAIL vca 小信号: in=%0d out=%0d（增益不为 1？）", in_val, out_val);
                errors = errors + 1;
            end else
                $display("PASS vca 小信号: in=%0d → out=%0d（无额外衰减/回绕）", in_val, out_val);
        end

        //================================================================
        // 测试 10：全程 env_value 不越界
        //================================================================
        if (err_env_oor != 0) begin
            $display("FAIL adsr env 越界: 有 %0d 步 env_value > 32767", err_env_oor);
            errors = errors + 1;
        end else
            $display("PASS adsr env 量程: 全程 %0d 步 env_value 均在 [0, 32767]", nstep);

        //================================================================
        if (errors == 0) $display("PASS  tb_adsr_vca");
        else             $display("FAIL  tb_adsr_vca: %0d 项", errors);
        $finish;
    end

    initial begin
        #500_000_000;
        $display("FAIL tb_adsr_vca: 仿真超时");
        $finish;
    end

endmodule

`default_nettype wire
