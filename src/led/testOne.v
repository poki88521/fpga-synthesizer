// ============================================================
// Tang Mega 138K Pro LCD 倒计时 + 颜色闪烁 + STOP
// 分辨率: 1024x768 @ SYNC-DE 模式 (可根据实际屏幕改为800x480)
// ============================================================
module lcd_countdown_top (
    input  wire        clk_27m,      // 板载 27MHz 晶振
    input  wire        rst_n,        // 复位，低有效
    output wire        lcd_clk,      // 像素时钟
    output wire        lcd_hs,       // 行同步
    output wire        lcd_vs,       // 场同步
    output wire        lcd_de,       // 数据使能
    output wire [5:0]  lcd_r,        // 红色
    output wire [5:0]  lcd_g,        // 绿色
    output wire [5:0]  lcd_b         // 蓝色
);

    // ---------- 1. 像素时钟生成 (PLL) ----------
    // 1024x768 @ 60Hz 需要约 65MHz 像素时钟
    // 使用 Gowin rPLL IP 生成, 此处例化占位
    // 请在 Gowin IDE 中配置 rPLL: CLKIN=27MHz, CLKOUT=65MHz
    wire pixel_clk;
    Gowin_rPLL u_pll (
        .clkin  (clk_27m),
        .clkout (pixel_clk),
        .lock   ()
    );

    assign lcd_clk = pixel_clk;

    // ---------- 2. 显示时序参数 ----------
    // 1024x768 XGA 参数 (参考 Sipeed 官方示例)
    localparam H_ACTIVE  = 1024;   // 有效像素
    localparam H_FP      = 144;    // 前肩
    localparam H_BP      = 144;    // 后肩
    localparam H_TOTAL   = 1312;   // 行总周期 (1024+144+144)

    localparam V_ACTIVE  = 768;    // 有效行数
    localparam V_FP      = 13;     // 前肩
    localparam V_BP      = 11;     // 后肩
    localparam V_TOTAL   = 792;    // 场总周期 (768+13+11)

    // ---------- 3. 行/场计数器 ----------
    reg [11:0] h_cnt;
    reg [10:0] v_cnt;

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt <= 12'd0;
            v_cnt <= 11'd0;
        end else begin
            if (h_cnt == H_TOTAL - 1) begin
                h_cnt <= 12'd0;
                if (v_cnt == V_TOTAL - 1)
                    v_cnt <= 11'd0;
                else
                    v_cnt <= v_cnt + 1'b1;
            end else begin
                h_cnt <= h_cnt + 1'b1;
            end
        end
    end

    // ---------- 4. 同步信号与 DE ----------
    assign lcd_hs = ~((h_cnt >= H_ACTIVE + H_FP) &&
                      (h_cnt <  H_ACTIVE + H_FP + 8));
    assign lcd_vs = ~((v_cnt >= V_ACTIVE + V_FP) &&
                      (v_cnt <  V_ACTIVE + V_FP + 2));

    wire de_active = (h_cnt < H_ACTIVE) && (v_cnt < V_ACTIVE);
    assign lcd_de = de_active;

    // 有效区域坐标
    wire [11:0] pix_x = h_cnt;
    wire [10:0] pix_y = v_cnt;

    // ---------- 5. 1Hz 计时脉冲 ----------
    // 利用场同步周期产生 1 秒脉冲 (60Hz / 60 = 1Hz)
    reg [5:0] frame_cnt;
    wire      tick_1s;

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_cnt <= 6'd0;
        end else if (h_cnt == H_TOTAL - 1 && v_cnt == V_TOTAL - 1) begin
            if (frame_cnt == 6'd59)
                frame_cnt <= 6'd0;
            else
                frame_cnt <= frame_cnt + 1'b1;
        end
    end
    assign tick_1s = (frame_cnt == 6'd59) &&
                     (h_cnt == H_TOTAL - 1) && (v_cnt == V_TOTAL - 1);

    // ---------- 6. 倒计时逻辑 ----------
    reg [3:0] sec_ones;    // 秒个位
    reg [3:0] sec_tens;    // 秒十位
    reg       counting;    // 是否在倒计时中
    reg       done;        // 倒计时是否结束

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            sec_ones <= 4'd0;
            sec_tens <= 4'd1;
            counting <= 1'b0;
            done     <= 1'b0;
        end else if (tick_1s) begin
            if (!counting && !done) begin
                counting <= 1'b1;      // 上电后自动开始
            end else if (counting) begin
                if (sec_ones == 4'd0) begin
                    if (sec_tens == 4'd0) begin
                        counting <= 1'b0;
                        done     <= 1'b1;   // 倒计时结束
                    end else begin
                        sec_tens <= sec_tens - 1'b1;
                        sec_ones <= 4'd9;
                    end
                end else begin
                    sec_ones <= sec_ones - 1'b1;
                end
            end
        end
    end

    // ---------- 7. 颜色闪烁状态机 ----------
    // 倒计时结束后，全屏依次切换 红→橙→黄→绿→蓝，每色停留 1 秒
    localparam C_RED    = 3'd0;
    localparam C_ORANGE = 3'd1;
    localparam C_YELLOW = 3'd2;
    localparam C_GREEN  = 3'd3;
    localparam C_BLUE   = 3'd4;
    localparam C_STOP   = 3'd5;

    reg [2:0] color_state;
    reg [3:0] flash_cnt;      // 每种颜色停留的秒计数

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            color_state <= C_RED;
            flash_cnt   <= 4'd0;
        end else if (done && tick_1s) begin
            if (flash_cnt == 4'd0) begin
                if (color_state == C_BLUE) begin
                    color_state <= C_STOP;   // 蓝闪完后进入 STOP
                end else begin
                    color_state <= color_state + 1'b1;
                end
                flash_cnt <= 4'd0;
            end else begin
                flash_cnt <= flash_cnt + 1'b1;
            end
        end
    end

    // ---------- 8. 颜色查找表 ----------
    reg [5:0] bg_r, bg_g, bg_b;

    always @(*) begin
        case (color_state)
            C_RED:    {bg_r, bg_g, bg_b} = {6'h3F, 6'h00, 6'h00}; // 红
            C_ORANGE: {bg_r, bg_g, bg_b} = {6'h3F, 6'h1F, 6'h00}; // 橙
            C_YELLOW: {bg_r, bg_g, bg_b} = {6'h3F, 6'h3F, 6'h00}; // 黄
            C_GREEN:  {bg_r, bg_g, bg_b} = {6'h00, 6'h3F, 6'h00}; // 绿
            C_BLUE:   {bg_r, bg_g, bg_b} = {6'h00, 6'h00, 6'h3F}; // 蓝
            C_STOP:   {bg_r, bg_g, bg_b} = {6'h00, 6'h00, 6'h00}; // 黑底
            default:  {bg_r, bg_g, bg_b} = {6'h00, 6'h00, 6'h00};
        endcase
    end

    // ---------- 9. 字符 ROM (8x8 点阵) ----------
    // 数字 0-9 和字母 S,T,O,P 的点阵数据
    // 每个字符 8 行，每行 8 bit (高位在左)
    function [7:0] char_rom;
        input [3:0] ch;
        input [2:0] row;
        begin
            case (ch)
                4'd0: case(row)
                    3'd0: char_rom = 8'b00111100;
                    3'd1: char_rom = 8'b01100110;
                    3'd2: char_rom = 8'b01101110;
                    3'd3: char_rom = 8'b01110110;
                    3'd4: char_rom = 8'b01100110;
                    3'd5: char_rom = 8'b01100110;
                    3'd6: char_rom = 8'b00111100;
                    default: char_rom = 8'b00000000;
                endcase
                4'd1: case(row)
                    3'd0: char_rom = 8'b00011000;
                    3'd1: char_rom = 8'b00111000;
                    3'd2: char_rom = 8'b00011000;
                    3'd3: char_rom = 8'b00011000;
                    3'd4: char_rom = 8'b00011000;
                    3'd5: char_rom = 8'b00011000;
                    3'd6: char_rom = 8'b01111110;
                    default: char_rom = 8'b00000000;
                endcase
                4'd2: case(row)
                    3'd0: char_rom = 8'b00111100;
                    3'd1: char_rom = 8'b01100110;
                    3'd2: char_rom = 8'b00000110;
                    3'd3: char_rom = 8'b00001100;
                    3'd4: char_rom = 8'b00011000;
                    3'd5: char_rom = 8'b00110000;
                    3'd6: char_rom = 8'b01111110;
                    default: char_rom = 8'b00000000;
                endcase
                4'd3: case(row)
                    3'd0: char_rom = 8'b00111100;
                    3'd1: char_rom = 8'b01100110;
                    3'd2: char_rom = 8'b00000110;
                    3'd3: char_rom = 8'b00011100;
                    3'd4: char_rom = 8'b00000110;
                    3'd5: char_rom = 8'b01100110;
                    3'd6: char_rom = 8'b00111100;
                    default: char_rom = 8'b00000000;
                endcase
                4'd4: case(row)
                    3'd0: char_rom = 8'b00001100;
                    3'd1: char_rom = 8'b00011100;
                    3'd2: char_rom = 8'b00111100;
                    3'd3: char_rom = 8'b01101100;
                    3'd4: char_rom = 8'b01111110;
                    3'd5: char_rom = 8'b00001100;
                    3'd6: char_rom = 8'b00001100;
                    default: char_rom = 8'b00000000;
                endcase
                4'd5: case(row)
                    3'd0: char_rom = 8'b01111110;
                    3'd1: char_rom = 8'b01100000;
                    3'd2: char_rom = 8'b01111100;
                    3'd3: char_rom = 8'b00000110;
                    3'd4: char_rom = 8'b00000110;
                    3'd5: char_rom = 8'b01100110;
                    3'd6: char_rom = 8'b00111100;
                    default: char_rom = 8'b00000000;
                endcase
                4'd6: case(row)
                    3'd0: char_rom = 8'b00111100;
                    3'd1: char_rom = 8'b01100110;
                    3'd2: char_rom = 8'b01100000;
                    3'd3: char_rom = 8'b01111100;
                    3'd4: char_rom = 8'b01100110;
                    3'd5: char_rom = 8'b01100110;
                    3'd6: char_rom = 8'b00111100;
                    default: char_rom = 8'b00000000;
                endcase
                4'd7: case(row)
                    3'd0: char_rom = 8'b01111110;
                    3'd1: char_rom = 8'b00000110;
                    3'd2: char_rom = 8'b00001100;
                    3'd3: char_rom = 8'b00011000;
                    3'd4: char_rom = 8'b00110000;
                    3'd5: char_rom = 8'b00110000;
                    3'd6: char_rom = 8'b00110000;
                    default: char_rom = 8'b00000000;
                endcase
                4'd8: case(row)
                    3'd0: char_rom = 8'b00111100;
                    3'd1: char_rom = 8'b01100110;
                    3'd2: char_rom = 8'b01100110;
                    3'd3: char_rom = 8'b00111100;
                    3'd4: char_rom = 8'b01100110;
                    3'd5: char_rom = 8'b01100110;
                    3'd6: char_rom = 8'b00111100;
                    default: char_rom = 8'b00000000;
                endcase
                4'd9: case(row)
                    3'd0: char_rom = 8'b00111100;
                    3'd1: char_rom = 8'b01100110;
                    3'd2: char_rom = 8'b01100110;
                    3'd3: char_rom = 8'b00111110;
                    3'd4: char_rom = 8'b00000110;
                    3'd5: char_rom = 8'b01100110;
                    3'd6: char_rom = 8'b00111100;
                    default: char_rom = 8'b00000000;
                endcase
                // 字母 S (10)
                4'd10: case(row)
                    3'd0: char_rom = 8'b00111110;
                    3'd1: char_rom = 8'b01100000;
                    3'd2: char_rom = 8'b01100000;
                    3'd3: char_rom = 8'b00111100;
                    3'd4: char_rom = 8'b00000110;
                    3'd5: char_rom = 8'b00000110;
                    3'd6: char_rom = 8'b01111100;
                    default: char_rom = 8'b00000000;
                endcase
                // 字母 T (11)
                4'd11: case(row)
                    3'd0: char_rom = 8'b01111110;
                    3'd1: char_rom = 8'b00011000;
                    3'd2: char_rom = 8'b00011000;
                    3'd3: char_rom = 8'b00011000;
                    3'd4: char_rom = 8'b00011000;
                    3'd5: char_rom = 8'b00011000;
                    3'd6: char_rom = 8'b00011000;
                    default: char_rom = 8'b00000000;
                endcase
                // 字母 O (12)
                4'd12: case(row)
                    3'd0: char_rom = 8'b00111100;
                    3'd1: char_rom = 8'b01100110;
                    3'd2: char_rom = 8'b01100110;
                    3'd3: char_rom = 8'b01100110;
                    3'd4: char_rom = 8'b01100110;
                    3'd5: char_rom = 8'b01100110;
                    3'd6: char_rom = 8'b00111100;
                    default: char_rom = 8'b00000000;
                endcase
                // 字母 P (13)
                4'd13: case(row)
                    3'd0: char_rom = 8'b01111100;
                    3'd1: char_rom = 8'b01100110;
                    3'd2: char_rom = 8'b01100110;
                    3'd3: char_rom = 8'b01111100;
                    3'd4: char_rom = 8'b01100000;
                    3'd5: char_rom = 8'b01100000;
                    3'd6: char_rom = 8'b01100000;
                    default: char_rom = 8'b00000000;
                endcase
                default: char_rom = 8'b00000000;
            endcase
        end
    endfunction

    // ---------- 10. 字符显示位置与像素生成 ----------
    // 字符缩放: 每个点阵像素放大为 8x8 屏幕像素
    localparam CHAR_SCALE = 4'd8;
    localparam CHAR_W     = 8 * CHAR_SCALE;   // 64 像素宽
    localparam CHAR_H     = 8 * CHAR_SCALE;   // 64 像素高

    // 倒计时显示区域: 屏幕中央偏上
    localparam COUNT_Y_TOP = (V_ACTIVE / 2) - CHAR_H - 8;
    // 两个数字水平居中
    localparam COUNT_X_LEFT  = (H_ACTIVE / 2) - CHAR_W - 8;
    localparam COUNT_X_RIGHT = (H_ACTIVE / 2) + 8;

    // STOP 显示区域: 屏幕中央
    localparam STOP_Y_TOP = (V_ACTIVE / 2) - (CHAR_H / 2);
    // 4 个字符从中央向两侧展开
    localparam STOP_X_BASE = (H_ACTIVE / 2) - (CHAR_W * 2) - 12;

    reg [5:0] pix_r, pix_g, pix_b;
    reg       pix_on;

    // 倒计时数字区域判断
    wire in_count_area = de_active &&
                         (pix_y >= COUNT_Y_TOP) &&
                         (pix_y <  COUNT_Y_TOP + CHAR_H) &&
                         (pix_x >= COUNT_X_LEFT) &&
                         (pix_x <  COUNT_X_LEFT + CHAR_W * 2 + 16);

    // STOP 文字区域判断
    wire in_stop_area = de_active &&
                        (pix_y >= STOP_Y_TOP) &&
                        (pix_y <  STOP_Y_TOP + CHAR_H) &&
                        (pix_x >= STOP_X_BASE) &&
                        (pix_x <  STOP_X_BASE + CHAR_W * 4 + 3 * 8);

    // 计算当前像素对应字符点阵的行列
    // 倒计时: 两个数字
    wire [11:0] cnt_rel_x = pix_x - COUNT_X_LEFT;
    wire [10:0] cnt_rel_y = pix_y - COUNT_Y_TOP;
    wire [3:0]  cnt_char_col = cnt_rel_x / (CHAR_W + 8);  // 0=十位, 1=个位
    wire [7:0]  cnt_char_x   = (cnt_rel_x % (CHAR_W + 8)) / CHAR_SCALE;
    wire [7:0]  cnt_char_y   = cnt_rel_y / CHAR_SCALE;

    // STOP: 4 个字符
    wire [11:0] stp_rel_x = pix_x - STOP_X_BASE;
    wire [10:0] stp_rel_y = pix_y - STOP_Y_TOP;
    wire [3:0]  stp_char_col = stp_rel_x / (CHAR_W + 8);
    wire [7:0]  stp_char_x   = (stp_rel_x % (CHAR_W + 8)) / CHAR_SCALE;
    wire [7:0]  stp_char_y   = stp_rel_y / CHAR_SCALE;

    // 字符代码查找
    reg [3:0] disp_char;
    reg [2:0] disp_row;

    always @(*) begin
        pix_on = 1'b0;
        disp_char = 4'd0;
        disp_row  = 3'd0;

        if (in_count_area && !done) begin
            // 显示倒计时数字
            if (cnt_char_col == 4'd0)
                disp_char = sec_tens;
            else
                disp_char = sec_ones;
            disp_row = cnt_char_y[2:0];
            if (char_rom(disp_char, disp_row)[7 - cnt_char_x[2:0]])
                pix_on = 1'b1;
        end else if (in_stop_area && done) begin
            // 显示 STOP
            case (stp_char_col)
                4'd0: disp_char = 4'd10; // S
                4'd1: disp_char = 4'd11; // T
                4'd2: disp_char = 4'd12; // O
                4'd3: disp_char = 4'd13; // P
                default: disp_char = 4'd0;
            endcase
            disp_row = stp_char_y[2:0];
            if (char_rom(disp_char, disp_row)[7 - stp_char_x[2:0]])
                pix_on = 1'b1;
        end
    end

    // 最终像素颜色: 字符白色, 背景由状态机决定
    always @(*) begin
        if (pix_on) begin
            pix_r = 6'h3F;
            pix_g = 6'h3F;
            pix_b = 6'h3F;
        end else begin
            pix_r = bg_r;
            pix_g = bg_g;
            pix_b = bg_b;
        end
    end

    // 有效区域外输出黑色
    assign lcd_r = de_active ? pix_r : 6'h00;
    assign lcd_g = de_active ? pix_g : 6'h00;
    assign lcd_b = de_active ? pix_b : 6'h00;

endmodule