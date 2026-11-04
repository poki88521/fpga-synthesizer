//============================================================================
//  pll_49m —— 24.576 MHz -> 49.152 MHz（Arora V PLL 原语，不是 PLLA）
//
//  ⚠ 重要：本器件（GW5AST-138）用的是 PLL 原语；PLLA 只支持 GW5A-25。
//
//  ⚠⚠ 本文件的参数是**按板上实测可用的方案**定的（2026-10-06，见
//     `new/测试清单.md` §二「PLL / 最终时钟链实测结论」）：
//        MS5351 CLK2 → 24.576 MHz → N22 → PLL → 49.152 MHz，**已实测锁定成功**
//        （实测 PMOD2：N22 直通 24.5 MHz、clk_49m÷2 = 24.5 MHz、
//          ÷16 = 3.07 MHz、÷256 = 192 kHz，均与设计一致）
//
//  频率校验（依据 UG306 的关系式）：
//      Fpfd    = Fclkin / IDIV   = 24.576 / 1      = 24.576 MHz
//      Fclkfb  = Fpfd  * FBDIV   = 24.576 * 1      = 24.576 MHz
//      Fvco    = Fclkfb * MDIV   = 24.576 * 32     = 786.432 MHz
//      Fclkout0= Fvco  / ODIV0   = 786.432 / 16    = 49.152 MHz
//      分频比    = 49.152 / 24.576 = 2.0（整数）
//
//  ⚠⚠⚠ 关键实测约束（工具报错 PA2078/PA1019 给出，**与 DS1104 表 3-18 的
//        10~400 MHz / 800~2000 MHz 不符，以工具为准**）：
//          PFD（鉴相频率）= 19 ~ 81.25 MHz
//          VCO            = 650 ~ 1300 MHz
//        ⇒ FCLKIN/IDIV 必须 ≥ 19 MHz。
//        **所以 12.288 MHz 不能直接喂这个 PLL**（12.288 < 19，工具直接报 PA2078）。
//        本文件原来就是按 12.288 MHz 写的（FCLKIN=12.288/FBDIV=2/MDIV=64/ODIV0=32），
//        那个配置在板上**锁不上** —— 已按实测方案改正。
//
//  ⚠ 原语使用要点（实测踩过）：`CLKOUT0_EN="TRUE"` 之外，
//    **动态使能脚 `ENCLK0` 必须接 1'b1**（接 0 会报 PA2146 "Channel 0 must be enabled"）。
//
//  ⚠ `N22` 不是专用时钟脚（UG986 显示它是 MGCLKC_3 + PLL 反馈脚），
//    所以走通用布线（PR1014 警告），**但 PLL 仍能锁定**，不影响功能。
//
//  ⚠ `.sdc` 里 `clk_in` 的周期必须与这里 FCLKIN 一致（24.576 MHz → 40.69 ns），
//    否则报 TA1118。
//
//  CLKOUT1~6 本项目不用（PT8211 不需要 MCLK），直接关闭。
//============================================================================

`default_nettype none

module pll_49m #(
    //  PLL 从复位释放前的等待拍数（相对 clkin）。默认 2^13 拍 ≈ 0.33 ms @24.576MHz。
    //  ⚠⚠ 为什么必须等待（板上实测的教训，见 src/test/pll_test/pll_test.v）：
    //    上电时 MS5351 的 CLK2 会先输出一个**默认频率（≈16 MHz）**，
    //    要等 I2C 配置完成后才是 24.576 MHz。
    //    如果 PLL 一上电就自由跑，它会**锁到 16 MHz** → 输出 ≈32 MHz（不是 49.152），
    //    整个音频链的采样率全错 → 表现为"完全无声"或音调怪异。
    //    板上可用的 pll_test 是"等 MS5351 配置完成 + 延迟 ~1 ms 再释放 RESET"。
    //    本模块自带等待计数，只要 clkin 稳定后自动释放；上层若想完全掌控，
    //    可把 WAIT_BITS 设大或改用 external_reset 端口。
    parameter integer WAIT_BITS  = 13,
    //  置 1 时用外部 reset_in 控制（与内部分频等待相或）
    parameter integer USE_EXT_RST = 0
)(
    input  wire clkin,      // 24.576 MHz（MS5351M CLK2 -> N22，实测 ≈24.5 MHz）
    input  wire reset_in,   // 外部复位（USE_EXT_RST=1 时生效；高有效）
    output wire clkout0,    // 49.152 MHz
    output wire lock
);

    // ---------------- 复位等待：clkin 稳定一段时间后才释放 PLL ----------------
    reg [WAIT_BITS-1:0] pll_wait;
    initial pll_wait = {WAIT_BITS{1'b0}};

    always @(posedge clkin)
        if (pll_wait != {WAIT_BITS{1'b1}}) pll_wait <= pll_wait + 1'b1;

    //  计数未满 → 保持复位；满了 → 释放。
    //  ⚠ 判据用"明确计满才释放"（`==` 比较 + &&），X 情况下当复位处理，X 安全。
    wire pll_rst_n = (pll_wait == {WAIT_BITS{1'b1}});
    wire pll_reset = (USE_EXT_RST != 0) ? (~pll_rst_n | reset_in) : (~pll_rst_n);

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
        // ⚠⚠ 实测要点（new/测试清单.md）：动态使能脚 **ENCLK0 必须接 1'b1**，
        //    接 0 会报 PA2146「Channel 0 must be enabled」，CLKOUT0 不出来。
        //    原来本文件**没有连这个端口** —— 板上是锁不上的。
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
    // 仿真时跳过 defparam（桩模型没有这些参数），并由桩模型直接把 clkin 透传
`else
    defparam PLL_inst.FCLKIN        = "24.576";
    defparam PLL_inst.IDIV_SEL      = 1;
    defparam PLL_inst.FBDIV_SEL     = 1;
    defparam PLL_inst.MDIV_SEL      = 32;
    defparam PLL_inst.MDIV_FRAC_SEL = 0;
    defparam PLL_inst.ODIV0_SEL     = 16;
    defparam PLL_inst.ODIV0_FRAC_SEL= 0;

    defparam PLL_inst.CLKOUT0_EN    = "TRUE";
    defparam PLL_inst.CLKOUT1_EN    = "FALSE";   // 本项目不需要 MCLK
    defparam PLL_inst.CLKOUT2_EN    = "FALSE";
    defparam PLL_inst.CLKOUT3_EN    = "FALSE";
    defparam PLL_inst.CLKOUT4_EN    = "FALSE";
    defparam PLL_inst.CLKOUT5_EN    = "FALSE";
    defparam PLL_inst.CLKOUT6_EN    = "FALSE";
    defparam PLL_inst.CLKFB_SEL     = "INTERNAL";

    defparam PLL_inst.CLKOUT0_DT_DIR  = 1'b1;
    defparam PLL_inst.CLKOUT1_DT_DIR  = 1'b1;
    defparam PLL_inst.CLKOUT2_DT_DIR  = 1'b1;
    defparam PLL_inst.CLKOUT3_DT_DIR  = 1'b1;
    defparam PLL_inst.CLKOUT0_DT_STEP = 0;
    defparam PLL_inst.CLKOUT1_DT_STEP = 0;
    defparam PLL_inst.CLKOUT2_DT_STEP = 0;
    defparam PLL_inst.CLKOUT3_DT_STEP = 0;

    defparam PLL_inst.CLK0_IN_SEL  = 1'b0;
    defparam PLL_inst.CLK0_OUT_SEL = 1'b0;
    defparam PLL_inst.CLK1_IN_SEL  = 1'b0;
    defparam PLL_inst.CLK1_OUT_SEL = 1'b0;
    defparam PLL_inst.CLK2_IN_SEL  = 1'b0;
    defparam PLL_inst.CLK2_OUT_SEL = 1'b0;
    defparam PLL_inst.CLK3_IN_SEL  = 1'b0;
    defparam PLL_inst.CLK3_OUT_SEL = 1'b0;
    defparam PLL_inst.CLK4_IN_SEL  = 2'b00;
    defparam PLL_inst.CLK4_OUT_SEL = 1'b0;
    defparam PLL_inst.CLK5_IN_SEL  = 1'b0;
    defparam PLL_inst.CLK5_OUT_SEL = 1'b0;
    defparam PLL_inst.CLK6_IN_SEL  = 1'b0;
    defparam PLL_inst.CLK6_OUT_SEL = 1'b0;

    defparam PLL_inst.DYN_DPA_EN  = "FALSE";
    defparam PLL_inst.CLKOUT0_PE_COARSE = 0;
    defparam PLL_inst.CLKOUT0_PE_FINE   = 0;
    defparam PLL_inst.CLKOUT1_PE_COARSE = 0;
    defparam PLL_inst.CLKOUT1_PE_FINE   = 0;
    defparam PLL_inst.CLKOUT2_PE_COARSE = 0;
    defparam PLL_inst.CLKOUT2_PE_FINE   = 0;
    defparam PLL_inst.CLKOUT3_PE_COARSE = 0;
    defparam PLL_inst.CLKOUT3_PE_FINE   = 0;
    defparam PLL_inst.CLKOUT4_PE_COARSE = 0;
    defparam PLL_inst.CLKOUT4_PE_FINE   = 0;
    defparam PLL_inst.CLKOUT5_PE_COARSE = 0;
    defparam PLL_inst.CLKOUT5_PE_FINE   = 0;
    defparam PLL_inst.CLKOUT6_PE_COARSE = 0;
    defparam PLL_inst.CLKOUT6_PE_FINE   = 0;

    defparam PLL_inst.DYN_PE0_SEL = "FALSE";
    defparam PLL_inst.DYN_PE1_SEL = "FALSE";
    defparam PLL_inst.DYN_PE2_SEL = "FALSE";
    defparam PLL_inst.DYN_PE3_SEL = "FALSE";
    defparam PLL_inst.DYN_PE4_SEL = "FALSE";
    defparam PLL_inst.DYN_PE5_SEL = "FALSE";
    defparam PLL_inst.DYN_PE6_SEL = "FALSE";

    defparam PLL_inst.DE0_EN = "FALSE";
    defparam PLL_inst.DE1_EN = "FALSE";
    defparam PLL_inst.DE2_EN = "FALSE";
    defparam PLL_inst.DE3_EN = "FALSE";
    defparam PLL_inst.DE4_EN = "FALSE";
    defparam PLL_inst.DE5_EN = "FALSE";
    defparam PLL_inst.DE6_EN = "FALSE";

    defparam PLL_inst.RESET_I_EN = "FALSE";
    defparam PLL_inst.RESET_O_EN = "FALSE";
    defparam PLL_inst.ICP_SEL    = 6'bXXXXXX;
    defparam PLL_inst.LPF_RES    = 3'b000;   // 板上实测版用 000（原来是默认 XXX，综合有风险）
    defparam PLL_inst.LPF_CAP    = 2'b00;
    defparam PLL_inst.SSC_EN     = "FALSE";

    defparam PLL_inst.DYN_IDIV_SEL  = "FALSE";
    defparam PLL_inst.DYN_FBDIV_SEL = "FALSE";
    defparam PLL_inst.DYN_MDIV_SEL  = "FALSE";
    defparam PLL_inst.DYN_ODIV0_SEL = "FALSE";
    defparam PLL_inst.DYN_ODIV1_SEL = "FALSE";
    defparam PLL_inst.DYN_ODIV2_SEL = "FALSE";
    defparam PLL_inst.DYN_ODIV3_SEL = "FALSE";
    defparam PLL_inst.DYN_ODIV4_SEL = "FALSE";
    defparam PLL_inst.DYN_ODIV5_SEL = "FALSE";
    defparam PLL_inst.DYN_ODIV6_SEL = "FALSE";
    defparam PLL_inst.DYN_DT0_SEL   = "FALSE";
    defparam PLL_inst.DYN_DT1_SEL   = "FALSE";
    defparam PLL_inst.DYN_DT2_SEL   = "FALSE";
    defparam PLL_inst.DYN_DT3_SEL   = "FALSE";
    defparam PLL_inst.DYN_ICP_SEL   = "FALSE";
    defparam PLL_inst.DYN_LPF_SEL   = "FALSE";
`endif

endmodule

`default_nettype wire
