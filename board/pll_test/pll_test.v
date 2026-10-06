// [2026-10-06 11:36]  本文件时间戳（用于校验是否被外部覆盖）
//=============================================================
//  pll_test —— T-2：MS5351 -> N22 -> FPGA PLL ×2 -> 49.152 MHz
//  板卡：Tang Mega 138K Pro (GW5AST-LV138FPG676A / FCPBG676A)
//
//  【重要修正】该 PLL 的实际约束（工具报错 PA2078/PA1019）为：
//     PFD  ∈ 19 ~ 81.25 MHz，VCO ∈ 650 ~ 1300 MHz
//   （与 DS1104 表 3-18 的 10~400 / 800~2000 不同，以工具为准）
//   因 PFD = FCLKIN/IDIV 且 IDIV≥1，故 **FCLKIN 必须 ≥19 MHz** ——
//   原来的 12.288 MHz 无法使用（PFD 仅 12.288）。
//   => 改为 MS5351 输出 **24.576 MHz**，PLL ×2 得到 49.152 MHz：
//
//    MS5351: PLLA VCO=786.432 MHz，MS2 ÷32 -> 24.576 MHz
//    FPGA PLL: FCLKIN=24.576, IDIV=1, FBDIV=1, MDIV=32, ODIV0=16
//        Fpfd = 24.576/1 = 24.576 MHz          （19~81.25 ✓）
//        Fvco = 24.576*1*32 = 786.432 MHz      （650~1300 ✓）
//        CLKOUT0 = 786.432/16 = 49.152 MHz ✓
//
//  目的（回答 H3/H4）：若 PLL 能 LOCK 并输出 49.152 MHz，则 N22 可作 PLL CLKIN。
//   ⚠ 风险：N22 是普通 IO（非专用 CLKIN 脚）。若布线失败或 PLL 不 LOCK，
//       即说明 N22 不能作 PLL CLKIN。若原语例化参数仍报错，改用 IP Core Generator。
//
//  LED（低电平点亮，代码已取反）：
//    led_lock (M25/LED3) : PLL LOCK -> 亮（关键判据）
//    led_cfg  (R26/LED1) : MS5351 至少一档 ACK+配置成功 -> 亮
//    led_scan (L20/LED2) : 扫描中 -> 闪；结束 -> 灭
//    led_49m  (N21/LED4) : 49.152 MHz 域在跑 -> 闪
//
//  PMOD2（示波器测点）：
//    C21  PMOD2_IO0 : clk_49m ÷2 = 24.576 MHz（经寄存器输出，避免 GCLK 直连 IO）
//    B20  PMOD2_IO1 : clk_49m ÷16  = 3.072 MHz
//    B19  PMOD2_IO2 : clk_49m ÷256 = 192 kHz
//    A17  PMOD2_IO3 : clk_in(N22) 直通 = 24.576 MHz（复核输入）
//    B21/A20/A19    : 首个成功 mux 编号（3 位）
//=============================================================
module pll_test (
    input  wire clk,            // P16, 50 MHz（控制域）
    inout  wire scl,            // K25
    inout  wire sda,            // K26
    input  wire clk_in,         // N22 <- USR_CLK_IN（24.576 MHz）
    output wire mux_sel2,       // P26 = SEL2
    output wire mux_sel1,       // P19 = SEL1
    output wire mux_sel0,       // N19 = SEL0
    output wire led_lock,       // M25
    output wire led_cfg,        // R26
    output wire led_scan,       // L20
    output wire led_49m,        // N21
    output wire p_raw,          // C21  clk_49m÷2 = 24.576 MHz
    output wire p_div16,        // B20  3.072 MHz
    output wire p_div256,       // B19  192 kHz
    output wire p_clkin,        // A17  24.576 MHz (N22 直通)
    output wire mux_b0,         // B21
    output wire mux_b1,         // A20
    output wire mux_b2          // A19
);

    //----------------------------------------------------------
    // 参数
    //----------------------------------------------------------
    localparam [7:0]  DEV_ADDR   = 8'hC0;
    localparam integer N_ENT     = 26;
    localparam integer SETTLE_MAX= 100_000;

    localparam S_SETTLE = 3'd0,
               S_PROBE  = 3'd1,
               S_CFG    = 3'd2,
               S_NEXT   = 3'd3,
               S_DONE   = 3'd4;

    //----------------------------------------------------------
    // 1. 上电复位（控制域）
    //----------------------------------------------------------
    reg [19:0] por_cnt;
    always @(posedge clk)
        if (!(&por_cnt)) por_cnt <= por_cnt + 1'b1;
    wire rst = ~(&por_cnt);

    //----------------------------------------------------------
    // 2. 扫描寄存器
    //----------------------------------------------------------
    reg [2:0]  st;
    reg [2:0]  mux_try;
    reg [19:0] settle;
    reg  [5:0] idx;
    reg        go, pend;
    reg        ok_any, got_first;
    reg [2:0]  mux_first;
    reg [24:0] hb;

    //----------------------------------------------------------
    // 3. MS5351 配置表（CLK2 = 12.288 MHz）
    //----------------------------------------------------------
    function [15:0] cfg_entry;
        input integer i;
        begin
            case (i)
                0:  cfg_entry = {8'h03, 8'hFF};   // 关闭所有输出
                1:  cfg_entry = {8'h10, 8'h80};   // CLK0 掉电
                2:  cfg_entry = {8'h11, 8'h80};   // CLK1 掉电
                3:  cfg_entry = {8'h12, 8'h80};   // CLK2 掉电（配置期间）
                4:  cfg_entry = {8'h0F, 8'h00};   // PLL 输入源 = XTAL
                5:  cfg_entry = {8'h1A, 8'h0C};   // PLLA P3[15:8]
                6:  cfg_entry = {8'h1B, 8'h35};   // PLLA P3[7:0]
                7:  cfg_entry = {8'h1C, 8'h00};   // PLLA P1[17:16]
                8:  cfg_entry = {8'h1D, 8'h0D};   // PLLA P1[15:8]
                9:  cfg_entry = {8'h1E, 8'hBA};   // PLLA P1[7:0]
                10: cfg_entry = {8'h1F, 8'h00};   // PLLA P3[19:16]/P2[19:16]
                11: cfg_entry = {8'h20, 8'h06};   // PLLA P2[15:8]
                12: cfg_entry = {8'h21, 8'h7E};   // PLLA P2[7:0]
                13: cfg_entry = {8'h3A, 8'h00};   // MS2 P3[15:8]
                14: cfg_entry = {8'h3B, 8'h01};   // MS2 P3[7:0]      (P3=1)
                15: cfg_entry = {8'h3C, 8'h00};   // MS2 R2_DIV/DIVBY4/P1[17:16]=00
                16: cfg_entry = {8'h3D, 8'h0E};   // MS2 P1[15:8]
                17: cfg_entry = {8'h3E, 8'h00};   // MS2 P1[7:0]      (P1=0x0E00 -> ÷32 = 24.576MHz)
                18: cfg_entry = {8'h3F, 8'h00};   // MS2 P3[19:16]/P2[19:16]
                19: cfg_entry = {8'h40, 8'h00};   // MS2 P2[15:8]
                20: cfg_entry = {8'h41, 8'h00};   // MS2 P2[7:0]
                21: cfg_entry = {8'h12, 8'h4F};   // CLK2: MS2/整数/PLLA/8mA
                22: cfg_entry = {8'hB7, 8'hD2};   // 晶振负载 10 pF
                23: cfg_entry = {8'hBB, 8'hD0};   // Reg187 fanout enable（关键）
                24: cfg_entry = {8'hB1, 8'h20};   // PLLA 软复位
                25: cfg_entry = {8'h03, 8'hFB};   // 使能 CLK2（末项）
                default: cfg_entry = 16'h0000;
            endcase
        end
    endfunction

    //----------------------------------------------------------
    // 4. I2C 主机
    //----------------------------------------------------------
    wire        i2c_done;
    wire        ack_err;
    wire [15:0] ent = cfg_entry(idx);

    i2c_mst #(.CLK_HZ(50_000_000), .I2C_HZ(100_000)) u_i2c (
        .clk     (clk),
        .rst     (rst),
        .go      (go),
        .dev_w   (DEV_ADDR),
        .reg_a   (ent[15:8]),
        .dat     (ent[7:0]),
        .done    (i2c_done),
        .ack_err (ack_err),
        .scl     (scl),
        .sda     (sda)
    );

    //----------------------------------------------------------
    // 5. 扫描状态机
    //----------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            st<=S_SETTLE; mux_try<=3'd0; settle<=20'd0; idx<=6'd0;
            pend<=1'b1; go<=1'b0; ok_any<=1'b0; got_first<=1'b0;
            mux_first<=3'd0; hb<=25'd0;
        end else begin
            go <= 1'b0;
            if (st != S_DONE) hb <= hb + 1'b1;

            case (st)
            S_SETTLE: begin
                if (settle == SETTLE_MAX) begin
                    settle <= 20'd0; idx <= 6'd0; pend <= 1'b1; st <= S_PROBE;
                end else settle <= settle + 1'b1;
            end
            S_PROBE: begin
                if (pend) begin go <= 1'b1; pend <= 1'b0; end
                else if (i2c_done) begin
                    if (ack_err) st <= S_NEXT;
                    else begin
                        ok_any <= 1'b1;
                        if (!got_first) begin got_first <= 1'b1; mux_first <= mux_try; end
                        idx <= 6'd0; pend <= 1'b1; st <= S_CFG;
                    end
                end
            end
            S_CFG: begin
                if (pend) begin go <= 1'b1; pend <= 1'b0; end
                else if (i2c_done) begin
                    if (idx == N_ENT-1) st <= S_NEXT;
                    else begin idx <= idx + 1'b1; pend <= 1'b1; end
                end
            end
            S_NEXT: begin
                if (mux_try == 3'd7) st <= S_DONE;
                else begin mux_try <= mux_try + 1'b1; settle <= 20'd0; st <= S_SETTLE; end
            end
            S_DONE: ;
            default: st <= S_SETTLE;
            endcase
        end
    end

    assign mux_sel2 = mux_try[2];
    assign mux_sel1 = mux_try[1];
    assign mux_sel0 = mux_try[0];

    assign mux_b0 = mux_first[0];
    assign mux_b1 = mux_first[1];
    assign mux_b2 = mux_first[2];

    //----------------------------------------------------------
    // 6. PLL 复位：等 MS5351 配置完成后，再延迟约 1ms 释放
    //----------------------------------------------------------
    reg [16:0] pll_wait;
    always @(posedge clk) begin
        if (rst) pll_wait <= 17'd0;
        else if (ok_any && !(&pll_wait)) pll_wait <= pll_wait + 1'b1;
    end
    wire pll_rst = ~ok_any | (pll_wait != {17{1'b1}});   // 未配好或延迟未满 -> 复位

    //----------------------------------------------------------
    // 7. PLL 原语（UG306 §5.1 模板）
    //    CLKIN = N22(12.288MHz) -> CLKOUT0 = 49.152 MHz
    //----------------------------------------------------------
    wire clk_49m;
    wire pll_lock;

    PLL u_pll (
        .LOCK      (pll_lock),
        .CLKOUT0   (clk_49m),
        .CLKOUT1   (),
        .CLKOUT2   (),
        .CLKOUT3   (),
        .CLKOUT4   (),
        .CLKOUT5   (),
        .CLKOUT6   (),
        .CLKFBOUT  (),
        .CLKIN     (clk_in),
        .CLKFB     (1'b0),
        .RESET     (pll_rst),
        .PLLPWD    (1'b0),
        .RESET_I   (1'b0),
        .RESET_O   (1'b0),
        .FBDSEL    (6'd0),
        .IDSEL     (6'd0),
        .MDSEL     (7'd0),
        .MDSEL_FRAC(3'd0),
        .ODSEL0    (7'd0),
        .ODSEL0_FRAC(3'd0),
        .ODSEL1    (7'd0),
        .ODSEL2    (7'd0),
        .ODSEL3    (7'd0),
        .ODSEL4    (7'd0),
        .ODSEL5    (7'd0),
        .ODSEL6    (7'd0),
        .DT0       (4'd0),
        .DT1       (4'd0),
        .DT2       (4'd0),
        .DT3       (4'd0),
        .ICPSEL    (6'd0),
        .LPFRES    (3'd0),
        .LPFCAP    (2'd0),
        .PSSEL     (3'd0),
        .PSDIR     (1'b0),
        .PSPULSE   (1'b0),
        .ENCLK0    (1'b1),
        .ENCLK1    (1'b0),
        .ENCLK2    (1'b0),
        .ENCLK3    (1'b0),
        .ENCLK4    (1'b0),
        .ENCLK5    (1'b0),
        .ENCLK6    (1'b0),
        .SSCPOL    (1'b0),
        .SSCON     (1'b0),
        .SSCMDSEL  (7'd0),
        .SSCMDSEL_FRAC(3'd0)
    );

    defparam u_pll.CLK0_IN_SEL = 1'b0;
    defparam u_pll.CLK0_OUT_SEL = 1'b0;
    defparam u_pll.CLK1_IN_SEL = 1'b0;
    defparam u_pll.CLK1_OUT_SEL = 1'b0;
    defparam u_pll.CLK2_IN_SEL = 1'b0;
    defparam u_pll.CLK2_OUT_SEL = 1'b0;
    defparam u_pll.CLK3_IN_SEL = 1'b0;
    defparam u_pll.CLK3_OUT_SEL = 1'b0;
    defparam u_pll.CLK4_IN_SEL = 2'b00;
    defparam u_pll.CLK4_OUT_SEL = 1'b0;
    defparam u_pll.CLK5_IN_SEL = 1'b0;
    defparam u_pll.CLK5_OUT_SEL = 1'b0;
    defparam u_pll.CLK6_IN_SEL = 1'b0;
    defparam u_pll.CLK6_OUT_SEL = 1'b0;
    defparam u_pll.CLKFB_SEL = "INTERNAL";
    defparam u_pll.CLKOUT0_EN = "TRUE";
    defparam u_pll.CLKOUT0_DT_DIR = 1'b1;
    defparam u_pll.CLKOUT0_DT_STEP = 0;
    defparam u_pll.CLKOUT0_PE_COARSE = 0;
    defparam u_pll.CLKOUT0_PE_FINE = 0;
    defparam u_pll.CLKOUT1_EN = "FALSE";
    defparam u_pll.CLKOUT2_EN = "FALSE";
    defparam u_pll.CLKOUT3_EN = "FALSE";
    defparam u_pll.CLKOUT4_EN = "FALSE";
    defparam u_pll.CLKOUT5_EN = "FALSE";
    defparam u_pll.CLKOUT6_EN = "FALSE";
    defparam u_pll.DYN_DPA_EN = "FALSE";
    defparam u_pll.DYN_DT0_SEL = "FALSE";
    defparam u_pll.DYN_DT1_SEL = "FALSE";
    defparam u_pll.DYN_DT2_SEL = "FALSE";
    defparam u_pll.DYN_DT3_SEL = "FALSE";
    defparam u_pll.DYN_FBDIV_SEL = "FALSE";
    defparam u_pll.DYN_ICP_SEL = "FALSE";
    defparam u_pll.DYN_IDIV_SEL = "FALSE";
    defparam u_pll.DYN_LPF_SEL = "FALSE";
    defparam u_pll.DYN_MDIV_SEL = "FALSE";
    defparam u_pll.DYN_ODIV0_SEL = "FALSE";
    defparam u_pll.DYN_ODIV1_SEL = "FALSE";
    defparam u_pll.DYN_ODIV2_SEL = "FALSE";
    defparam u_pll.DYN_ODIV3_SEL = "FALSE";
    defparam u_pll.DYN_ODIV4_SEL = "FALSE";
    defparam u_pll.DYN_ODIV5_SEL = "FALSE";
    defparam u_pll.DYN_ODIV6_SEL = "FALSE";
    defparam u_pll.DYN_PE0_SEL = "FALSE";
    defparam u_pll.DYN_PE1_SEL = "FALSE";
    defparam u_pll.DYN_PE2_SEL = "FALSE";
    defparam u_pll.DYN_PE3_SEL = "FALSE";
    defparam u_pll.DYN_PE4_SEL = "FALSE";
    defparam u_pll.DYN_PE5_SEL = "FALSE";
    defparam u_pll.DYN_PE6_SEL = "FALSE";
    defparam u_pll.FBDIV_SEL = 1;
    defparam u_pll.FCLKIN = "24.576";
    defparam u_pll.ICP_SEL = 6'bXXXXXX;
    defparam u_pll.IDIV_SEL = 1;
    defparam u_pll.LPF_CAP = 2'b00;
    defparam u_pll.LPF_RES = 3'b000;
    defparam u_pll.MDIV_FRAC_SEL = 0;
    defparam u_pll.MDIV_SEL = 32;
    defparam u_pll.ODIV0_FRAC_SEL = 0;
    defparam u_pll.ODIV0_SEL = 16;
    defparam u_pll.ODIV1_SEL = 1;
    defparam u_pll.ODIV2_SEL = 1;
    defparam u_pll.ODIV3_SEL = 1;
    defparam u_pll.ODIV4_SEL = 1;
    defparam u_pll.ODIV5_SEL = 1;
    defparam u_pll.ODIV6_SEL = 1;
    defparam u_pll.RESET_I_EN = "FALSE";
    defparam u_pll.RESET_O_EN = "FALSE";
    defparam u_pll.SSC_EN = "FALSE";

    //----------------------------------------------------------
    // 8. 49.152 MHz 域：分频输出 + LED
    //----------------------------------------------------------
    reg [23:0] cnt49;   // 24 位（led_49m 用到 [22]）
    always @(posedge clk_49m)
        cnt49 <= cnt49 + 1'b1;

    assign p_raw    = cnt49[0];      // clk_49m ÷2 = 24.576 MHz（寄存器输出，可驱动 IO）
    assign p_div16  = cnt49[3];      // 49.152/16  = 3.072 MHz
    assign p_div256 = cnt49[7];      // 49.152/256 = 192 kHz
    assign p_clkin  = clk_in;        // N22 直通（12.288 MHz 复核）
    assign led_49m  = ~cnt49[22];    // 约 5.9 Hz 闪烁

    //----------------------------------------------------------
    // 9. LED（控制域）
    //----------------------------------------------------------
    wire scan_q = (st != S_DONE) ? hb[22] : 1'b0;
    assign led_lock = ~pll_lock;     // LOCK -> 亮（关键）
    assign led_cfg  = ~ok_any;       // 至少一档成功 -> 亮
    assign led_scan = ~scan_q;       // 扫描中闪

endmodule
