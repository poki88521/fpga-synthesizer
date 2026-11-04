//============================================================================
//  vis_top —— 可视化顶层（接真音频）
//
//  音频域（49.152 MHz）  : clk_sys / rst_sys_n / sample_stb / sample_l
//                            └→ spec_band（32 频带 Goertzel）
//  像素域（35 MHz，自带 PLL）: clk50 → pll_pixel
//                            └→ wave_render（底部 32 根频谱柱 + 波形）
//
//  ⚠ 时钟墙：PRIMARY 8/8、LW 8/8 已满 ⇒ spec_band 必须跑在 clk_sys 上，
//    不能为它新增时钟域。频谱柱的 256 bit 结果用"翻转握手"搬到像素域：
//    spec_band 每 21 ms 整体提交一次 bars_tgl，像素域检测到翻转后才整块抓取，
//    避免在测量扫描（约 7 µs）期间抓到半新半旧的柱高。
//
//  集成到 full_system 时，只要把 sample_l 和 sample_stb 接过来，
//  再把 LCD 的 22 根线接到 cst 里的引脚即可。
//============================================================================
`default_nettype none

module vis_top (
    // ---- 音频域（来自 full_top）----
    input  wire               clk_sys,
    input  wire               rst_sys_n,
    input  wire               sample_stb,
    input  wire signed [15:0] sample_l,

    // ---- 板载 50 MHz（给像素 PLL 做参考，专用时钟脚）----
    input  wire               clk50,

    // ---- 面板 ----
    output wire               lcd_clk,
    output wire               lcd_en,
    output wire [5:0]         lcd_r,
    output wire [5:0]         lcd_g,
    output wire [5:0]         lcd_b,

    // ---- 观测 ----
    output wire               pll_lock_o,
    output wire [11:0]        dbg_wp,
    output wire [11:0]        dbg_start
);

    //------------------------------------------------------------------------
    //  1. 像素时钟 + 复位
    //------------------------------------------------------------------------
    wire clk_px, lock;

    pll_pixel u_pll (
        .clkin(clk50), .reset_in(1'b0),
        .clkout0(clk_px), .lock(lock)
    );

    reg [15:0] por;
    initial por = 16'd0;
    always @(posedge clk_px)
        if (!lock)               por <= 16'd0;
        else if (por != 16'hFFFF) por <= por + 16'd1;

    wire rst_px_n = (por == 16'hFFFF) && lock;

    //------------------------------------------------------------------------
    //  2. LCD 时序
    //------------------------------------------------------------------------
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

    //------------------------------------------------------------------------
    //  3. 音频 → 波形
    //------------------------------------------------------------------------
    wire [10:0] wy;
    wire        wy_vld;

    //  ⚠ 布局 A（交接文档 2026-10-29 定稿）：波形占上部、频谱占底部 100 px。
    //     波形原来是全屏 40..440（CX=240/AMP=195）；这里**只在本例化处覆盖参数**
    //     把它收到 40..360（CX=200/AMP=160），vis_audio.v 内部一行都不用改。
    vis_audio #(
        .CX    (200),
        .AMP   (160),
        .Y_MIN (40),
        .Y_MAX (360)
    ) u_aud (
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n),
        .sample_stb(sample_stb), .sample_l(sample_l),
        .clk_px(clk_px), .rst_px_n(rst_px_n),
        .x(rnd_x), .vld(rnd_vld), .frame_stb(frame_stb),
        .y(wy), .vld_o(wy_vld),
        .wr_ptr_o(dbg_wp), .start_o(dbg_start)
    );

    //------------------------------------------------------------------------
    //  4. 音频 → 32 频带频谱（音频域，单份 Goertzel 旋转式）
    //------------------------------------------------------------------------
    wire [255:0] spec_bars;
    wire         spec_vld;
    wire         spec_tgl;

    spec_band #(.NB(32), .AW(16)) u_spec (
        .clk        (clk_sys),
        .rst_n      (rst_sys_n),
        .sample_stb (sample_stb),
        .aud_in     (sample_l),
        .bars       (spec_bars),
        .bars_vld   (spec_vld),
        .bars_tgl   (spec_tgl)
    );

    //  翻转握手：像素域把 spec_tgl 打三拍，检测到 tgl_s[1]^tgl_s[2] 才整块抓
    reg [2:0] tgl_s;
    always @(posedge clk_px or negedge rst_px_n) begin
        if (!rst_px_n) tgl_s <= 3'd0;
        else           tgl_s <= {tgl_s[1:0], spec_tgl};
    end

    reg [255:0] bars_px;
    always @(posedge clk_px or negedge rst_px_n) begin
        if (!rst_px_n)                 bars_px <= 256'd0;
        else if (tgl_s[2] ^ tgl_s[1])  bars_px <= spec_bars;
    end

    //------------------------------------------------------------------------
    //  5. 渲染
    //------------------------------------------------------------------------
    wave_render #(
        .AXIS_Y  (200),                    // 与上面 vis_audio 的 CX 保持一致
        .SPEC_Y0 (380)
    ) u_wave (
        .clk(clk_px), .rst_n(rst_px_n),
        .x(rnd_x), .y(rnd_y), .vld(rnd_vld),
        .y_wave_q(wy),
        .color({6'd0, 6'd56, 6'd56}),      // alpha：固定青色；beta 接音色混色
        .bars(bars_px),
        .rgb(rnd_rgb)
    );

    assign pll_lock_o = lock;

endmodule
`default_nettype wire
