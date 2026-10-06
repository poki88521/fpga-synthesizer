//=============================================================
//  bits_test —— B. 幅度阶梯（位深 / MSB 对齐测试）
//  板卡：Tang Mega 138K Pro (GW5AST-LV138FPG676A / FCPBG676A)
//  时钟：P16 = 50 MHz
//
//  输出：440 Hz 方波，幅度每约 1.34 s 下降一档：
//        32767 -> 8191 -> 2047 -> 511 -> 127 -> 31 -> 7 -> 1 -> 循环
//
//  目的：验证 DAC 位深 / MSB 对齐。
//    - 若对齐正确：音量应逐档明显变小，最后一档（±1 LSB）几乎听不见
//    - 若 MSB 对齐错误（数据移位/取错位）：
//        小的幅度档会仍然很响，或"阶梯"不按预期递减
//
//  注意：±1 LSB 档本来就应几乎无声，这是正常现象，不是故障。
//
//  LED：led_clk (M25) 系统时钟；led_lrck (N21) 采样节拍
//  时序：f_s = 48828.125 Hz；BCLK = 1.5625 MHz
//=============================================================
module bits_test (
    input  wire clk,
    output wire bclk,
    output wire lrck,
    output wire din,
    output wire pa_en,
    output wire led_clk,
    output wire led_lrck
);

    //----------------------------------------------------------
    // 1. 上电复位
    //----------------------------------------------------------
    reg [15:0] por_cnt;
    always @(posedge clk)
        if (!(&por_cnt)) por_cnt <= por_cnt + 1'b1;
    wire rst = ~(&por_cnt);

    //----------------------------------------------------------
    // 2. 采样节拍 /1024
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
    // 3. BCLK /32
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
    // 4. 位计数
    //----------------------------------------------------------
    reg [4:0] bit_cnt;
    always @(posedge clk) begin
        if (rst)              bit_cnt <= 5'd0;
        else if (sample_tick) bit_cnt <= 5'd0;
        else if (bclk_fall)   bit_cnt <= bit_cnt + 1'b1;
    end

    //----------------------------------------------------------
    // 5. 440 Hz 相位
    //----------------------------------------------------------
    localparam [15:0] PHASE_INC = 16'd591;

    reg [15:0] phase;
    always @(posedge clk) begin
        if (rst)              phase <= 16'd0;
        else if (sample_tick) phase <= phase + PHASE_INC;
    end

    //----------------------------------------------------------
    // 6. 幅度阶梯：每 65536 个采样换一档（约 1.34 s）
    //----------------------------------------------------------
    reg [16:0] amp_hold;
    reg [2:0]  amp_idx;

    always @(posedge clk) begin
        if (rst) begin
            amp_hold <= 17'd0;
            amp_idx  <= 3'd0;
        end else if (sample_tick) begin
            if (amp_hold == 17'd65535) begin
                amp_hold <= 17'd0;
                amp_idx  <= amp_idx + 1'b1;
            end else begin
                amp_hold <= amp_hold + 1'b1;
            end
        end
    end

    function signed [15:0] amp_of;
        input [2:0] i;
        begin
            case (i)
                3'd0:    amp_of = 16'sd32767;
                3'd1:    amp_of = 16'sd8191;
                3'd2:    amp_of = 16'sd2047;
                3'd3:    amp_of = 16'sd511;
                3'd4:    amp_of = 16'sd127;
                3'd5:    amp_of = 16'sd31;
                3'd6:    amp_of = 16'sd7;
                default: amp_of = 16'sd1;
            endcase
        end
    endfunction

    wire signed [15:0] amp    = amp_of(amp_idx);
    wire signed [15:0] sample = phase[15] ? amp : -amp;

    //----------------------------------------------------------
    // 7. LRCK + DIN
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
                lrck_r    <= 1'b1;
                shift_reg <= sample;
                din_r     <= sample[15];
            end else if (bit_cnt == 5'd16) begin
                lrck_r    <= 1'b0;
                shift_reg <= sample;
                din_r     <= sample[15];
            end else begin
                shift_reg <= {shift_reg[14:0], 1'b0};
                din_r     <= shift_reg[14];
            end
        end
    end

    //----------------------------------------------------------
    // 8. 输出 + LED
    //----------------------------------------------------------
    assign bclk  = bclk_r;
    assign lrck  = lrck_r;
    assign din   = din_r;
    assign pa_en = ~rst;

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
