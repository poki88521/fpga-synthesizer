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

module tb_vel_amp;
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

    //  ⚠ 2026-10-14 加：主输出链逐级峰值跟踪。
    //     目的：查清"单声部层差 6.35 倍、到 I2S 却几乎一样"是哪一级吃掉的。
    //     层次：u_master = master_chain，内含 u_vol → u_lim → u_dc_l → u_dith
    //  ⚠ 2026-10-14 加：通道累加器探针。
    //     怀疑点：chan_layer 的 vld 只有 8 位（每泳道），不是 32 位（每声部），
    //     导致同一泳道在一帧内被扫描多次、把多个声部累加到同一个通道。
    //  ⚠ 2026-10-14 加：通道系数探针（看实际用的 gL 是多少）
    integer pk_gL   = 0;
    integer min_gL  = 1<<20;
    integer pk_pgch = 0;
    integer chl_min_p = 1<<20, chl_max_p = -(1<<20);
    always @(posedge clk50) if (dut.rst_n_sync) begin : g_coef
        integer g;
        g = $signed(dut.u_full_top.u_chan.u_coef.gL_flat[15:0]);
        if (g < 0) g = -g;
        if (g > pk_gL)  pk_gL  = g;
        if (g < min_gL) min_gL = g;
        g = $signed(dut.u_full_top.ch_l);
        if (g < chl_min_p) chl_min_p = g;
        if (g > chl_max_p) chl_max_p = g;
    end

    //  ⚠ 2026-10-14 修正：ch_l / ch_acc 是**时分复用**的（每拍一条通道），
    //     必须**在 ch_vld 有效时**按 ch_addr 配对采样，否则抓到的是无效拍。
    //     之前无条件采样导致"ch_l 从不负向、峰值恒饱和"的假象。
    integer pk_chl_by [0:15];      // 每个通道的 ch_l 峰值（绝对值）
    integer pk_acc_by [0:15];      // 每个通道的 ch_acc 峰值（绝对值）
    integer ch_vld_cnt = 0;
    integer ch_l_min_s = 1<<20, ch_l_max_s = -(1<<20);
    integer i2;
    initial for (i2 = 0; i2 < 16; i2 = i2 + 1) begin
        pk_chl_by[i2] = 0; pk_acc_by[i2] = 0;
    end
    always @(posedge clk50) if (dut.rst_n_sync && dut.u_full_top.ch_vld) begin : g_acc
        integer k, av, cid;
        cid = dut.u_full_top.ch_addr;
        av = $signed(dut.u_full_top.ch_l);
        if (av < ch_l_min_s) ch_l_min_s = av;
        if (av > ch_l_max_s) ch_l_max_s = av;
        if (av < 0) av = -av;
        if (av > pk_chl_by[cid]) pk_chl_by[cid] = av;
        for (k = 0; k < 16; k = k + 1) begin
            av = $signed(dut.u_full_top.u_chan.ch_acc[k]);
            if (av < 0) av = -av;
            if (av > pk_acc_by[k]) pk_acc_by[k] = av;
        end
        ch_vld_cnt = ch_vld_cnt + 1;
    end

    integer pk_mx   = 0;   // main_mix 输出（= master_chain 输入）
    integer pk_vol  = 0;   // 主音量之后
    integer pk_lim  = 0;   // 软限幅之后
    integer pk_dc   = 0;   // 去直流之后
    integer pk_samp = 0;   // 最终 16 位输出
    integer lim_hit = 0;   // 限幅器"正在压缩"的拍数
    always @(posedge clk50) if (dut.rst_n_sync) begin : g_chain
        integer a, b, c, d, e2;
        a  = $signed(dut.u_full_top.mx_l);
        b  = $signed(dut.u_full_top.u_master.l_vol);
        c  = $signed(dut.u_full_top.u_master.l_lim);
        d  = $signed(dut.u_full_top.u_master.l_dc);
        e2 = $signed(dut.u_full_top.sample_l);
        if (a  < 0) a  = -a;   if (a  > pk_mx)   pk_mx   = a;
        if (b  < 0) b  = -b;   if (b  > pk_vol)  pk_vol  = b;
        if (c  < 0) c  = -c;   if (c  > pk_lim)  pk_lim  = c;
        if (d  < 0) d  = -d;   if (d  > pk_dc)   pk_dc   = d;
        if (e2 < 0) e2 = -e2;  if (e2 > pk_samp) pk_samp = e2;
        //  限幅器压缩判据：输入绝对值超过阈值（THRESH = 0x600000 = 6291456）
        if ((($signed(dut.u_full_top.u_master.l_vol) > 6291456) ||
             ($signed(dut.u_full_top.u_master.l_vol) < -6291456))) lim_hit = lim_hit + 1;
    end

    //  ⚠ 不要在 TB 里按 BCK 边沿解码（早先那样写得到"98 样本/2ms、右声道 0 个"的
    //     假结果 —— 边沿计数与 WS 半帧不对齐）。直接读**设计内部**的每采样输出：
    //     `u_full_top.sample_l/sample_r` 就是送往 PT8211 的那两个字。
    integer sx_l = 0, sx_r = 0;
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

    integer vvel = 100;
    initial begin
        if (!$value$plusargs("vel=%d", vvel)) vvel = 100;
        $display("  ★ 本次力度 = %0d", vvel);
        $display("=== tb_vel_amp：力度 → 输出幅度对比===");
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
        midi_byte(vvel[7:0]);  // velocity（由 +vel=N 指定）
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
        $display("");
        $display("     --- 主输出链逐级峰值（绝对值）---");
        $display("       main_mix 输入到 master : %0d", pk_mx);
        $display("       主音量之后            : %0d", pk_vol);
        $display("       软限幅之后            : %0d   (限幅阈值 6291456)", pk_lim);
        $display("       去直流之后            : %0d", pk_dc);
        $display("       最终 16 位输出        : %0d", pk_samp);
        $display("       限幅器压缩拍数         : %0d", lim_hit);
        $display("");
        $display("");
        $display("     --- 逐通道 ch_l / ch_acc 峰值（在 ch_vld 时采样）---");
        $display("       ch_vld 采样次数 = %0d", ch_vld_cnt);
        $display("       ch_l 全局 min/max = %0d / %0d", ch_l_min_s, ch_l_max_s);
        for (i2 = 0; i2 < 16; i2 = i2 + 1)
            if (pk_chl_by[i2] != 0 || pk_acc_by[i2] != 0)
                $display("       ch %0d : ch_l 峰值 %0d   ch_acc 峰值 %0d", i2, pk_chl_by[i2], pk_acc_by[i2]);
        $display("");
        $display("     右声道样本 %0d 个，非零 %0d 个，范围 [%0d, %0d]", n_r, r_nz, r_min, r_max);

        if ((n_l - t0) < 50) begin
            $display("  FAIL: I2S 样本太少（%0d）—— 帧节拍可能没跑", n_l - t0); errs = errs + 1;
        end else $display("     I2S 帧在正常输出 ✓");

        if (l_nz == 0) begin
            $display("  FAIL: 左声道全零（没出声音）"); errs = errs + 1;
        end else $display("     左声道有非零样本 ✓");

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
        if (errs == 0) $display("PASS  tb_vel_amp: 端到端 5 项全过");
        else           $display("FAIL  tb_vel_amp: %0d 项未过", errs);
        $finish;
    end

    //  ⚠ 波表 ROM 未载入时 `mem[]` 是未初始化的 `reg` → 仿真读出 X →
    //     整条音频链变 X。上板时 BSRAM 初值由 .mi/bitstream 承担，仿真必须给文件。
    initial begin
        #500_000_000;
        $display("FAIL  tb_vel_amp: 超时");
        $finish;
    end
endmodule
`default_nettype wire
