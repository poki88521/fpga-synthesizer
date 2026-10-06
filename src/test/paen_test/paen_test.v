//=============================================================
//  paen_test —— E. 功放使能（PA_EN）测试
//  板卡：Tang Mega 138K Pro (GW5AST-LV138FPG676A / FCPBG676A)
//  时钟：P16 = 50 MHz
//
//  输出：440 Hz 方波（幅度 16384），同时 pa_en 以约 1.34 s 为半周期
//        在 0 / 1 之间翻转。
//
//  目的：判定 PA_EN 的作用与极性。
//    观察耳机声音：
//      - 声音随 pa_en 周期性地"响 / 静"交替 -> PA_EN 确实控制输出通路
//          且哪半周期响，即代表有效电平（本代码高有效，若"低有效"
//          则表现为反相：安静/响的时间互换）
//      - 声音始终响、不随 pa_en 变化   -> 耳机通路不经 PA_EN（或该脚
//          在耳机模式下无效），说明它只影响扬声器功放
//
//  LED：led_clk (M25) 系统时钟；led_lrck (N21) 采样节拍
//  时序：f_s = 48828.125 Hz；BCLK = 1.5625 MHz
//=============================================================
module paen_test (
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
    // 5. 440 Hz 方波（幅度 16384）
    //----------------------------------------------------------
    localparam [15:0] PHASE_INC = 16'd591;

    reg [15:0] phase;
    always @(posedge clk) begin
        if (rst)              phase <= 16'd0;
        else if (sample_tick) phase <= phase + PHASE_INC;
    end

    wire signed [15:0] sample = phase[15] ? 16'sd16384 : -16'sd16384;

    //----------------------------------------------------------
    // 6. PA_EN 翻转：每 65536 个采样翻转一次（约 1.34 s 半周期）
    //----------------------------------------------------------
    reg [16:0] pa_cnt;
    always @(posedge clk) begin
        if (rst)              pa_cnt <= 17'd0;
        else if (sample_tick) pa_cnt <= pa_cnt + 1'b1;
    end

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
    assign pa_en = rst ? 1'b0 : pa_cnt[16];   // 复位时关；之后约 1.34 s 翻转

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
