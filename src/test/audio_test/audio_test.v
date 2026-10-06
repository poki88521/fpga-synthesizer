//=============================================================
//  audio_test —— A. 正弦 + 颤音（连续信号质量测试）
//  板卡：Tang Mega 138K Pro (GW5AST-LV138FPG676A / FCPBG676A)
//  时钟：P16 = 50 MHz（实测有效）
//
//  输出：440 Hz 正弦（64 点 1/4 表 + 象限镜像），叠加约 1.5 Hz 的
//        音量颤动（tremolo，幅度在 50% ~ 100% 之间摆动），左右相同。
//
//  目的：验证「连续多采样」下信号是否平滑、有无爆音/断点/量化噪声。
//
//  LED：led_clk (M25) 系统时钟；led_lrck (N21) 采样节拍
//  时序：f_s = 50 MHz / 1024 = 48828.125 Hz；BCLK = 1.5625 MHz
//=============================================================
module audio_test (
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
    // 4. 位计数 0..31
    //----------------------------------------------------------
    reg [4:0] bit_cnt;
    always @(posedge clk) begin
        if (rst)              bit_cnt <= 5'd0;
        else if (sample_tick) bit_cnt <= 5'd0;
        else if (bclk_fall)   bit_cnt <= bit_cnt + 1'b1;
    end

    //----------------------------------------------------------
    // 5. 440 Hz 相位 + 正弦（1/4 表 + 象限镜像）
    //----------------------------------------------------------
    localparam [15:0] PHASE_INC = 16'd591;   // 440 Hz @ 48828.125 Hz

    reg [15:0] phase;
    always @(posedge clk) begin
        if (rst)              phase <= 16'd0;
        else if (sample_tick) phase <= phase + PHASE_INC;
    end

    function [15:0] quarter_of;
        input [5:0] s;
        begin
            case (s)
                6'd0:  quarter_of = 16'd402;
                6'd1:  quarter_of = 16'd1206;
                6'd2:  quarter_of = 16'd2009;
                6'd3:  quarter_of = 16'd2811;
                6'd4:  quarter_of = 16'd3612;
                6'd5:  quarter_of = 16'd4410;
                6'd6:  quarter_of = 16'd5205;
                6'd7:  quarter_of = 16'd5998;
                6'd8:  quarter_of = 16'd6786;
                6'd9:  quarter_of = 16'd7571;
                6'd10: quarter_of = 16'd8351;
                6'd11: quarter_of = 16'd9126;
                6'd12: quarter_of = 16'd9896;
                6'd13: quarter_of = 16'd10659;
                6'd14: quarter_of = 16'd11417;
                6'd15: quarter_of = 16'd12167;
                6'd16: quarter_of = 16'd12910;
                6'd17: quarter_of = 16'd13645;
                6'd18: quarter_of = 16'd14372;
                6'd19: quarter_of = 16'd15090;
                6'd20: quarter_of = 16'd15800;
                6'd21: quarter_of = 16'd16499;
                6'd22: quarter_of = 16'd17189;
                6'd23: quarter_of = 16'd17869;
                6'd24: quarter_of = 16'd18537;
                6'd25: quarter_of = 16'd19195;
                6'd26: quarter_of = 16'd19841;
                6'd27: quarter_of = 16'd20475;
                6'd28: quarter_of = 16'd21096;
                6'd29: quarter_of = 16'd21705;
                6'd30: quarter_of = 16'd22301;
                6'd31: quarter_of = 16'd22884;
                6'd32: quarter_of = 16'd23452;
                6'd33: quarter_of = 16'd24007;
                6'd34: quarter_of = 16'd24547;
                6'd35: quarter_of = 16'd25072;
                6'd36: quarter_of = 16'd25582;
                6'd37: quarter_of = 16'd26077;
                6'd38: quarter_of = 16'd26556;
                6'd39: quarter_of = 16'd27019;
                6'd40: quarter_of = 16'd27466;
                6'd41: quarter_of = 16'd27896;
                6'd42: quarter_of = 16'd28310;
                6'd43: quarter_of = 16'd28706;
                6'd44: quarter_of = 16'd29085;
                6'd45: quarter_of = 16'd29447;
                6'd46: quarter_of = 16'd29791;
                6'd47: quarter_of = 16'd30117;
                6'd48: quarter_of = 16'd30424;
                6'd49: quarter_of = 16'd30714;
                6'd50: quarter_of = 16'd30985;
                6'd51: quarter_of = 16'd31237;
                6'd52: quarter_of = 16'd31470;
                6'd53: quarter_of = 16'd31685;
                6'd54: quarter_of = 16'd31880;
                6'd55: quarter_of = 16'd32057;
                6'd56: quarter_of = 16'd32213;
                6'd57: quarter_of = 16'd32351;
                6'd58: quarter_of = 16'd32469;
                6'd59: quarter_of = 16'd32567;
                6'd60: quarter_of = 16'd32646;
                6'd61: quarter_of = 16'd32705;
                6'd62: quarter_of = 16'd32745;
                default: quarter_of = 16'd32765;
            endcase
        end
    endfunction

    wire [7:0] pidx = phase[15:8];      // 0..255

    reg signed [15:0] sine_val;
    always @(*) begin
        case (pidx[7:6])
            2'd0:    sine_val =  quarter_of(pidx[5:0]);
            2'd1:    sine_val =  quarter_of(6'd63 - pidx[5:0]);
            2'd2:    sine_val = -quarter_of(pidx[5:0]);
            default: sine_val = -quarter_of(6'd63 - pidx[5:0]);
        endcase
    end

    //----------------------------------------------------------
    // 6. 颤音包络：trem 0..255，每 128 个采样变化一次
    //    周期 = 256 * 128 / 48828 ≈ 0.67 s（约 1.5 Hz）
    //    env = 64 + trem/4  ->  64..127  (即 0.5 ~ 1.0)
    //----------------------------------------------------------
    reg [7:0] trem;
    reg [6:0] trem_div;
    reg       trem_dir;

    always @(posedge clk) begin
        if (rst) begin
            trem     <= 8'd0;
            trem_div <= 7'd0;
            trem_dir <= 1'b0;
        end else if (sample_tick) begin
            if (trem_div == 7'd127) begin
                trem_div <= 7'd0;
                if (!trem_dir) begin
                    if (trem == 8'd255) begin trem_dir <= 1'b1; trem <= trem - 1'b1; end
                    else                     trem <= trem + 1'b1;
                end else begin
                    if (trem == 8'd0)  begin trem_dir <= 1'b0; trem <= trem + 1'b1; end
                    else                     trem <= trem - 1'b1;
                end
            end else begin
                trem_div <= trem_div + 1'b1;
            end
        end
    end

    wire [7:0]         env    = 8'd64 + (trem >> 2);   // 64..127
    wire signed [7:0]  env_s  = env[6:0];              // <=127，正数
    wire signed [31:0] prod   = sine_val * env_s;      // 16s x 8s -> 32 位容器
    wire signed [15:0] sample = prod[22:7];            // 等价 (prod/128)，取恰好 16 位

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
                lrck_r    <= 1'b1;          // 左
                shift_reg <= sample;
                din_r     <= sample[15];
            end else if (bit_cnt == 5'd16) begin
                lrck_r    <= 1'b0;          // 右
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
