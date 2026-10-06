//=============================================================
//  i2s_test —— PT8211 (I2S / LSBJ) 音频输出测试
//  板卡：Tang Mega 138K Pro (GW5AST-LV138FPG676A / FCPBG676A)
//  时钟：P16 = 50 MHz（实测有效；V22 无效，见测试清单第 0 级）
//
//  输出：440 Hz 方波（左右声道相同），送往 PT8211
//
//  不依赖 GAO：用 3 个 LED 观察内部节拍（板上 LED 低电平点亮）
//    led_clk  : 系统时钟心跳        （clk 在跑 -> 闪）
//    led_lrck : 采样节拍 LRCK 累加   （sample_tick 在跑 -> 闪）
//    led_bclk : BCLK 边沿累加        （BCLK 在跑 -> 闪）
//  三灯均以约 0.67 s 周期闪烁；任一不闪即对应环节没跑。
//
//  PT8211 关键规格（来源：material/PT8211 V1.7_E.pdf）
//    - 16-bit，LSBJ（Japanese）格式，two's complement，MSB first
//    - MSB 紧贴 WS 跳变；WS 高 = 左声道，WS 低 = 右声道
//    - DIN 在 BCK 上升沿被锁入（数据应在 BCK 下降沿更新）
//    - 只取自 MSB 起前 16 位；BCK <= 18.4 MHz；WS <= 384 kHz；不需要 MCLK
//
//  时序：f_s = 50 MHz / 1024 = 48828.125 Hz
//        BCLK = 50 MHz / 32  = 1.5625 MHz
//        440 Hz 频率字 = 440 * 2^16 / f_s ≈ 591
//=============================================================
module i2s_test (
    input  wire clk,        // P16, 50 MHz
    output wire bclk,       // E22 -> PT8211 BCK
    output wire lrck,       // F24 -> PT8211 WS
    output wire din,        // G24 -> PT8211 DIN
    output wire pa_en,      // H17 -> 功放使能（Pro 板高电平有效）
    output wire led_clk,    // M25 (USR_LED.3)
    output wire led_lrck,   // N21 (USR_LED.4)
    output wire led_bclk    // N22 (USR_LED.5)
);

    //----------------------------------------------------------
    // 1. 内部上电复位（无外部复位端口）
    //    复位时长 ≈ 65536 / 50 MHz = 1.31 ms
    //----------------------------------------------------------
    reg [15:0] por_cnt;

    always @(posedge clk)
        if (!(&por_cnt))
            por_cnt <= por_cnt + 1'b1;

    wire rst = ~(&por_cnt);

    //----------------------------------------------------------
    // 2. 采样节拍：每 1024 拍一次
    //    f_s = 50 MHz / 1024 = 48828.125 Hz
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

    // BCLK 下降沿：数据在此更新
    wire bclk_fall = (bclk_div == 4'd15) && bclk_r;

    //----------------------------------------------------------
    // 4. 位计数 0..31（一个采样周期 32 个 BCLK）
    //    0..15  : 左声道（WS 高）
    //    16..31 : 右声道（WS 低）
    //----------------------------------------------------------
    reg [4:0] bit_cnt;

    always @(posedge clk) begin
        if (rst)              bit_cnt <= 5'd0;
        else if (sample_tick) bit_cnt <= 5'd0;
        else if (bclk_fall)   bit_cnt <= bit_cnt + 1'b1;
    end

    //----------------------------------------------------------
    // 5. 440 Hz 方波
    //    phase_inc = 440 * 2^16 / f_s ≈ 590.5 -> 591
    //    实际 ≈ 591 * 48828.125 / 65536 ≈ 440.3 Hz
    //    幅度取半量程（±16384），避免过响
    //----------------------------------------------------------
    localparam [15:0] PHASE_INC = 16'd591;

    reg [15:0] phase_acc;

    always @(posedge clk) begin
        if (rst)              phase_acc <= 16'd0;
        else if (sample_tick) phase_acc <= phase_acc + PHASE_INC;
    end

    wire signed [15:0] sample = phase_acc[15] ? 16'sd16384 : -16'sd16384;

    //----------------------------------------------------------
    // 6. LRCK + DIN
    //    - 均在 BCLK 下降沿更新
    //    - bit_cnt == 0  : WS 拉高（左），加载样本，输出 MSB
    //    - bit_cnt == 16 : WS 拉低（右），加载样本，输出 MSB
    //    - 其余          : 依次移出后续位
    //    【待核实】"MSB 紧贴 WS 跳变" 需对照 PT8211 波形图确认
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
            // 采样边界先置静默，等 bit_cnt 归零后再发
            lrck_r <= 1'b0;
        end else if (bclk_fall) begin
            if (bit_cnt == 5'd0) begin
                lrck_r    <= 1'b1;         // WS 高 = 左声道
                shift_reg <= sample;
                din_r     <= sample[15];   // MSB
            end else if (bit_cnt == 5'd16) begin
                lrck_r    <= 1'b0;         // WS 低 = 右声道
                shift_reg <= sample;
                din_r     <= sample[15];   // MSB
            end else begin
                shift_reg <= {shift_reg[14:0], 1'b0};
                din_r     <= shift_reg[14]; // 下一位
            end
        end
    end

    //----------------------------------------------------------
    // 7. 输出
    //----------------------------------------------------------
    assign bclk  = bclk_r;
    assign lrck  = lrck_r;
    assign din   = din_r;
    assign pa_en = ~rst;      // 复位期间关，复位释放后开（Pro 板高有效）

    //----------------------------------------------------------
    // 8. LED 节拍监测（板上 LED 低电平点亮 → 取反）
    //    三者闪烁周期均约 0.67 s：
    //      cnt_clk[24]  @50 MHz    : 2^24 / 50e6      = 0.335 s 半周期
    //      cnt_lrck[14] @48828 Hz  : 2^14 / 48828     = 0.335 s 半周期
    //      cnt_bclk[19] @1.5625 MHz: 2^19 / 1.5625e6  = 0.335 s 半周期
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
