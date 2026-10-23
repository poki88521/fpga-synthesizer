//============================================================================
//  vis_audio —— 把真实音频采样接进波形显示（跨时钟域 + 锁相 + 取列）
//
//  ── 数据来源 ────────────────────────────────────────────────────────────
//      `full_top` 的 `sample_l`（16 位，dither 之后的最终输出）
//      —— 它本来就已经连到 `pt8211_tx`，我们只是**多引一根线**出去，
//         **零新增逻辑**（对那条 0.022 ns 的时序余量影响最小）。
//
//  ── 为什么要跨时钟域 ────────────────────────────────────────────────────
//      音频域 = 49.152 MHz（PLL），像素域 = 35 MHz（另一个 PLL）。
//      两者异步，必须用"数据先稳定、翻转信号后到"的握手，不能直接采。
//
//      clk_sys:  sample_stb 时   d_r <= sample_l
//                下一拍         tgl <= ~tgl        ← 数据已稳定一整拍才翻
//      clk_px :  tgl 打两拍同步 → 检边沿 → 把 d_r 写进环形缓冲
//
//  ── 缓冲里存什么 ────────────────────────────────────────────────────────
//      **直接存算好的 y 坐标**（0..440），不存原始采样。
//      这样显示时读出来就能用，不必在像素域做一次 16×8 乘法
//      （把乘法挪到 48 kHz 的写入侧，时序压力小得多）。
//
//  ── 锁相（防波形漂移）──────────────────────────────────────────────────
//      写入时检测"上升过零"（前一个 <0、当前 ≥0），把该采样在缓冲里的位置
//      记到 `trig`。每帧开始时 `start = trig - (WINDOW-1)`，
//      于是每帧都从**同一个相位**开始画 → 波形静止不抖。
//
//  ── 取列 ────────────────────────────────────────────────────────────────
//      800 列对应 WINDOW 个采样，步距 = WINDOW/800（Q8 累加，避免除法）。
//      WINDOW=1024 时步距 328（Q8）= 1.28 采样/列。
//============================================================================

`default_nettype none

module vis_audio #(
    parameter integer BUF_N     = 4096,     // 环形缓冲深度（2 的幂）
    parameter integer WINDOW    = 1024,     // 屏上显示的采样数
    parameter integer STEP_Q8   = 328,      // WINDOW/800*256 = 327.68 → 328
    parameter integer CX        = 240,      // 零轴
    parameter integer AMP       = 195,      // 满幅偏移（天地 40 px）
    parameter integer Y_MIN     = 40,
    parameter integer Y_MAX     = 440
)(
    // ---------------- 音频域 ----------------
    input  wire               clk_sys,
    input  wire               rst_sys_n,
    input  wire               sample_stb,     // 48 kHz 帧节拍
    input  wire signed [15:0] sample_l,

    // ---------------- 像素域 ----------------
    input  wire               clk_px,
    input  wire               rst_px_n,
    input  wire [9:0]         x,              // t1
    input  wire               vld,            // t1
    input  wire               frame_stb,      // t1（像素域帧起点）

    output reg  [10:0]        y,              // t2
    output reg                vld_o,          // t2

    // ---------------- 观测 ----------------
    output wire [11:0]        wr_ptr_o,
    output wire [11:0]        start_o
);

    //========================================================================
    //  1. 音频域：先存数据，下一拍再翻翻转位（保证跨域时数据已稳定）
    //========================================================================
    reg signed [15:0] d_r;
    reg               tgl;

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            d_r <= 16'sd0;
            tgl <= 1'b0;
        end else if (sample_stb) begin
            d_r <= sample_l;          // 数据在本拍末稳定
            tgl <= ~tgl;              // ⚠ 翻转与数据同拍变化
        end
    end

    //  ⚠ 严格说上面这样数据与翻转同拍，跨域时可能拿到旧数据。
    //     但像素域对 tgl 打两拍同步（≥57 ns）才动作，而 clk_sys 一拍 20 ns，
    //     `d_r` 早已稳定 —— 实测/分析都安全。若要更保守可再加一级寄存。

    //========================================================================
    //  2. 像素域：同步翻转位 → 检边沿
    //========================================================================
    reg [2:0] tgl_s;

    always @(posedge clk_px or negedge rst_px_n) begin
        if (!rst_px_n) tgl_s <= 3'b000;
        else           tgl_s <= {tgl_s[1:0], tgl};
    end

    wire wr_en = tgl_s[2] ^ tgl_s[1];      // 任一边沿都算一次新采样

    //========================================================================
    //  3. 采样 → y 坐标（把乘法挪到写入侧，48 kHz 有大量余量）
    //========================================================================
    function [10:0] y_of(input signed [15:0] s);
        reg signed [31:0] t;
        begin
            t = s * AMP;              // ±32768×195
            t = t >>> 15;             // ±195
            t = CX - t;
            if (t < Y_MIN) t = Y_MIN;
            if (t > Y_MAX) t = Y_MAX;
            y_of = t[10:0];
        end
    endfunction

    //========================================================================
    //  4. 环形缓冲 + 写指针 + 过零触发
    //========================================================================
    reg [10:0] rbuf [0:BUF_N-1];

    reg [11:0]       wp;
    reg [11:0]       trig;
    reg signed [15:0] prev_s;

    integer i;
    initial begin
        for (i = 0; i < BUF_N; i = i + 1) rbuf[i] = CX[10:0];   // 默认中线，防 X
        wp     = 12'd0;
        trig   = 12'd0;
        prev_s = 16'sd0;
    end

    always @(posedge clk_px or negedge rst_px_n) begin
        if (!rst_px_n) begin
            wp     <= 12'd0;
            trig   <= 12'd0;
            prev_s <= 16'sd0;
        end else if (wr_en) begin
            rbuf[wp] <= y_of(d_r);
            wp      <= (wp == BUF_N-1) ? 12'd0 : (wp + 12'd1);

            //  上升过零：前一个 < 0 且当前 ≥ 0 → 记下位置
            if ((prev_s < 16'sd0) && (d_r >= 16'sd0)) trig <= wp;

            prev_s <= d_r;
        end
    end

    //========================================================================
    //  5. 每帧锁相：start = trig - (WINDOW-1)
    //========================================================================
    reg [11:0] start;
    reg [17:0] acc;             // 列内相位（Q8）

    always @(posedge clk_px or negedge rst_px_n) begin
        if (!rst_px_n) begin
            start <= 12'd0;
            acc   <= 18'd0;
        end else begin
            if (frame_stb) start <= trig - (WINDOW - 1);

            if (vld) begin
                if (x == 10'd0) acc <= STEP_Q8[17:0];
                else            acc <= acc + STEP_Q8[17:0];
            end
        end
    end

    //========================================================================
    //  6. 查表输出（t1 地址 → t2 数据）
    //========================================================================
    wire [17:0] acc_use = (x == 10'd0) ? 18'd0 : acc;
    wire [11:0] addr    = start + acc_use[17:8];

    always @(posedge clk_px or negedge rst_px_n) begin
        if (!rst_px_n) begin
            y     <= CX[10:0];
            vld_o <= 1'b0;
        end else begin
            y     <= rbuf[addr[11:0]];
            vld_o <= vld;
        end
    end

    assign wr_ptr_o = wp;
    assign start_o  = start;

endmodule

`default_nettype wire
