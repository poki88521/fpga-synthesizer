//============================================================================
//  tb_wave_pitch —— 波表 + DDS 音高专项验证（A 级，约 20 ms 仿真）
//
//  目的：验证 2026-10-21 的两处修改后，note 60 的 DDS 输出音高**回到了 1x**：
//      1) 波表每槽只有 1 个周期（原 slot0/1 有 2 个 → 输出精确 2x）
//      2) dds_voice 的 timbre_r 与相位同沿锁存（原来波表槽来自下一时隙声部）
//
//  被测链路：dds_voice + wave_fetch + wave_table_rom（真实 data/wave_table.hex）
//
//  ⚠ 本 TB 用 50 MHz + 1024 拍/帧（= 48.828 kHz），与 USE_PLL=0 的仿真口径一致；
//     而 data/note_inc.hex 是按 48.000 kHz 算的 → 预期音高
//        261.63 x 48.828/48.000 = 266.1 Hz
//     （不是 261.6，这是本 TB 的已知且可接受的偏差）
//
//  判据（20 ms 窗口）：
//       1 周期   → 约 21 次过零（266 Hz x 0.02 s x 2）
//       2 周期   → 约 42 次过零（这正是修改前 slot0/1 的症状）
//============================================================================
`timescale 1ns/1ps

module tb_wave_pitch;

    localparam integer P        = 1;
    localparam integer AW       = 14;
    localparam integer DW       = 16;
    localparam integer N_CYC    = 1024;      // 每帧拍数（48.828 kHz @ 50 MHz）
    localparam integer STRIDE   = 32;        // 时隙间隔（与 full_system 一致）
    localparam integer NFRAME   = 1000;      // 观察帧数 → 20.48 ms
                                             //  ⚠ 若要更细的过零分辨率，改 5000（102.4 ms，
                                             //     约 1 分钟仿真）；当前值 = 已验证 PASS 的那次
    localparam [31:0]  PHINC    = 32'd23409859;   // note60 @ fs=48000

    //---------------------------------------------------------- 时钟/节拍
    reg clk = 0;
    always #10 clk = ~clk;                   // 50 MHz

    reg [10:0] cyc   = 0;                    // 0..1023
    reg [1:0]  slot  = 0;
    reg        frame = 0;                    // 帧首脉冲
    reg        sample_en = 0;                // 时隙脉冲（= slot_vld）

    integer k;
    always @(posedge clk) begin
        if (cyc == N_CYC - 1) begin
            cyc   <= 0;
            frame <= 1;
        end else begin
            cyc   <= cyc + 1;
            frame <= 0;
        end

        // 时隙脉冲：cyc = 1 + k*STRIDE（k = 0..3）
        sample_en <= 1'b0;
        for (k = 0; k < 4; k = k + 1) begin
            if (cyc == (1 + k * STRIDE)) begin
                sample_en <= 1'b1;
                slot      <= k[1:0];
            end
        end
    end

    //---------------------------------------------------------- 被测
    reg rst_n = 0;
    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1;
    end

    wire [P*AW-1:0] rom_addr_n, rom_addr_n1;
    wire [P*DW-1:0] tab_n, tab_n1;
    wire            rdy;
    wire [31:0]     phase_acc;
    wire signed [23:0] wave_out;

    // 只有"自己的时隙"（slot 0）才推进相位 —— 与调度层 pf_phase_inc 的实测行为一致
    wire [31:0] phase_inc = (slot == 2'd0) ? PHINC : 32'd0;

    // 音色槽在时隙 0 设为 1、其余时隙设为 2：用于验证 timbre_r 锁存
    // （若地址仍取"下一时隙"的实时值，slot0 会读到槽 2 而不是槽 1）
    wire [2:0] timbre_slot = (slot == 2'd0) ? 3'd1 : 3'd2;

    dds_voice u_dds (
        .clk         (clk),
        .rst_n_sync  (rst_n),
        .sample_en   (sample_en),
        .phase_inc   (phase_inc),
        .wave_sel    (2'd0),
        .timbre_slot (timbre_slot),
        .tab_n       ($signed(tab_n[15:0])),
        .tab_n1      ($signed(tab_n1[15:0])),
        .samples_rdy (rdy),
        .phase_acc   (phase_acc),
        .wave_out    (wave_out),
        .rom_addr_n  (rom_addr_n[13:0]),
        .rom_addr_n1 (rom_addr_n1[13:0])
    );

    wave_fetch #(
        .P(P), .AW(AW), .DW(DW), .INIT_FILE("data/wave_table.hex")
    ) u_wf (
        .clk           (clk),
        .rst_n_sync    (rst_n),
        .sample_en     (sample_en),
        .addr_n_flat   (rom_addr_n),
        .addr_n1_flat  (rom_addr_n1),
        .rdy           (rdy),
        .tab_n_flat    (tab_n),
        .tab_n1_flat   (tab_n1)
    );

    //---------------------------------------------------------- 采样与统计
    // 每帧在 cyc==25 记录一次 wave_out（slot0 的 rdy 已完成、slot1 尚未开始）
    integer n         = 0;
    integer ncross    = 0;
    integer bad_slot  = 0;
    //  ⚠ 变量不能叫 buf：`buf` 是 Verilog 的门级原语保留字（和 not 同类），
    //    用它当数组名会在声明处直接报 "syntax error / invalid module item"。
    reg [23:0] wsamp [0:NFRAME-1];

    always @(posedge clk) begin
        if (rst_n && cyc == 25 && n < NFRAME) begin
            wsamp[n] = wave_out;
            n = n + 1;
            if (n >= 2) begin
                if (($signed(wsamp[n-1]) >= 0) != ($signed(wsamp[n-2]) >= 0))
                    ncross = ncross + 1;
            end
        end
        // 地址槽位检查：slot0 的 rdy 时刻 rom_addr_n[13:11] 应为 1（timbre_r 锁存值）
        if (rst_n && rdy && (slot == 2'd0) && (rom_addr_n[13:11] !== 3'd1))
            bad_slot = bad_slot + 1;
    end

    //---------------------------------------------------------- 结果
    real freq;
    initial begin
        wait (rst_n);
        repeat (20) @(posedge clk);
        $display("=== tb_wave_pitch: 波表 + DDS 音高（note 60）===");
        $display("  时钟 50 MHz，1024 拍/帧 -> 帧率 48.828 kHz");
        $display("  phase_inc = %0d（note_inc.hex 中 note60 的值）", PHINC);
        $display("");

        while (n < NFRAME) @(posedge clk);

        freq = (ncross * 1.0) / (2.0 * (NFRAME * N_CYC * 20.0e-9));
        $display("  观察 %0d 帧 = %.3f ms", NFRAME, NFRAME * N_CYC * 20.0e-9 * 1e3);
        $display("  过零次数 = %0d", ncross);
        $display("  实测音高 = %.2f Hz（期望 266.1 Hz；2x 会是 532 Hz）", freq);
        $display("  slot0 读到非锁存槽的 rdy 次数 = %0d（应为 0）", bad_slot);
        $display("");

        if (freq > 240.0 && freq < 290.0 && bad_slot == 0)
            $display("PASS  tb_wave_pitch: 音高 1x、timbre_r 锁存生效");
        else if (freq > 500.0 && freq < 570.0)
            $display("FAIL  tb_wave_pitch: 音高仍是 2x（%.1f Hz）", freq);
        else
            $display("FAIL  tb_wave_pitch: 音高异常（%.1f Hz）或槽位错误（%0d）",
                     freq, bad_slot);
        $finish;
    end

    initial begin
        #30_000_000;                       // 30 ms 仿真上限（防止死等）
        $display("FAIL  tb_wave_pitch: 超时（n=%0d）", n);
        $finish;
    end

endmodule
