//=============================================================
// PT8211 音频测试 - Tang Mega 138K Pro
//-------------------------------------------------------------
// 目标：跑通工具链 + 验证 PT8211 DAC 链路
// 输出：约 440 Hz 方波
//
// 本版相对旧版的修改：
//   1) 取消外部复位端口 rst_n（原版未约束，可能被分配到悬空脚
//      导致 rst 恒有效、设计永远不出声），改为内部上电复位
//   2) BCLK 改用普通寄存器输出，不再用 ODDR
//      （ODDR 的 TX 使能极性未验证，若反则输出高阻、无时钟）
//   3) DIN 移位逻辑修正：原版有 MSB 被重复输出的 bug
//   4) LED 引脚补上（M25），用于观察时钟/复位是否正常
//
// PT8211 关键规格（来源：material/PT8211 V1.7_E.pdf）
//   - 格式：LSBJ / Japanese format，two's complement，MSB first
//   - DIN 在 BCK 上升沿被锁入（因此数据应在 BCK 下降沿更新）
//   - WS 低 = 右声道，WS 高 = 左声道
//   - 只取自 MSB 起的前 16 位，多余截断
//   - BCK <= 18.4 MHz，WS <= 384 kHz，不需要 MCLK
//=============================================================
module audio_test (
    input  wire clk,      // 50 MHz 有源晶振（V22）
    output wire bclk,     // E22 -> PT8211 BCK
    output wire lrck,     // F24 -> PT8211 WS
    output wire din,      // G24 -> PT8211 DIN
    output wire pa_en,    // H17 -> 功放使能（极性待确认）
    output wire led       // M25 -> 板载状态灯
);

    //----------------------------------------------------------
    // 1. 内部上电复位（无外部复位端口）
    //    por_cnt 上电为 0，计满后 rst 释放
    //    复位时长约 65536 / 50MHz = 1.31 ms
    //----------------------------------------------------------
    reg [15:0] por_cnt;

    always @(posedge clk)
        if (!(&por_cnt))
            por_cnt <= por_cnt + 1'b1;

    wire rst = ~(&por_cnt);   // 计满前为 1（复位中）

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
    // 3. BCLK 生成：每 16 拍翻转
    //    BCLK = 50 MHz / 32 = 1.5625 MHz（50% 占空比）
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
    // 5. DDS：440 Hz 方波
    //    phase_inc = 440 * 2^16 / f_s
    //              = 440 * 65536 / 48828.125 ≈ 590.5 -> 取 591
    //    实际频率 ≈ 591 * 48828.125 / 65536 ≈ 440.3 Hz
    //----------------------------------------------------------
    localparam [15:0] PHASE_INC = 16'd591;

    reg [15:0] phase_acc;

    always @(posedge clk) begin
        if (rst)              phase_acc <= 16'd0;
        else if (sample_tick) phase_acc <= phase_acc + PHASE_INC;
    end

    // 注意：方波为满量程，接通后音量较大，注意护耳
    wire [15:0] sample = phase_acc[15] ? 16'h7FFF : 16'h8000;

    //----------------------------------------------------------
    // 6. LRCK + DIN
    //    - 均在 BCLK 下降沿更新
    //    - bit_cnt == 0  : WS 拉高（左），加载样本，输出 MSB
    //    - bit_cnt == 16 : WS 拉低（右），加载样本，输出 MSB
    //    - 其余          : 依次移出后续位
    //
    //    【待确认】"MSB 紧贴 WS 跳变" 取自 LSBJ 的定义，
    //    但手册的 Figure 1/2 为图片，建议对照波形图核实。
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
                din_r     <= shift_reg[14]; // 下一位（已左移）
            end
        end
    end

    //----------------------------------------------------------
    // 7. 输出
    //----------------------------------------------------------
    assign bclk = bclk_r;
    assign lrck = lrck_r;
    assign din  = din_r;

    // 功放使能：复位期间关闭，复位释放后打开
    // 【待确认】若 XPT4809 的 EN 为低有效，改为 assign pa_en = rst;
    assign pa_en = ~rst;

    //----------------------------------------------------------
    // 8. LED 状态指示
    //    每来一次 sample_tick 递增，高位翻转成慢闪
    //    灯闪  -> 时钟在跑、复位已释放、采样节拍正常
    //    灯不闪 -> 时钟或复位有问题（可改用 P16 时钟试）
    //    led_div[15] 翻转周期约 2.7 s
    //----------------------------------------------------------
    reg [15:0] led_div;

    always @(posedge clk) begin
        if (rst)              led_div <= 16'd0;
        else if (sample_tick) led_div <= led_div + 1'b1;
    end

    assign led = led_div[15];

endmodule
