//============================================================================
//  vis_top —— 可视化顶层（接真音频）
//
//  音频域（49.152 MHz）  : clk_sys / rst_sys_n / sample_stb / sample_l
//  像素域（35 MHz，自带 PLL）: clk50 → pll_pixel
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

    vis_audio u_aud (
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n),
        .sample_stb(sample_stb), .sample_l(sample_l),
        .clk_px(clk_px), .rst_px_n(rst_px_n),
        .x(rnd_x), .vld(rnd_vld), .frame_stb(frame_stb),
        .y(wy), .vld_o(wy_vld),
        .wr_ptr_o(dbg_wp), .start_o(dbg_start)
    );

    wave_render u_wave (
        .clk(clk_px), .rst_n(rst_px_n),
        .x(rnd_x), .y(rnd_y), .vld(rnd_vld),
        .y_wave_q(wy),
        .color({6'd0, 6'd56, 6'd56}),      // alpha：固定青色；beta 接音色混色
        .rgb(rnd_rgb)
    );

    assign pll_lock_o = lock;

endmodule
`default_nettype wire
