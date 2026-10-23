//============================================================================
//  pll_pixel —— 50 MHz → 35 MHz（LCD 像素时钟，给 800×480 屏）
//
//  ⚠ 与 `pll_49m.v` 同一套原语用法（GW5AST-138 用 PLL 原语，不是 PLLA）。
//
//  频率校验（依据 UG306 关系式，与 pll_49m 实测公式一致）：
//      Fpfd     = Fclkin / IDIV   = 50 / 1      = 50 MHz
//      Fclkfb   = Fpfd   * FBDIV  = 50 * 1      = 50 MHz
//      Fvco     = Fclkfb * MDIV   = 50 * 21     = 1050 MHz
//      Fclkout0 = Fvco   / ODIV0  = 1050 / 30   = 35 MHz
//
//  约束核对（pll_49m.v 注释里记录的实测限制）：
//      PFD = 19 ~ 81.25 MHz  → 50 MHz ✓
//      VCO = 650 ~ 1300 MHz  → 1050 MHz ✓
//
//  ⚠⚠ 为什么是 35 MHz：官方 `TangMega-138KPro-example/rgb_screen/800_480_screen`
//     的 `gowin_pll.mod` 实测参数就是 mdiv=21 / odiv0=30 / fclkin=50。
//     按 800×480 的时序（一行 1192 clk、一帧 533 行）：
//        刷新率 = 35e6 / (1192 × 533) = 55.09 Hz
//     （源码 `top.v` 里那句 `//10M` 是**过时注释**，别被它骗）
//
//  ⚠ `ENCLK0` 必须接 1'b1（接 0 报 PA2146）。
//
//  ⚠ 本 PLL 的参考时钟是**板载 clk50（P16，专用时钟脚）**，
//     与音频那路（N22 走通用布线）不同，这里没有 PR1014 警告。
//============================================================================

`default_nettype none

module pll_pixel #(
    //  PLL 复位等待拍数（相对 clkin）。50 MHz 下 2^12 拍 ≈ 82 µs，足够。
    parameter integer WAIT_BITS = 12
)(
    input  wire clkin,      // 50 MHz（板载 P16）
    input  wire reset_in,   // 外部复位（高有效，可选）
    output wire clkout0,    // 35 MHz 像素时钟
    output wire lock
);

    // ---------------- 上电等待：clkin 稳定后才释放 PLL ----------------
    reg [WAIT_BITS-1:0] pll_wait;
    initial pll_wait = {WAIT_BITS{1'b0}};

    always @(posedge clkin)
        if (pll_wait != {WAIT_BITS{1'b1}}) pll_wait <= pll_wait + 1'b1;

    //  判据用"明确计满才释放"（`==` 比较），X 情况下当复位处理，X 安全。
    wire pll_rst_n  = (pll_wait == {WAIT_BITS{1'b1}});
    wire pll_reset  = (~pll_rst_n) | reset_in;

    wire gw_gnd = 1'b0;
    wire clkout1, clkout2, clkout3, clkout4, clkout5, clkout6, clkfbout;

    PLL PLL_inst (
        .LOCK       (lock),
        .CLKOUT0    (clkout0),
        .CLKOUT1    (clkout1),
        .CLKOUT2    (clkout2),
        .CLKOUT3    (clkout3),
        .CLKOUT4    (clkout4),
        .CLKOUT5    (clkout5),
        .CLKOUT6    (clkout6),
        .CLKFBOUT   (clkfbout),
        .CLKIN      (clkin),
        //  ⚠ ENCLK0 必须为 1，否则 PA2146
        .ENCLK0     (1'b1),
        .ENCLK1     (gw_gnd),
        .ENCLK2     (gw_gnd),
        .ENCLK3     (gw_gnd),
        .ENCLK4     (gw_gnd),
        .ENCLK5     (gw_gnd),
        .ENCLK6     (gw_gnd),
        .CLKFB      (gw_gnd),
        .RESET      (pll_reset),
        .PLLPWD     (gw_gnd),
        .RESET_I    (gw_gnd),
        .RESET_O    (gw_gnd),
        .FBDSEL     ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
        .IDSEL      ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
        .MDSEL      ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
        .MDSEL_FRAC ({gw_gnd, gw_gnd, gw_gnd}),
        .ODSEL0     ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
        .ODSEL0_FRAC({gw_gnd, gw_gnd, gw_gnd}),
        .ODSEL1     ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
        .ODSEL2     ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
        .ODSEL3     ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
        .ODSEL4     ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
        .ODSEL5     ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
        .ODSEL6     ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
        .DT0        ({gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
        .DT1        ({gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
        .DT2        ({gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
        .DT3        ({gw_gnd, gw_gnd, gw_gnd, gw_gnd})
    );

`ifdef SIMULATION
    //  仿真：桩模型把 clkin 直通，跳过 defparam
`else
    defparam PLL_inst.FCLKIN         = "50.000";
    defparam PLL_inst.IDIV_SEL       = 1;
    defparam PLL_inst.FBDIV_SEL      = 1;
    defparam PLL_inst.MDIV_SEL       = 21;
    defparam PLL_inst.MDIV_FRAC_SEL  = 0;
    defparam PLL_inst.ODIV0_SEL      = 30;
    defparam PLL_inst.ODIV0_FRAC_SEL = 0;

    defparam PLL_inst.CLKOUT0_EN     = "TRUE";
    defparam PLL_inst.CLKOUT1_EN     = "FALSE";
    defparam PLL_inst.CLKOUT2_EN     = "FALSE";
    defparam PLL_inst.CLKOUT3_EN     = "FALSE";
    defparam PLL_inst.CLKOUT4_EN     = "FALSE";
    defparam PLL_inst.CLKOUT5_EN     = "FALSE";
    defparam PLL_inst.CLKOUT6_EN     = "FALSE";
    defparam PLL_inst.CLKFB_SEL      = "INTERNAL";
`endif

endmodule

`default_nettype wire
