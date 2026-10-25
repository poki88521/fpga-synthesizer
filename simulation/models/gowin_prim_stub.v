//============================================================================
//  gowin_prim_stub.v —— 仿真用桩模型（不进综合）
//
//  只为了在 iverilog 里把含 Gowin 原语的层次跑通：
//      PLL_49M 里的 PLL 原语直接透传 clkin
//  真机综合时请用 Gowin IDE 的 IP 向导生成 PLL，并把这个文件排除出工程。
//============================================================================

`timescale 1ns/1ps

//  ⚠ 参数补丁（2026-10-08 poki）：pll_49m.v 里有 88 处 `defparam PLL_inst.X`，
//    而原桩没有声明任何参数 → iverilog 报 "parameter `FCLKIN` not found"。
//    full_top 默认 USE_PLL=0 不走 PLL 分支所以没暴露；full_system 默认 USE_PLL=1
//    一编译就炸。这里把所有被 defparam 的参数按实际用到的名字补齐。
//    这些值只影响仿真，真机综合用的是 Gowin 原语，与本文件无关。
module PLL #(
    parameter FCLKIN = "",
    parameter IDIV_SEL = 0,
    parameter FBDIV_SEL = 0,
    parameter MDIV_SEL = 0,
    parameter MDIV_FRAC_SEL = 0,
    parameter ODIV0_SEL = 0,
    parameter ODIV0_FRAC_SEL = 0,
    parameter CLKOUT0_EN = "",
    parameter CLKOUT1_EN = "",
    parameter CLKOUT2_EN = "",
    parameter CLKOUT3_EN = "",
    parameter CLKOUT4_EN = "",
    parameter CLKOUT5_EN = "",
    parameter CLKOUT6_EN = "",
    parameter CLKFB_SEL = "",
    parameter CLKOUT0_DT_DIR = 0,
    parameter CLKOUT1_DT_DIR = 0,
    parameter CLKOUT2_DT_DIR = 0,
    parameter CLKOUT3_DT_DIR = 0,
    parameter CLKOUT0_DT_STEP = 0,
    parameter CLKOUT1_DT_STEP = 0,
    parameter CLKOUT2_DT_STEP = 0,
    parameter CLKOUT3_DT_STEP = 0,
    parameter CLK0_IN_SEL = 0,
    parameter CLK0_OUT_SEL = 0,
    parameter CLK1_IN_SEL = 0,
    parameter CLK1_OUT_SEL = 0,
    parameter CLK2_IN_SEL = 0,
    parameter CLK2_OUT_SEL = 0,
    parameter CLK3_IN_SEL = 0,
    parameter CLK3_OUT_SEL = 0,
    parameter CLK4_IN_SEL = 0,
    parameter CLK4_OUT_SEL = 0,
    parameter CLK5_IN_SEL = 0,
    parameter CLK5_OUT_SEL = 0,
    parameter CLK6_IN_SEL = 0,
    parameter CLK6_OUT_SEL = 0,
    parameter DYN_DPA_EN = "",
    parameter CLKOUT0_PE_COARSE = 0,
    parameter CLKOUT0_PE_FINE = 0,
    parameter CLKOUT1_PE_COARSE = 0,
    parameter CLKOUT1_PE_FINE = 0,
    parameter CLKOUT2_PE_COARSE = 0,
    parameter CLKOUT2_PE_FINE = 0,
    parameter CLKOUT3_PE_COARSE = 0,
    parameter CLKOUT3_PE_FINE = 0,
    parameter CLKOUT4_PE_COARSE = 0,
    parameter CLKOUT4_PE_FINE = 0,
    parameter CLKOUT5_PE_COARSE = 0,
    parameter CLKOUT5_PE_FINE = 0,
    parameter CLKOUT6_PE_COARSE = 0,
    parameter CLKOUT6_PE_FINE = 0,
    parameter DYN_PE0_SEL = "",
    parameter DYN_PE1_SEL = "",
    parameter DYN_PE2_SEL = "",
    parameter DYN_PE3_SEL = "",
    parameter DYN_PE4_SEL = "",
    parameter DYN_PE5_SEL = "",
    parameter DYN_PE6_SEL = "",
    parameter DE0_EN = "",
    parameter DE1_EN = "",
    parameter DE2_EN = "",
    parameter DE3_EN = "",
    parameter DE4_EN = "",
    parameter DE5_EN = "",
    parameter DE6_EN = "",
    parameter RESET_I_EN = "",
    parameter RESET_O_EN = "",
    parameter ICP_SEL = 0,
    parameter LPF_RES = 0,
    parameter LPF_CAP = 0,
    parameter SSC_EN = "",
    parameter DYN_IDIV_SEL = "",
    parameter DYN_FBDIV_SEL = "",
    parameter DYN_MDIV_SEL = "",
    parameter DYN_ODIV0_SEL = "",
    parameter DYN_ODIV1_SEL = "",
    parameter DYN_ODIV2_SEL = "",
    parameter DYN_ODIV3_SEL = "",
    parameter DYN_ODIV4_SEL = "",
    parameter DYN_ODIV5_SEL = "",
    parameter DYN_ODIV6_SEL = "",
    parameter DYN_DT0_SEL = "",
    parameter DYN_DT1_SEL = "",
    parameter DYN_DT2_SEL = "",
    parameter DYN_DT3_SEL = "",
    parameter DYN_ICP_SEL = "",
    parameter DYN_LPF_SEL = ""
) (
    output wire LOCK,
    output wire CLKOUT0, CLKOUT1, CLKOUT2, CLKOUT3,
    output wire CLKOUT4, CLKOUT5, CLKOUT6, CLKFBOUT,
    input  wire CLKIN, CLKFB, RESET, PLLPWD, RESET_I, RESET_O,
    input  wire ENCLK0, ENCLK1, ENCLK2, ENCLK3, ENCLK4, ENCLK5, ENCLK6,
    input  wire [5:0] FBDSEL, IDSEL,
    input  wire [6:0] MDSEL, ODSEL0, ODSEL1, ODSEL2,
    input  wire [6:0] ODSEL3, ODSEL4, ODSEL5, ODSEL6,
    input  wire [2:0] MDSEL_FRAC, ODSEL0_FRAC,
    input  wire [3:0] DT0, DT1, DT2, DT3,
    //  2026-10-23：pll_pixel.v（可视化像素时钟）显式接死了这些 SSC / 动态相移 /
    //  电荷泵 / 环路滤波配置口。仿真 stub 原来没有这些端口 → iverilog 报
    //  "port ``PSSEL'' is not a port of PLL_inst"。这里补齐（只用于仿真，
    //  综合时用的是 Gowin 的真实原语，不受影响）。
    input  wire [2:0] PSSEL,
    input  wire       PSDIR, PSPULSE, SSCPOL, SSCON,
    input  wire [6:0] SSCMDSEL,
    input  wire [2:0] SSCMDSEL_FRAC,
    input  wire [5:0] ICPSEL,
    input  wire [2:0] LPFRES,
    input  wire [1:0] LPFCAP
);
    assign LOCK     = 1'b1;
    assign CLKOUT0  = CLKIN;
    assign CLKOUT1  = CLKIN;
    assign CLKOUT2  = CLKIN;
    assign CLKOUT3  = CLKIN;
    assign CLKOUT4  = CLKIN;
    assign CLKOUT5  = CLKIN;
    assign CLKOUT6  = CLKIN;
    assign CLKFBOUT = CLKIN;
endmodule
