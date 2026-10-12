//============================================================================
//  ms5351_init —— MS5351 上电配置（让 CLK2 输出 24.576 MHz 给 FPGA 的 N22）
//
//  为什么需要它：
//    MS5351 上电默认输出 16 MHz（CLK2 的默认值）。PLC 若此时自由跑，
//    pll_49m 会锁到 16 MHz → 输出 ≈32 MHz 而不是 49.152 MHz → 采样率全错。
//    必须先用 I2C 把它配成 24.576 MHz，再让 PLL 锁定。
//
//  移植来源：board/pll_test/pll_test.v（上板实测锁定成功的版本）
//    · 配置表 26 项，与原文件**逐字节一致**（MS2 P1=0x0E00 → ÷32 = 24.576 MHz）
//    · 保留原来的「mux 档位扫描」：TWI 复用器的选择值在不同板子上可能不同，
//      扫描 0~7 直到 I2C 有 ACK，比写死一个值更稳
//
//  ⚠ 时钟要求（关键）：
//    本模块**必须**用不依赖 PLL 的时钟驱动（板载 clk50 / P16）。
//    如果用了 PLL 输出的 clk_sys，就会死锁 —— PLL 要等 MS5351 配好，
//    而配置逻辑又在等 PLL 出时钟。
//
//  ⚠ 与 PLL 的配合：
//    本模块的 ok 只在配置成功后拉高。上层应保证「ok 之前不要让 PLL 锁定」，
//    否则会锁到 16 MHz。full_top 的 POR（POR_BITS=22，约 84 ms @50 MHz）
//    远大于本模块的配置耗时（S_SETTLE 2 ms + 26 项 I2C ≈ 8 ms），
//    所以 POR 释放时 clkin 已是 24.576 MHz —— 这是它能正常工作的前提，
//    若将来调小了 POR_BITS，必须重新核算这个时序。
//
//  ⚠ 注意 pll_test.v 里 L91 那句「CLK2 = 12.288 MHz」是过时注释，
//    实际配置（L114）是 ÷32 = 24.576 MHz。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module ms5351_init #(
    parameter integer CLK_HZ = 50_000_000,   // 必须填**实际驱动 clk 的频率**
    parameter integer I2C_HZ = 100_000,
    // 每档 mux 试探前的等待拍数。/50MHz 时 100_000 = 2 ms（真实值，上板勿改小）。
    // 仿真为省时间可以调小 —— 仿真里没有 I2C 从机，8 档扫描本来每档都要等满。
    parameter integer SETTLE_MAX = 100_000
)(
    input  wire clk,          // 不依赖 PLL 的时钟（板载 50 MHz）
    //  ⚠ 必须是 `wire` 而不是 `reg`：scl/sda 是由内部 i2c_mst 实例驱动的，
    //    本模块自己不赋值。写成 `output reg scl` 会变成"两处驱动同一信号"，
    //    Gowin 报 EX3805 (Concurrent assignment to a non-net 'scl')。
    //    iverilog 对此宽容不报，是综合时才抓到的。
    output wire scl,
    //  ⚠ 必须显式写 `wire`：本文件有 `default_nettype none`，
    //    而 `inout` 端口只能是 net 类型。只写 `inout sda` 会报
    //    EX3094（Net type must be explicitly specified）+
    //    EX3675（Non-net port 'sda' cannot be of mode inout）。
    //    iverilog 不报这个错，是 Gowin 综合时抓到的。
    inout  wire sda,
    output reg  mux_sel0,
    output reg  mux_sel1,
    output reg  mux_sel2,
    output wire ok            // 至少一次 I2C 配置成功
);
    localparam [7:0]  DEV_ADDR   = 8'hC0;
    localparam integer N_ENT     = 26;

    localparam S_SETTLE = 3'd0,
               S_PROBE  = 3'd1,
               S_CFG    = 3'd2,
               S_NEXT   = 3'd3,
               S_DONE   = 3'd4;

    //----------------------------------------------------------
    // 自产上电复位（不依赖外部复位脚，保证上电就开始配置）
    //----------------------------------------------------------
    reg [19:0] por_cnt;
    always @(posedge clk)
        if (!(&por_cnt)) por_cnt <= por_cnt + 1'b1;
    wire rst = ~(&por_cnt);

    //----------------------------------------------------------
    // 状态与扫描寄存器
    //----------------------------------------------------------
    reg [2:0]  st;
    reg [2:0]  mux_try;
    reg [19:0] settle;
    reg  [5:0] idx;
    reg        go, pend;
    reg        ok_any;

    //----------------------------------------------------------
    // MS5351 配置表（与 board/pll_test/pll_test.v 逐字节一致）
    //   CLK2 = PLLA VCO 786.432 MHz ÷ 32 = 24.576 MHz
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
    // I2C 主机
    //----------------------------------------------------------
    wire        i2c_done;
    wire        ack_err;
    wire [15:0] ent = cfg_entry(idx);

    i2c_mst #(.CLK_HZ(CLK_HZ), .I2C_HZ(I2C_HZ)) u_i2c (
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
    // 扫描状态机（照搬 pll_test.v，去掉测试用的探针输出）
    //   先对每个 mux 档位试一次单字节探测，通了才做完整 26 项配置
    //----------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            st      <= S_SETTLE;
            mux_try <= 3'd0;
            settle  <= 20'd0;
            idx     <= 6'd0;
            pend    <= 1'b1;
            go      <= 1'b0;
            ok_any  <= 1'b0;
        end else begin
            go <= 1'b0;

            case (st)
            S_SETTLE: begin
                if (settle == SETTLE_MAX) begin
                    settle <= 20'd0; idx <= 6'd0; pend <= 1'b1; st <= S_PROBE;
                end else settle <= settle + 1'b1;
            end
            S_PROBE: begin
                if (pend) begin go <= 1'b1; pend <= 1'b0; end
                else if (i2c_done) begin
                    if (ack_err) st <= S_NEXT;              // 这个 mux 档位不通
                    else begin
                        ok_any <= 1'b1;                     // 通了，开始正式配置
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

    // TWI 复用器选择
    always @(*) begin
        mux_sel0 = mux_try[0];
        mux_sel1 = mux_try[1];
        mux_sel2 = mux_try[2];
    end

    assign ok = ok_any;

endmodule
`default_nettype wire
