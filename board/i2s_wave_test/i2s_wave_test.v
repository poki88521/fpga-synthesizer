// [2026-10-06 12:00]  本文件时间戳（用于校验是否被外部覆盖）
//=============================================================
//  i2s_wave_test —— T-1：I2S 波形实测（同时送 PT8211 与 PMOD2）
//  板卡：Tang Mega 138K Pro (GW5AST-LV138FPG676A / FCPBG676A)
//  时钟：P16 = 50 MHz
//
//  目的：把 I2S 三线（BCLK / LRCK / DIN）**额外复制到 PMOD2**，
//        便于用示波器直接测波形与相位关系（PT8211 侧引脚小，不好探）。
//        音频仍照常送 PT8211（440 Hz 方波），可同时听声。
//
//  可实测项（对应测试清单 2.1~2.4）：
//    2.1 bclk (E22 / C21)  = 1.5625 MHz 方波（50 MHz ÷ 32）
//    2.2 lrck (F24 / B20)  = 48.83 kHz，50% 占空比（= f_s = 50MHz/1024）
//    2.3 din  (G24 / B19)  有数据翻转；每个 LRCLK 半周期恰 16 位
//    2.4 相位：DIN 在 BCLK **下降沿**更新；**MSB 紧贴 WS 跳变**；WS 高=左
//
//  PMOD2 输出：
//    C21  PMOD2_IO0 : bclk 复制        1.5625 MHz
//    B20  PMOD2_IO1 : lrck 复制        48.83 kHz
//    B19  PMOD2_IO2 : din  复制
//    A17  PMOD2_IO3 : lrck ÷2048       约 23.8 Hz（帧标记，慢速便于触发/观察）
//
//  LED（低电平点亮，代码已取反，约 0.67 s 周期闪烁）：
//    led_clk  (M25/LED3) : 系统时钟在跑
//    led_lrck (L20/LED2) : 采样节拍在跑
//    led_bclk (R26/LED1) : BCLK 在跑
//
//  注意：不再使用 N22（现为 USR_CLK_IN 输入）。
//=============================================================
module i2s_wave_test (
    input  wire clk,          // P16, 50 MHz
    output wire bclk,         // E22 -> PT8211 BCK
    output wire lrck,         // F24 -> PT8211 WS
    output wire din,          // G24 -> PT8211 DIN
    output wire pa_en,        // H17 -> 功放使能（Pro 板高电平有效）
    output wire m_bclk,       // C21  PMOD2_IO0  bclk 复制
    output wire m_lrck,       // B20  PMOD2_IO1  lrck 复制
    output wire m_din,        // B19  PMOD2_IO2  din 复制
    output wire m_slow,       // A17  PMOD2_IO3  lrck÷2048（约 23.8 Hz）
    output wire led_clk,      // M25
    output wire led_lrck,     // L20
    output wire led_bclk      // R26
);

    //----------------------------------------------------------
    // 1. 内部上电复位
    //----------------------------------------------------------
    reg [15:0] por_cnt;

    always @(posedge clk)
        if (!(&por_cnt))
            por_cnt <= por_cnt + 1'b1;

    wire rst = ~(&por_cnt);

    //----------------------------------------------------------
    // 2. 采样节拍：每 1024 拍一次（f_s = 50MHz/1024 = 48828.125 Hz）
    //----------------------------------------------------------
    reg [9:0] sample_cnt;
    reg       sample_tick;

    always @(posedge clk) begin
        if (rst) begin
            sample_cnt  <= 10'd0;
            sample_tick <= 1'b0;
        end else if (sample_cnt == 10'd1023) begin
            sample_cnt  <= 10'd0;
            sample_tick <= 1'b1;
        end else begin
            sample_cnt  <= sample_cnt + 1'b1;
            sample_tick <= 1'b0;
        end
    end

    //----------------------------------------------------------
    // 3. BCLK：每 16 拍翻转 → 50 MHz / 32 = 1.5625 MHz
    //    一个采样周期 1024 拍 = 32 个 BCLK
    //----------------------------------------------------------
    reg [3:0] bclk_div;
    reg       bclk_r;

    always @(posedge clk) begin
        if (rst) begin
            bclk_div <= 4'd0;
            bclk_r   <= 1'b0;
        end else if (bclk_div == 4'd15) begin
            bclk_div <= 4'd0;
            bclk_r   <= ~bclk_r;
        end else begin
            bclk_div <= bclk_div + 1'b1;
        end
    end

    wire bclk_fall = (bclk_div == 4'd15) && bclk_r;   // BCLK 下降沿：数据在此更新

    //----------------------------------------------------------
    // 4. 位计数 0..31（0..15 左声道 WS 高；16..31 右声道 WS 低）
    //----------------------------------------------------------
    reg [4:0] bit_cnt;

    always @(posedge clk) begin
        if (rst)              bit_cnt <= 5'd0;
        else if (sample_tick) bit_cnt <= 5'd0;
        else if (bclk_fall)   bit_cnt <= bit_cnt + 1'b1;
    end

    //----------------------------------------------------------
    // 5. 440 Hz 方波（半量程）
    //    phase_inc = 440 * 2^16 / f_s ≈ 591
    //----------------------------------------------------------
    localparam [15:0] PHASE_INC = 16'd591;

    reg [15:0] phase_acc;

    always @(posedge clk) begin
        if (rst)              phase_acc <= 16'd0;
        else if (sample_tick) phase_acc <= phase_acc + PHASE_INC;
    end

    wire signed [15:0] sample = phase_acc[15] ? 16'sd16384 : -16'sd16384;

    //----------------------------------------------------------
    // 6. LRCK + DIN（均在 BCLK 下降沿更新）
    //----------------------------------------------------------
    reg [15:0] shift_reg;
    reg        lrck_r;
    reg        din_r;

    always @(posedge clk) begin
        if (rst) begin
            shift_reg <= 16'd0;
            lrck_r    <= 1'b0;
            din_r     <= 1'b0;
        end else if (sample_tick) begin
            lrck_r <= 1'b0;
        end else if (bclk_fall) begin
            if (bit_cnt == 5'd0) begin
                lrck_r    <= 1'b1;         // WS 高 = 左声道
                shift_reg <= sample;
                din_r     <= sample[15];   // MSB（紧贴 WS 跳变）
            end else if (bit_cnt == 5'd16) begin
                lrck_r    <= 1'b0;         // WS 低 = 右声道
                shift_reg <= sample;
                din_r     <= sample[15];   // MSB
            end else begin
                shift_reg <= {shift_reg[14:0], 1'b0};
                din_r     <= shift_reg[14];
            end
        end
    end

    //----------------------------------------------------------
    // 7. 输出（PT8211 + PMOD2 复制）
    //----------------------------------------------------------
    assign bclk   = bclk_r;
    assign lrck   = lrck_r;
    assign din    = din_r;
    assign pa_en  = ~rst;

    assign m_bclk = bclk_r;
    assign m_lrck = lrck_r;
    assign m_din  = din_r;

    //----------------------------------------------------------
    // 8. 慢速帧标记：lrck ÷2048 ≈ 23.8 Hz（便于示波器慢速/触发）
    //----------------------------------------------------------
    reg [11:0] slow_cnt;

    always @(posedge clk) begin
        if (rst)              slow_cnt <= 12'd0;
        else if (sample_tick) slow_cnt <= slow_cnt + 1'b1;
    end

    assign m_slow = slow_cnt[10];

    //----------------------------------------------------------
    // 9. LED 节拍监测（低电平点亮 → 取反，约 0.67 s 周期）
    //----------------------------------------------------------
    reg [24:0] cnt_clk;
    reg [14:0] cnt_lrck;
    reg [19:0] cnt_bclk;

    always @(posedge clk) begin
        if (rst) cnt_clk <= 25'd0;
        else     cnt_clk <= cnt_clk + 1'b1;
    end

    always @(posedge clk) begin
        if (rst)              cnt_lrck <= 15'd0;
        else if (sample_tick) cnt_lrck <= cnt_lrck + 1'b1;
    end

    always @(posedge clk) begin
        if (rst)            cnt_bclk <= 20'd0;
        else if (bclk_fall) cnt_bclk <= cnt_bclk + 1'b1;
    end

    assign led_clk  = ~cnt_clk[24];
    assign led_lrck = ~cnt_lrck[14];
    assign led_bclk = ~cnt_bclk[19];

endmodule
