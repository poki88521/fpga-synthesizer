//=============================================================
//  lr_channel_test —— 左右声道分离测试（PT8211 / I2S-LSBJ）
//  板卡：Tang Mega 138K Pro (GW5AST-LV138FPG676A / FCPBG676A)
//  时钟：P16 = 50 MHz（实测有效）
//
//  目的：用「左=440 Hz、右=880 Hz」两种音高区分左右声道，
//        同时据此判定 PT8211 的 WS 极性与左右声道对应关系（H9）。
//
//  判读（PT8211 手册：WS 高 = 左声道，WS 低 = 右声道）：
//    若正确 -> 左耳 440 Hz、右耳 880 Hz
//    若相反 -> 左耳 880 Hz、右耳 440 Hz（此时需把 WS 极性取反）
//
//  LED（板上低电平点亮，代码已取反）：
//    led_clk  (M25) : 系统时钟心跳
//    led_lrck (N21) : 采样节拍
//  说明：不使用 N22（该脚可疑，且未来要留给 USR_CLK_IN）。
//
//  时序：f_s  = 50 MHz / 1024 = 48828.125 Hz
//        BCLK = 50 MHz / 32   = 1.5625 MHz
//=============================================================
module lr_channel_test (
    input  wire clk,        // P16, 50 MHz
    output wire bclk,       // E22 -> PT8211 BCK
    output wire lrck,       // F24 -> PT8211 WS
    output wire din,        // G24 -> PT8211 DIN
    output wire pa_en,      // H17 -> 功放使能（Pro 板高电平有效）
    output wire led_clk,    // M25 (USR_LED.3)
    output wire led_lrck    // N21 (USR_LED.4)
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
    // 2. 采样节拍：每 1024 拍一次
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
    // 3. BCLK：每 16 拍翻转 -> 1.5625 MHz
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

    wire bclk_fall = (bclk_div == 4'd15) && bclk_r;

    //----------------------------------------------------------
    // 4. 位计数 0..31
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
    // 5. 两个音高：左 440 Hz、右 880 Hz（方波，半量程）
    //    inc = f * 2^16 / f_s
    //    440 : 440 * 65536 / 48828.125 ≈ 590.5 -> 591
    //    880 : 880 * 65536 / 48828.125 ≈ 1181.0 -> 1181
    //----------------------------------------------------------
    localparam [15:0] INC_L = 16'd591;    // 左 440 Hz
    localparam [15:0] INC_R = 16'd1181;   // 右 880 Hz

    reg [15:0] phase_l, phase_r;

    always @(posedge clk) begin
        if (rst) begin
            phase_l <= 16'd0;
            phase_r <= 16'd0;
        end else if (sample_tick) begin
            phase_l <= phase_l + INC_L;
            phase_r <= phase_r + INC_R;
        end
    end

    wire signed [15:0] sample_l = phase_l[15] ? 16'sd16384 : -16'sd16384;
    wire signed [15:0] sample_r = phase_r[15] ? 16'sd16384 : -16'sd16384;

    //----------------------------------------------------------
    // 6. LRCK + DIN（BCLK 下降沿更新）
    //    bit_cnt == 0  : WS 拉高（左），加载 sample_l，输出 MSB
    //    bit_cnt == 16 : WS 拉低（右），加载 sample_r，输出 MSB
    //    其余          : 移出后续位
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
                lrck_r    <= 1'b1;          // WS 高 = 左声道
                shift_reg <= sample_l;
                din_r     <= sample_l[15];  // MSB
            end else if (bit_cnt == 5'd16) begin
                lrck_r    <= 1'b0;          // WS 低 = 右声道
                shift_reg <= sample_r;
                din_r     <= sample_r[15];  // MSB
            end else begin
                shift_reg <= {shift_reg[14:0], 1'b0};
                din_r     <= shift_reg[14];
            end
        end
    end

    //----------------------------------------------------------
    // 7. 输出
    //----------------------------------------------------------
    assign bclk  = bclk_r;
    assign lrck  = lrck_r;
    assign din   = din_r;
    assign pa_en = ~rst;

    //----------------------------------------------------------
    // 8. LED 节拍监测（低电平点亮 -> 取反）
    //----------------------------------------------------------
    reg [24:0] cnt_clk;
    reg [14:0] cnt_lrck;

    always @(posedge clk) begin
        if (rst) cnt_clk <= 25'd0;
        else     cnt_clk <= cnt_clk + 1'b1;
    end

    always @(posedge clk) begin
        if (rst)              cnt_lrck <= 15'd0;
        else if (sample_tick) cnt_lrck <= cnt_lrck + 1'b1;
    end

    assign led_clk  = ~cnt_clk[24];
    assign led_lrck = ~cnt_lrck[14];

endmodule
