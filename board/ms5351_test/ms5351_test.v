// [2026-10-05 22:25]  本文件时间戳（用于校验是否被外部覆盖）
//=============================================================
//  ms5351_test —— 方案E：配置 MS5351 的 CLK2（USR_CLK_IN 的真实来源），出 12.288 MHz
//  板卡：Tang Mega 138K Pro (GW5AST-LV138FPG676A / FCPBG676A)
//
//  【关键更正】据 Dock 原理图 CLOCK 页坐标分析：
//      USR_CLK_IN 源自 MS5351 U2(PLL1) 的 CLK2，连到 FPGA 的 N22。
//    此前一直配置的是 CLK0 -> 所以 N22 从未被驱动（16MHz 是 CLK2 默认输出，
//    被 Reg3=0xFF 关掉后即成悬空/杂波）。
//    => 本次改为配置并「使能 CLK2」（MS2 分频 + Reg18 控制 + Reg3 使能 CLK2）。
//
//  配置（PLLA VCO = 786.432 MHz，MS2 ÷64 -> 12.288 MHz）：
//    PLLA  P1=0x0DBA, P2=0x067E, P3=0x0C35
//    MS2   P1=0x1E00, P2=0,      P3=1
//    Reg18 (CLK2) = 0x4F（MS2 / 整数 / PLLA / 8mA）
//    Reg187 = 0xD0（使能 fanout，否则输出不出来）
//    Reg3  = 0xFB（只使能 CLK2）
//
//  仍保留 mux 扫描：凡能 ACK 的档位都按其上配置（实际只有 1 档会 ACK）。
//
//  LED（低电平点亮，代码已取反）：
//    led_ok   (M25/LED3) : 至少一档 ACK+配置成功 -> 亮
//    led_err  (R26/LED1) : 8 档全 NACK -> 亮
//    led_scan (L20/LED2) : 扫描中 -> 闪；结束 -> 灭
//    led_in   (N21/LED4) : N22 输入有时钟 -> 闪
//  示波器测点：N22 直通 -> PMOD2：dbg_a0=C21(IO0) / dbg_a1=B20(IO1)
//  首个成功 mux 值 -> PMOD2：mux_b0=B19(IO2) / mux_b1=A17(IO3) / mux_b2=B21(IO4)
//=============================================================
module ms5351_test (
    input  wire clk,            // P16, 50 MHz
    inout  wire scl,            // K25 -> IIC_SCL_MAIN
    inout  wire sda,            // K26 -> IIC_SDA_MAIN
    input  wire clk_in,         // N22 <- USR_CLK_IN
    output wire mux_sel2,       // P26 = SEL2
    output wire mux_sel1,       // P19 = SEL1
    output wire mux_sel0,       // N19 = SEL0
    output wire led_ok,         // M25
    output wire led_err,        // R26
    output wire led_scan,       // L20
    output wire led_in,         // N21
    output wire mux_b0,         // B19  (PMOD2_IO2)
    output wire mux_b1,         // A17  (PMOD2_IO3)
    output wire mux_b2,         // B21  (PMOD2_IO4)
    output wire dbg_a0,         // C21  (PMOD2_IO0) <- N22 直通
    output wire dbg_a1          // B20  (PMOD2_IO1) <- N22 直通
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
    // 1. 上电复位
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
    // 3. 配置表（目标：CLK2 = 12.288 MHz）
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
                16: cfg_entry = {8'h3D, 8'h1E};   // MS2 P1[15:8]
                17: cfg_entry = {8'h3E, 8'h00};   // MS2 P1[7:0]      (P1=0x1E00 -> ÷64)
                18: cfg_entry = {8'h3F, 8'h00};   // MS2 P3[19:16]/P2[19:16]
                19: cfg_entry = {8'h40, 8'h00};   // MS2 P2[15:8]
                20: cfg_entry = {8'h41, 8'h00};   // MS2 P2[7:0]
                21: cfg_entry = {8'h12, 8'h4F};   // CLK2: MS2/整数/PLLA/8mA
                22: cfg_entry = {8'hB7, 8'hD2};   // 晶振负载 10 pF
                23: cfg_entry = {8'hBB, 8'hD0};   // Reg187 fanout enable（关键）
                24: cfg_entry = {8'hB1, 8'h20};   // PLLA 软复位
                25: cfg_entry = {8'h03, 8'hFB};   // 使能 CLK2（仅 CLK2）
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
    // 5. 扫描状态机（每档尝试配置）
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
    // 6. clk_in 计数 / LED / 直通输出
    //----------------------------------------------------------
    reg  [2:0]  sync;
    reg  [24:0] cnt_in;

    always @(posedge clk) begin
        if (rst) begin
            sync   <= 3'd0;
            cnt_in <= 25'd0;
        end else begin
            sync <= {sync[1:0], clk_in};
            if (sync[2] != sync[1]) cnt_in <= cnt_in + 1'b1;
        end
    end

    wire scan_q = (st != S_DONE) ? hb[22] : 1'b0;
    assign led_ok   = ~ok_any;
    assign led_err  =  ok_any;
    assign led_scan = ~scan_q;
    assign led_in   = ~cnt_in[23];

    assign dbg_a0 = clk_in;
    assign dbg_a1 = clk_in;

endmodule
