//============================================================================
//  vis_standalone —— **可视化子系统独立测试**（不含音频引擎、不含调度层）
//
//  包含的模块（全部是可视化真正在用的那几个）：
//      pll_pixel        50 → 35 MHz 像素时钟
//      lcd_800x480      屏时序
//      fake_audio_gen   假音频（循环 8 音色 / 4 音高 / 4 档响度）
//      vis_audio        音频→波形（跨时钟域、环形缓冲、零交叉锁相）★
//      wave_render      11 px 折线 + 白轴 + 白框 + 黑底
//
//  ⚠ 与 full_system 里的接法**完全一致**，只是音频源换成本地假的：
//      full_system:  visual.sample_l ← mon_l（真音频）/ fake_l
//      这里:          visual.sample_l ← fake_audio_gen
//    所以这个工程能编过、屏能出波形，就说明可视化子系统本身没问题。
//
//  Top Module：vis_standalone
//  约束      ：vis_standalone.cst / vis_standalone.sdc
//  **不需要任何 .hex**
//============================================================================
`default_nettype none

module vis_standalone (
    input  wire        clk50,        // 板载 50 MHz
    output wire        lcd_clk,
    output wire        lcd_en,
    output wire [5:0]  lcd_r,
    output wire [5:0]  lcd_g,
    output wire [5:0]  lcd_b,
    output wire        heartbeat
);

    //========================================================================
    //  1. "音频域"：这里直接用 clk50，并用 ÷1024 造一个 48.8 kHz 节拍
    //     （真系统里 clk_sys=49.152 MHz、sample_stb=48 kHz；这里只要"两个
    //      异步时钟 + 一个采样节拍"这个结构对，vis_audio 的行为就一致）
    //========================================================================
    reg [9:0] div;
    initial div = 10'd0;
    always @(posedge clk50) div <= div + 10'd1;

    wire sample_stb = (div == 10'd0);      // 每 1024 拍一个脉冲

    reg [15:0] por_sys;
    initial por_sys = 16'd0;
    always @(posedge clk50)
        if (por_sys != 16'hFFFF) por_sys <= por_sys + 16'd1;
    wire rst_sys_n = (por_sys == 16'hFFFF);

    //========================================================================
    //  2. 假音频（8 音色 / 4 音高 / 4 响度）
    //========================================================================
    wire signed [15:0] fake_sample;
    wire        [17:0] fake_color;      // 8 纯色 + 8 混合

    fake_audio_gen u_fake (
        .clk        (clk50),
        .rst_n      (rst_sys_n),
        .sample_stb (sample_stb),
        .sample     (fake_sample),
        .color      (fake_color)
    );

    //========================================================================
    //  3. 像素时钟 + 像素域复位
    //========================================================================
    wire clk_px, lock;

    pll_pixel u_pll (
        .clkin(clk50), .reset_in(1'b0),
        .clkout0(clk_px), .lock(lock)
    );

    reg [15:0] por_px;
    initial por_px = 16'd0;
    always @(posedge clk_px)
        if (!lock)                por_px <= 16'd0;
        else if (por_px != 16'hFFFF) por_px <= por_px + 16'd1;

    wire rst_px_n = (por_px == 16'hFFFF) && lock;

    //========================================================================
    //  4. LCD 时序
    //========================================================================
    wire [9:0]  rnd_x;
    wire [8:0]  rnd_y;
    wire        rnd_vld;
    wire [17:0] rnd_rgb;
    wire [10:0] h_cnt;
    wire [9:0]  v_cnt;
    wire        frame_stb;

    lcd_800x480 u_lcd (
        .clk(clk_px), .rst_n(rst_px_n),
        .rnd_x(rnd_x), .rnd_y(rnd_y), .rnd_vld(rnd_vld), .rnd_rgb(rnd_rgb),
        .lcd_clk(lcd_clk), .lcd_en(lcd_en),
        .lcd_r(lcd_r), .lcd_g(lcd_g), .lcd_b(lcd_b),
        .h_cnt(h_cnt), .v_cnt(v_cnt), .frame_stb(frame_stb)
    );

    //========================================================================
    //  5. 波形子系统（与 full_system 里一模一样）
    //========================================================================
    wire [10:0] wy;
    wire        wy_vld;
    wire [11:0] dbg_wp, dbg_start;

    vis_audio u_aud (
        .clk_sys    (clk50),
        .rst_sys_n  (rst_sys_n),
        .sample_stb (sample_stb),
        .sample_l   (fake_sample),
        .clk_px     (clk_px),
        .rst_px_n   (rst_px_n),
        .x          (rnd_x),
        .vld        (rnd_vld),
        .frame_stb  (frame_stb),
        .y          (wy),
        .vld_o      (wy_vld),
        .wr_ptr_o   (dbg_wp),
        .start_o    (dbg_start)
    );

    wave_render u_wave (
        .clk(clk_px), .rst_n(rst_px_n),
        .x(rnd_x), .y(rnd_y), .vld(rnd_vld),
        .y_wave_q(wy),
        .color(fake_color),
        .rgb(rnd_rgb)
    );

    //========================================================================
    //  6. 心跳灯
    //========================================================================
    reg [24:0] hb;
    initial hb = 25'd0;
    always @(posedge clk_px) hb <= hb + 25'd1;
    assign heartbeat = hb[24];

endmodule

`default_nettype wire
