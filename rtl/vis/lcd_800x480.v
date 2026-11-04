//============================================================================
//  lcd_800x480 —— 800×480 RGB666 屏时序发生器（DE / SYNC-DE 模式）
//
//  依据：官方 `TangMega-138KPro-example/rgb_screen/800_480_screen/src/lcd_timing.v`
//        + `src/800_480_screen.cst`（引脚）+ `gowin_pll.mod`（35 MHz）
//
//  ── 时序（照抄官方参数，仅修正一个 off-by-one）───────────────────────────
//      H: 有效 800 | 前肩 210 | 后肩 182  → 一行 1192 clk
//      V: 有效 480 | 前肩  45 | 后肩   8  → 一帧  533 行
//      一帧 = 1192 × 533 = 635336 clk
//      35 MHz → 55.09 Hz
//
//  ⚠ 官方例程的 DE 判据写成 `H <= H_Valid + H_BackPorch`，
//    这个 `<=` 会让 DE 变成 **801** 拍宽（多一个像素）。
//    本模块改成 `<`，严格 800 拍。多出来的那个像素会把整行右移 1 列，
//    虽然通常看不出来，但会让"最后一列"叠到下一列的起始，故修正之。
//
//  ── 与渲染器的接口：3 级流水，延迟 = 3 拍 ────────────────────────────────
//
//     t0 : 计数器 (h,v) → 组合算出 (x_a,y_a) 与 de_a
//          ⚠ x_a 用的是 **h+3**（提前 3 拍），这样 3 拍后出到屏上时坐标正好对齐。
//     t1 : (x_b,y_b,de_b) 寄存  →  **渲染器在这一拍得到 (rnd_x,rnd_y,rnd_vld)**
//     t2 : 渲染器查表结果回来（内部 BRAM 1 拍延迟）→ rnd_rgb 在这一拍有效
//     t3 : lcd_r/g/b + lcd_en 寄存输出
//
//     对齐推演：
//       输出脚在 t2 出现的是 x_a(t-1)；而屏上该像素的位置 = h(t2) - H_BP
//       = h(t-1) + 3 - H_BP = x_a(t-1)。   两边相等 ✓
//
//  ── 时钟 ────────────────────────────────────────────────────────────────
//      `lcd_clk` **直接等于 clk**（与官方例程一致：PLL 输出直连引脚）。
//      数据在 posedge clk 寄存输出，面板在**下一个** posedge 采样
//      → 数据有接近 1 个周期（28.6 ns）的建立时间，非常宽裕。
//      ⚠ 不要在模块内对 lcd_clk 做取反/再寄存 —— 会造成 17.5 MHz 分频。
//
//  ── 时钟域 ─────────────────────────────────────────────────────────────
//      clk = 35 MHz（pll_pixel 输出）。本模块**完全在像素域**，
//      与音频域（49.152 MHz）无任何组合路径。
//============================================================================

`default_nettype none

module lcd_800x480 #(
    parameter integer H_VALID = 800,
    parameter integer H_FP    = 210,
    parameter integer H_BP    = 182,
    parameter integer V_VALID = 480,
    parameter integer V_FP    = 45,
    parameter integer V_BP    = 8
)(
    input  wire        clk,        // 35 MHz 像素时钟
    input  wire        rst_n,

    // ---- 渲染器接口（像素域）----
    output wire [9:0]  rnd_x,      // 当前要渲染的列（0..799）
    output wire [8:0]  rnd_y,      // 当前要渲染的行（0..479）
    output wire        rnd_vld,    // 上面两个坐标有效
    input  wire [17:0] rnd_rgb,    // 下一拍返回该像素颜色 {R5:0,G5:0,B5:0}

    // ---- 面板接口（DE 模式：只要 clk + en + 18 位色）----
    output wire        lcd_clk,
    output reg         lcd_en,
    output reg  [5:0]  lcd_r,
    output reg  [5:0]  lcd_g,
    output reg  [5:0]  lcd_b,

    // ---- 观测（给 TB / 调试 LED 用）----
    output wire [10:0] h_cnt,
    output wire [9:0]  v_cnt,
    output wire        frame_stb   // 每帧一个脉冲
);

    localparam integer H_TOTAL = H_VALID + H_FP + H_BP;   // 1192
    localparam integer V_TOTAL = V_VALID + V_FP + V_BP;   // 533
    localparam integer LAT     = 3;                        // 流水线延迟（拍）

    //========================================================================
    //  1. 行列计数器
    //========================================================================
    reg [10:0] h;
    reg [9:0]  v;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h <= 11'd0;
            v <= 10'd0;
        end else if (h == H_TOTAL - 1) begin
            h <= 11'd0;
            v <= (v == V_TOTAL - 1) ? 10'd0 : (v + 10'd1);
        end else begin
            h <= h + 11'd1;
        end
    end

    assign h_cnt = h;
    assign v_cnt = v;

    //  帧起点脉冲（h=0 且 v=0 的那一拍，寄存一拍出脉冲）
    reg frm;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) frm <= 1'b0;
        else        frm <= (h == 11'd0) && (v == 10'd0);
    assign frame_stb = frm;

    //========================================================================
    //  2. 组合坐标（提前 LAT 拍）
    //========================================================================
    //  ⚠ 全程用 12 位算，避免 h+3 溢出和减法下溢
    wire [11:0] hx    = {1'b0, h} + LAT[11:0];
    wire [11:0] vy    = {2'b00, v};
    wire [11:0] x_a12 = hx - H_BP[11:0];
    wire [11:0] y_a12 = vy - V_BP[11:0];

    //  DE 有效区间（严格 800 × 480 拍）
    wire de_a = (hx >= H_BP) && (hx < H_BP + H_VALID) &&
                (vy >= V_BP) && (vy < V_BP + V_VALID);

    wire [9:0] x_a = x_a12[9:0];    // de_a=1 时必在 0..799，截断安全
    wire [8:0] y_a = y_a12[8:0];    // de_a=1 时必在 0..479，截断安全

    //========================================================================
    //  3. 流水：坐标打一拍交给渲染器
    //========================================================================
    reg        de_b;
    reg [9:0]  x_b;
    reg [8:0]  y_b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_b <= 1'b0;
            x_b  <= 10'd0;
            y_b  <= 9'd0;
        end else begin
            de_b <= de_a;
            x_b  <= x_a;
            y_b  <= y_a;
        end
    end

    assign rnd_x   = x_b;
    assign rnd_y   = y_b;
    assign rnd_vld = de_b;

    //========================================================================
    //  4. 输出级：de 再打两拍，与数据通路（渲染器 1 拍 + 输出寄存 1 拍）对齐
    //========================================================================
    reg de_c;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_c   <= 1'b0;
            lcd_en <= 1'b0;
            lcd_r  <= 6'd0;
            lcd_g  <= 6'd0;
            lcd_b  <= 6'd0;
        end else begin
            de_c   <= de_b;
            lcd_en <= de_c;
            lcd_r  <= rnd_rgb[17:12];
            lcd_g  <= rnd_rgb[11:6];
            lcd_b  <= rnd_rgb[5:0];
        end
    end

    //  ⚠ 像素时钟直连（与官方例程一致）。不要在这里取反或再寄存。
    assign lcd_clk = clk;

endmodule

`default_nettype wire
