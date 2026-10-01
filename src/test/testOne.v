//=============================================================
// PT8211 音频测试 - Tang Mega 138K Pro
// 目标：跑通工具链 + 验证 PT8211 DAC 链路
// 输出：约 440 Hz 方波
//=============================================================
module audio_test (
    input  wire clk,        // 50 MHz, 引脚 V22
    input  wire rst_n,      // 复位按钮（若板子无复位，见下方说明）
    output wire bclk,       // E22 -> PT8211 BCLK
    output wire lrck,       // F24 -> PT8211 LRCK/WS
    output wire din,        // G24 -> PT8211 DIN
    output wire pa_en,      // H17 -> 功放使能
    output wire led         // 心跳 LED
);

    //----------------------------------------------------------
    // 复位同步器（异步断言，同步释放）
    //----------------------------------------------------------
    reg [1:0] rst_sync;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) rst_sync <= 2'b00;
        else        rst_sync <= {rst_sync[0], 1'b1};
    wire rst = ~rst_sync[1];

    //----------------------------------------------------------
    // 采样节拍：每 1024 个 clk 一次（50 MHz / 1024 ≈ 48.83 kHz）
    //----------------------------------------------------------
    reg [9:0] sample_cnt;
    wire sample_tick = (sample_cnt == 10'd1023);

    always @(posedge clk)
        if (rst) sample_cnt <= 10'd0;
        else     sample_cnt <= sample_cnt + 1'b1;

    //----------------------------------------------------------
    // 440 Hz 方波：f = f_s × inc / 2^16
    // 440 ≈ 48828 × 591 / 65536
    //----------------------------------------------------------
    reg [15:0] phase_acc;
    always @(posedge clk)
        if (rst)              phase_acc <= 16'd0;
        else if (sample_tick) phase_acc <= phase_acc + 16'd591;

    wire [15:0] sample = phase_acc[15] ? 16'h7FFF : 16'h8000;

    //----------------------------------------------------------
    // BCLK 生成：50 MHz / 32 = 1.5625 MHz
    //----------------------------------------------------------
    reg [4:0] clk_div;
    always @(posedge clk)
        if (rst) clk_div <= 5'd0;
        else     clk_div <= clk_div + 1'b1;

    wire bclk_int  = clk_div[4];
    wire bclk_fall = (clk_div == 5'd31);

    //----------------------------------------------------------
    // 位计数器：0..31，每帧 32 个 BCLK
    // bit_cnt[4]=0 -> 左声道（WS 高），=1 -> 右声道（WS 低）
    //----------------------------------------------------------
    reg [4:0] bit_cnt;
    always @(posedge clk)
        if (rst)              bit_cnt <= 5'd0;
        else if (sample_tick) bit_cnt <= 5'd0;
        else if (bclk_fall)   bit_cnt <= bit_cnt + 1'b1;

    //----------------------------------------------------------
    // 移位寄存器：加载 {左样本, 右样本}，每个 BCLK 移出 1 位
    //----------------------------------------------------------
    reg [31:0] shift_reg;
    reg        din_r;

    always @(posedge clk) begin
        if (rst) begin
            shift_reg <= 32'd0;
            din_r     <= 1'b0;
        end else if (sample_tick) begin
            shift_reg <= {sample, sample};
            din_r     <= sample[15];        // 左声道 MSB
        end else if (bclk_fall) begin
            shift_reg <= {shift_reg[30:0], 1'b0};
            din_r     <= shift_reg[30];     // 新 MSB
        end
    end

    //----------------------------------------------------------
    // 输出寄存器
    //----------------------------------------------------------
    reg bclk_r, lrck_r;
    always @(posedge clk) begin
        if (rst) begin
            bclk_r <= 1'b0;
            lrck_r <= 1'b0;
        end else begin
            bclk_r <= bclk_int;
            lrck_r <= ~bit_cnt[4];          // WS 高 = 左声道
        end
    end

    assign bclk  = bclk_r;
    assign lrck  = lrck_r;
    assign din   = din_r;
    assign pa_en = 1'b1;

    //----------------------------------------------------------
    // LED 心跳：约 1 Hz
    //----------------------------------------------------------
    reg [25:0] led_cnt;
    always @(posedge clk)
        if (rst) led_cnt <= 26'd0;
        else     led_cnt <= led_cnt + 1'b1;

    assign led = led_cnt[25];

endmodule