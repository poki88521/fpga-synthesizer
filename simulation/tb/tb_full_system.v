//============================================================================
//  tb_full_system —— 全系统端到端验证（唯一"真·集成"测试）
//
//  验证：**发一条 MIDI Note On → 喇叭端出声音**
//
//     tb  ──midi_rx[0]──▶ full_system ──HP_DIN/WS/BCK──▶ 统计
//              (31250 baud)     ├─ sched_subsystem
//                               ├─ voice_mono × 8
//                               └─ full_top
//
//  这条路径覆盖三边接口的全部关键点：
//    · MIDI 位定时（1573 拍/bit）
//    · 调度层分配 → pf_gate / pf_phase_inc
//    · 单声部层 DDS+SVF+ADSR/VCA → voice_aud
//    · 通道层 → 效果器 → 主混音 → 主输出 → PT8211 帧
//
//  ⚠ 仿真参数：USE_PLL=0（50 MHz 直连）+ POR_BITS=8/PA_DELAY=8 缩短等待。
//     上板用 USE_PLL=1 / POR_BITS=22。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_full_system;
    localparam integer P    = 8;
    localparam integer NCH  = 16;
    localparam integer HALF = 10;         // 50 MHz → 半周期 10 ns
    localparam integer BIT_TICK = 1573;   // 与 midi_parse 一致

    reg clk50 = 0, clk12288 = 0;
    always #HALF clk50    = ~clk50;
    always #HALF clk12288 = ~clk12288;

    wire HP_BCK, HP_WS, HP_DIN, PA_EN;

    reg [3:0] midi_rx = 4'hF;             // 空闲线 = 1

    full_system #(
        .USE_PLL(0), .P(P), .G(4), .NCH(NCH), .STRIDE(32),
        .PA_DELAY(8), .POR_BITS(8),
        .TEST_MODE_DEFAULT(0),            // 关测试模式：走真实 MIDI→发声 通路
        .WAVE_INIT_FILE("data/wave_table.hex")  // ⚠ 相对**仿真工作目录**；不载入则 ROM 未初始化 → 全 X
    ) dut (
        .clk50(clk50), .clk12288(clk12288),
        .midi_rx(midi_rx),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN)
    );

    // ---------------- MIDI 发送（31250 baud = 1573 拍/bit）----------------
    task midi_byte;
        input [7:0] b;
        integer k;
        begin
            midi_rx[0] = 1'b0;                     // 起始位
            #(BIT_TICK * 20);                      // 1 bit = 1573 拍 × 20 ns
            for (k = 0; k < 8; k = k + 1) begin
                midi_rx[0] = b[k];                 // LSB 先出
                #(BIT_TICK * 20);
            end
            midi_rx[0] = 1'b1;                     // 停止位
            #(BIT_TICK * 20);
        end
    endtask

    // ---------------- 从 HP_DIN/WS/BCK 解码出采样（复用 PT8211 LSBJ 格式）-----
    //  WS 高 = 左声道；MSB 先出；DIN 在 BCK 上升沿被从机采样
    reg  [15:0] sh;
    reg  [4:0]  bcnt = 0;
    reg         ws_d  = 0;
    integer     samp_l = 0, samp_r = 0;
    integer     n_l = 0, n_r = 0;
    integer     l_min = 1<<20, l_max = -(1<<20);
    integer     r_min = 1<<20, r_max = -(1<<20);
    integer     l_nz = 0, r_nz = 0;
    //  ⚠ 2026-10-13 新增：左声道峰峰值下限。
    //     原来只查"全零"，而 ±1 的抖动就能骗过它（实测 vel=20/127 都得到 l_max=0、l_min=-1）。
    localparam  AMP_MIN = 64;
    integer     p2p_l;

    //  ⚠ 不要在 TB 里按 BCK 边沿解码（早先那样写得到"98 样本/2ms、右声道 0 个"的
    //     假结果 —— 边沿计数与 WS 半帧不对齐）。直接读**设计内部**的每采样输出：
    //     `u_full_top.sample_l/sample_r` 就是送往 PT8211 的那两个字。
    integer sx_l = 0, sx_r = 0;
    //  ⚠ 2026-10-13 加：跨整个观察窗的**最大值**跟踪。
    //     因为 pf_* / rs_* 都是**时隙相关**的（泳道 0 在不同时隙对应声部 0/8/16/24），
    //     抓某一瞬间的值会误导（会正好落在 phase_inc=0 的那个时隙上）。
    integer max_pf_inc   = 0;
    integer max_rs_phacc = 0;
    integer max_rs_env   = 0;
    integer rom_rdy_cnt  = 0;
    always @(posedge clk50) if (dut.rst_n_sync) begin
        if (dut.pf_phase_inc[31:0]   > max_pf_inc)   max_pf_inc   = dut.pf_phase_inc[31:0];
        if (dut.rs_phase_acc[31:0]   > max_rs_phacc) max_rs_phacc = dut.rs_phase_acc[31:0];
        if ($signed(dut.rs_env_value[15:0]) > max_rs_env) max_rs_env = $signed(dut.rs_env_value[15:0]);
        if (dut.rom_rdy) rom_rdy_cnt = rom_rdy_cnt + 1;
    end

    //  单声部层与通道层的幅度统计（定位"声音在哪一级变小"）
    integer va_min = 1<<30, va_max = -(1<<30);
    integer chv_cnt = 0, svld_cnt = 0, bufwr = 0;
    integer chl_min = 1<<30, chl_max = -(1<<30);
    always @(posedge clk50) if (dut.rst_n_sync) begin
        if (dut.u_full_top.ch_vld) begin
            chv_cnt = chv_cnt + 1;
            if ($signed(dut.u_full_top.ch_l) < chl_min) chl_min = $signed(dut.u_full_top.ch_l);
            if ($signed(dut.u_full_top.ch_l) > chl_max) chl_max = $signed(dut.u_full_top.ch_l);
        end
        if (dut.u_full_top.slot_vld) svld_cnt = svld_cnt + 1;
        if (dut.u_full_top.u_chan.u_buf.slot_vld) bufwr = bufwr + 1;  // 用 slot_vld 代表写拍
    end
    integer mx_min = 1<<30, mx_max = -(1<<30);
    integer en_min = 1<<30, en_max = -(1<<30);
    always @(posedge clk50) if (dut.rst_n_sync) begin
        if ($signed(dut.voice_aud[23:0]) < va_min) va_min = $signed(dut.voice_aud[23:0]);
        if ($signed(dut.voice_aud[23:0]) > va_max) va_max = $signed(dut.voice_aud[23:0]);
        if ($signed(dut.u_full_top.mx_l) < mx_min) mx_min = $signed(dut.u_full_top.mx_l);
        if ($signed(dut.u_full_top.mx_l) > mx_max) mx_max = $signed(dut.u_full_top.mx_l);
        if ($signed(dut.rs_env_value[15:0]) < en_min) en_min = $signed(dut.rs_env_value[15:0]);
        if ($signed(dut.rs_env_value[15:0]) > en_max) en_max = $signed(dut.rs_env_value[15:0]);
    end
    always @(posedge clk50) begin
        if (dut.u_full_top.sample_stb && dut.rst_n_sync) begin
            n_l = n_l + 1;
            if (dut.u_full_top.sample_l === 16'bx) sx_l = sx_l + 1;
            else begin
                samp_l = $signed(dut.u_full_top.sample_l);
                if (samp_l != 0) l_nz = l_nz + 1;
                if (samp_l < l_min) l_min = samp_l;
                if (samp_l > l_max) l_max = samp_l;
            end
            n_r = n_r + 1;
            if (dut.u_full_top.sample_r === 16'bx) sx_r = sx_r + 1;
            else begin
                samp_r = $signed(dut.u_full_top.sample_r);
                if (samp_r != 0) r_nz = r_nz + 1;
                if (samp_r < r_min) r_min = samp_r;
                if (samp_r > r_max) r_max = samp_r;
            end
        end
    end

    //  音高验证：对 sample_l 做过零计数（Note On 之后 100 ms 窗口）
    integer zc = 0, zc_start = -1, zc_end = -1, prev_pos = -1;
    reg     counting = 0;
    always @(posedge clk50) if (dut.u_full_top.sample_stb && dut.rst_n_sync) begin
        if (counting && dut.u_full_top.sample_l !== 16'bx) begin
            if (($signed(dut.u_full_top.sample_l) >= 0) != (prev_pos == 1)) begin
                if (prev_pos >= 0) zc = zc + 1;
                prev_pos = ($signed(dut.u_full_top.sample_l) >= 0) ? 1 : 0;
            end
            if (zc_start < 0) zc_start = n_l;
            zc_end = n_l;
        end
    end

    integer x_cnt = 0;
    always @(posedge clk50) begin
        if (HP_DIN === 1'bx) x_cnt = x_cnt + 1;
    end

    integer errs = 0;
    integer t0;

    initial begin
        $display("=== tb_full_system：端到端（MIDI Note On → 出声音）===");
        wait (dut.rst_n_sync === 1'b1);
        $display("  复位释放 ✓（rst_n_sync=1）");
        #2000;

        // 等 pa_en 起来（PA_DELAY=8 → 256 拍）
        wait (PA_EN === 1'b1);
        $display("  PA_EN 已拉高 ✓");

        // ---------- ① 发 Note On（通道 0，音高 60，力度 100）----------
        $display("");
        $display("  ① 发 MIDI：Note On ch0 note=60 vel=100");
        @(posedge clk50);
        midi_byte(8'h90);      // Note On, channel 0
        midi_byte(8'h3C);      // note 60
        midi_byte(8'h64);      // velocity 100
        $display("     已发 3 字节");

        // ---------- ② 等分配生效 ----------
        #200000;               // 10 µs ≈ 480 采样，足够分配 + 预取
        $display("");
        $display("  ② 调度层分配状态");
        $display("     pf_gate      = %b（至少一位为 1 表示分配成功）", dut.pf_gate);
        $display("     pf_ch        = %h", dut.pf_ch);
        $display("     pf_phase_inc[31:0] = %h", dut.pf_phase_inc[31:0]);
        if (dut.pf_gate === {P{1'b0}}) begin
            $display("  FAIL: 没有声部被分配（pf_gate 全 0）"); errs = errs + 1;
        end else $display("     分配成功 ✓");

        counting = 1;             // 开始过零计数
        // ---------- ③ 等声音出来 ----------
        $display("");
        $display("  ③ 等 100 ms 收集输出（ADSR 上升 ≈125 ms，要给它时间爬到 sustain）…");
        t0 = n_l;
        #100_000_000;
        $display("     左声道样本 %0d 个，非零 %0d 个，范围 [%0d, %0d]", n_l - t0, l_nz, l_min, l_max);
        $display("     右声道样本 %0d 个，非零 %0d 个，范围 [%0d, %0d]", n_r, r_nz, r_min, r_max);

        if ((n_l - t0) < 50) begin
            $display("  FAIL: I2S 样本太少（%0d）—— 帧节拍可能没跑", n_l - t0); errs = errs + 1;
        end else $display("     I2S 帧在正常输出 ✓");

        //  ⚠ 2026-10-13 收紧判据：原来只查"全零"，而 ±1 的抖动就能骗过它
        //     （实测 vel=20 与 vel=127 都得到 l_max=0、l_min=-1，照样 PASS）。
        //     改成**峰峰值**判据：真正的音频信号应远超这个阈值。
        //  ⚠ 2026-10-13 加：单声部层内部逐级探针（定位信号在哪一级变 0）
        $display("");
        $display("       --- 单声部层内部（泳道 0 / 声部 0）---");
        $display("       pf_gate       = %b", dut.pf_gate);
        $display("       pf_phase_inc  = %h", dut.pf_phase_inc[31:0]);
        $display("       rs_phase_acc  = %h  (相位累加器)", dut.rs_phase_acc[31:0]);
        $display("       rs_env_value  = %0d  (包络)", $signed(dut.rs_env_value[15:0]));
        $display("       rs_env_state  = %0d  (0=IDLE 1=ATK 2=DEC 3=SUS 4=REL)", dut.rs_env_state[2:0]);
        $display("       tab_n  (波表) = %0d   tab_n1 = %0d", $signed(dut.tab_n[15:0]), $signed(dut.tab_n1[15:0]));
        $display("       rom_rdy       = %b   (取数就绪)", dut.rom_rdy);
        $display("       rom_addr_n[13:0] = %h  (读地址)", dut.rom_addr_n[13:0]);
        $display("");
        $display("       --- 跨整个观察窗的最大值（关键！）---");
        $display("       max pf_phase_inc   = %h   (非 0 才说明预取到了相位增量)", max_pf_inc);
        $display("       max rs_phase_acc   = %h   (非 0 才说明 DDS 在累加)", max_rs_phacc);
        $display("       max rs_env_value   = %0d", max_rs_env);
        $display("       rom_rdy 脉冲次数    = %0d", rom_rdy_cnt);
        $display("");

        p2p_l = l_max - l_min;
        $display("     左声道峰峰值 = %0d（阈值 %0d）", p2p_l, AMP_MIN);
        if (p2p_l < AMP_MIN) begin
            $display("  FAIL: 左声道峰峰值太小（%0d < %0d）—— 没有真正出声", p2p_l, AMP_MIN);
            errs = errs + 1;
        end else $display("     左声道幅度正常 ✓");

        if ((l_max - l_min) < 10) begin
            $display("  ⚠ 幅度极小（%0d）—— 波表 ROM 未载入时可能如此", l_max - l_min);
        end else $display("     幅度 %0d ✓", l_max - l_min);

        counting = 0;
        $display("");
        $display("  ③b 音高验证（过零计数）");
        $display("     过零 %0d 次，窗口 %0d 采样", zc, zc_end - zc_start);
        if (zc_end > zc_start) begin
            real fm;
            fm = zc / 2.0 * 48000.0 / (zc_end - zc_start);
            $display("     实测频率 ≈ %0.1f Hz（期望 261.6 Hz = C4）", fm);
            if (fm > 200.0 && fm < 340.0) $display("     音高正确 ✓");
            else $display("  ⚠ 音高偏离（%0.1f Hz）", fm);
        end

        // ---------- ④ 无 X ----------
        $display("");
        $display("  ④ X 检查（分别看引脚与内部采样）");
        $display("     HP_DIN 为 X 的拍数 = %0d", x_cnt);
        $display("     sample_l 为 X 的采样数 = %0d，sample_r = %0d", sx_l, sx_r);
        $display("     voice_aud[23:0] = %h", dut.voice_aud[23:0]);
        $display("     --- 逐级幅度 ---");
        $display("     voice_aud : [%0d, %0d]  幅度 %0d（满刻度 8388607）", va_min, va_max, (va_max-va_min)/2);
        $display("     rs_env_value[15:0] : [%0d, %0d]（Q1.15，满 32767）", en_min, en_max);
        $display("     mx_l      : [%0d, %0d]  幅度 %0d", mx_min, mx_max, (mx_max-mx_min)/2);
        $display("     --- 通道层探针 ---");
        $display("     ch_vld 高过 %0d 拍；ch_l 范围 [%0d, %0d]",
                 chv_cnt, chl_min, chl_max);
        $display("     ch_buf 写入过 %0d 次；slot_vld 高过 %0d 拍", bufwr, svld_cnt);
        $display("     lane_ch = %h   pf_ch = %h", dut.u_full_top.lane_ch, dut.pf_ch);
        $display("     volume_f[6:0]=%h  panL_f[15:0]=%h",
                 dut.u_full_top.volume_f[6:0], dut.u_full_top.panL_f[15:0]);
        $display("     --- 波表 ROM 探针 ---");
        $display("     rom mem[0]=%h mem[1]=%h mem[2048]=%h",
                 dut.u_wfetch.u_rom.mem[0], dut.u_wfetch.u_rom.mem[1], dut.u_wfetch.u_rom.mem[2048]);
        $display("     tab_n[15:0]=%h  rom_rdy 见过几次见下", dut.tab_n[15:0]);
        $display("     voice0.phase_acc=%h", dut.g_voice[0].u_voice.phase_acc);
        $display("     u_full_top.mx_l = %0d", $signed(dut.u_full_top.mx_l));
        if (sx_l != 0 || sx_r != 0) begin
            $display("  FAIL: 内部采样就是 X（不是引脚问题）"); errs = errs + 1;
        end else if (x_cnt != 0) begin
            $display("  ⚠ 引脚有 X 但内部采样正常 —— 可能是 I2S 移位寄存器复位前的残留");
        end else $display("     无 X ✓");

        // ---------- ⑤ Note Off ----------
        $display("");
        $display("  ⑤ 发 Note Off（note=60）");
        midi_byte(8'h80);
        midi_byte(8'h3C);
        midi_byte(8'h40);
        #500000;
        $display("     Note Off 已发，pf_gate = %b", dut.pf_gate);

        $display("");
        if (errs == 0) $display("PASS  tb_full_system: 端到端 5 项全过");
        else           $display("FAIL  tb_full_system: %0d 项未过", errs);
        $finish;
    end

    //  ⚠ 波表 ROM 未载入时 `mem[]` 是未初始化的 `reg` → 仿真读出 X →
    //     整条音频链变 X。上板时 BSRAM 初值由 .mi/bitstream 承担，仿真必须给文件。
    initial begin
        #500_000_000;
        $display("FAIL  tb_full_system: 超时");
        $finish;
    end

    //========================================================================
    //  2026-10-22 加：**数字域黄金参考** dump
    //
    //  每个采样帧把 4 路信号写成一行，供离线的频谱/跳变分析：
    //      sample_l          整链最终输出（送 DAC 的 16 位）
    //      voice_aud[23:0]   泳道 0 的 VCA 输出
    //      dbg_va_r          8 泳道 VCA 输出之和（= 探针 E25 看到的信号）
    //      ch_l              通道层输出（效果器之前）
    //  目的：判断"炸"到底是 RTL 逻辑就有的，还是只在硬件上（时序/模拟）才出现。
    //========================================================================
    integer fd;
    initial fd = $fopen("D:/code/fpga-synthesizer/folder-reorg/scratch/agent/probe_full.txt", "w");
    always @(posedge clk50) begin
        if (dut.rst_n_sync && dut.sample_stb)
            $fwrite(fd, "%0d %0d %0d %0d\n",
                    $signed(dut.u_full_top.sample_l),
                    $signed(dut.u_full_top.voice_aud[23:0]),
                    $signed(dut.u_full_top.dbg_va_r),
                    $signed(dut.u_full_top.ch_l));
    end
endmodule
`default_nettype wire
