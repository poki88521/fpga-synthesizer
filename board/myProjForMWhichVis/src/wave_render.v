//============================================================================
//  wave_render —— 全屏波形渲染（1.5 mm 实心粗线 + 纯黑底 + 白轴线/白框）
//
//  ── 视觉规格（2026-10-19 与 saki 确认）───────────────────────────────────
//      · 波形线宽 **1.5 mm**。5 寸 800×480 屏实测 7.346 px/mm
//        ⇒ 1.5 × 7.346 = 11.02 ⇒ **11 像素**（以曲线为中心 ±5）
//      · 实心粗线（不是空心描边），曲线与零轴之间**不额外填充**（方案 A）
//      · 背景 **纯黑** RGB000
//      · 零轴：纯白，3 像素（±1）
//      · 边框：纯白，2 像素
//      · 竖向网格：不要
//      · **天地**：满幅时线的外沿在 y=40 / y=440，距屏边 40 px
//
//  ── 绘制优先级 ──────────────────────────────────────────────────────────
//      白框 > 波形 > 白轴线 > 黑底
//
//  ── 折线渲染（关键，踩过三次坑）────────────────────────────────────────
//      **不能**只按"当前列的 y"画一个竖条 —— 那样陡峭处会断成虚线，
//      或者画成阶梯。正确做法是把**上一列和这一列的 y 连成一条折线**：
//          span = [min(y_prev, y_cur), max(y_prev, y_cur)] ± HALF
//      实测（Python 预览）：只有折线渲染在 3~11 个周期下都是平滑连续的。
//
//  ── 时序 ────────────────────────────────────────────────────────────────
//      lcd_800x480 在 t1 给出 (x,y,vld)，要求 t2 返回颜色。
//      波形源（wave_src_demo / wave_buf）在 t2 给出该列的 y。
//      本模块把 (x,y,vld) 打一拍到 t2，与 y 对齐后**组合**算颜色。
//============================================================================

`default_nettype none

module wave_render #(
    parameter integer H_VALID   = 800,
    parameter integer V_VALID   = 480,
    parameter integer LINE_HALF = 5,     // 11 px 总宽（±5）
    parameter integer AXIS_HALF = 1,     // 白轴线 ±1 = 3 px
    parameter integer BORDER    = 2,     // 白框 2 px
    parameter integer Y_BITS    = 11
)(
    input  wire              clk,
    input  wire              rst_n,

    // ---- 来自 lcd_800x480（t1）----
    input  wire [9:0]        x,
    input  wire [8:0]        y,
    input  wire              vld,

    // ---- 该列的波形纵坐标（t2，由波形源给）----
    input  wire [Y_BITS-1:0] y_wave_q,

    // ---- 当前音色色（RGB666）----
    input  wire [17:0]       color,

    // ---- 回给 lcd_800x480（t2）----
    output wire [17:0]       rgb
);

    localparam [17:0] BLACK = 18'b000000_000000_000000;
    localparam [17:0] WHITE = 18'b111111_111111_111111;

    localparam integer CX = V_VALID / 2;      // 零轴 y = 240

    //  ⚠ 不要对 `parameter integer` 做位选（`LINE_HALF[11:0]`）——
    //     iverilog 会把它当 X，导致整行输出 X（表现为整屏黑）。
    //     统一用定宽 localparam。
    localparam [11:0] LH12 = LINE_HALF;

    //========================================================================
    //  1. 坐标打一拍 → t2（与波形源的 1 拍延迟对齐）
    //========================================================================
    reg [9:0] x_d;
    reg [8:0] y_d;
    reg       vld_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_d   <= 10'd0;
            y_d   <= 9'd0;
            vld_d <= 1'b0;
        end else begin
            x_d   <= x;
            y_d   <= y;
            vld_d <= vld;
        end
    end

    //========================================================================
    //  2. 折线：取上一列的 y，与本列连成 span
    //========================================================================
    reg [Y_BITS-1:0] y_prev;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) y_prev <= 11'd240;
        else        y_prev <= y_wave_q;
    end

    //  ⚠ 行首（x_d==0）不能用上一列的值 —— 那是**上一行**最后一列的，
    //    否则每行开头会多画一条竖线。
    wire [Y_BITS-1:0] y_a = (x_d == 10'd0) ? y_wave_q : y_prev;

    wire [Y_BITS-1:0] lo = (y_wave_q < y_a) ? y_wave_q : y_a;
    wire [Y_BITS-1:0] hi = (y_wave_q > y_a) ? y_wave_q : y_a;

    //========================================================================
    //  3. 判定
    //========================================================================
    wire [11:0] y12 = {1'b0, y_d};                  // 0..479

    //  波形：y 落在 [lo-HALF, hi+HALF]
    wire in_wave = (y12 + LH12 >= {1'b0, lo}) &&
                   (y12 <= {1'b0, hi} + LH12);

    //  白轴线
    wire on_axis = (y_d >= CX - AXIS_HALF) && (y_d <= CX + AXIS_HALF);

    //  白框
    wire on_border = (x_d < BORDER) || (x_d >= H_VALID - BORDER) ||
                     (y_d < BORDER) || (y_d >= V_VALID - BORDER);

    //========================================================================
    //  4. 颜色优先级：白框 > 波形 > 白轴线 > 黑底
    //========================================================================
    assign rgb = (!vld_d)  ? BLACK  :
                 on_border ? WHITE  :
                 in_wave   ? color  :
                 on_axis   ? WHITE  :
                             BLACK;

endmodule

`default_nettype wire
