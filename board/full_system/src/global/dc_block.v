//============================================================================
//  dc_block —— 主输出处理 第三步：直流去除（一阶高通）
//
//  文档：模块三设计文档 4.主输出处理 第三步（可选）
//  差分方程：y[n] = x[n] - x[n-1] + a * y[n-1]
//            a = 0.995，Q1.15 = round(0.995 * 32768) = 32604 = 0x7F5C
//  截止频率：f_c ≈ (1-a) * f_s / (2*pi)
//            48.000 kHz -> 38.2 Hz；48.828 kHz -> 38.9 Hz
//
//  实现技巧：把整式乘 2^15 后再走通用归一化单元，避免多次截断：
//      acc = (x - x_d) <<< 15 + a * y_d
//      y   = acc >>> 15
//  这样归一化只发生一次，四舍五入也只有一次。
//============================================================================

`default_nettype none

module dc_block #(
    parameter signed [15:0] A_Q15 = 16'sd32604,   // 0.995
    parameter integer       W     = 24
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire                en,                // 采样节拍
    input  wire signed [W-1:0] x,
    output wire signed [W-1:0] y
);

    reg signed [W-1:0] x_d;      // x[n-1]
    reg signed [W-1:0] y_d;      // y[n-1]

    wire signed [W:0]    diff  = x - x_d;                     // (W+1) 位

    // ⚠⚠ **位宽陷阱（踩过，会静默溢出并抬高整条链的噪声底 12 dB）**：
    //   |diff| ≤ 2 × 2^23 = 2^24，左移 15 位后 = 2^39，**恰好超出 40 位有符号上限**
    //   （2^39 − 1）。原实现把 `diff` 先扩到 40 位再 `<<< 15`，峰值时会回绕，
    //   表现为"宽带噪声底抬到 −94 dBFS、SNR 从 86 掉到 62 dB"
    //   （逐级隔离 + 双精度参考比对才定位到这一处）。
    //   ⇒ 必须**先扩到 48 位再左移**：`{48{diff[W]}}, diff` 然后 `<<< 15`。
    //   `<<<` 本身也不会自动加宽（结果宽度 = 左操作数宽度），所以扩展要在移位之前。
    wire signed [47:0] diff_x = {{(48-(W+1)){diff[W]}}, diff};   // 先扩到 48 位
    wire signed [47:0] diff_s = diff_x <<< 15;                   // 再左移，不再溢出
    //  ⚠ `A_Q15` 是**有符号**的 Q1.15 系数，扩展必须复制符号位；
    //     用零扩展（{48-16{1'b0}}）会让负数系数变成大正数 —— 本处踩过，
    //     修完 SNR 反而掉到 −3.74 dB。y_d 是 signed，Verilog 会自动符号扩展。
    wire signed [47:0] aext   = {{(48-16){A_Q15[15]}}, A_Q15};
    wire signed [47:0] prod   = aext * y_d;                      // 48 位容器里乘

    wire signed [47:0] acc = diff_s + prod;

    norm_sat #(.IN_W(48), .SHIFT(15), .OUT_W(W)) u_norm (.acc(acc), .y(y));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_d <= {W{1'b0}};
            y_d <= {W{1'b0}};
        end else if (en) begin
            x_d <= x;
            y_d <= y;
        end
    end

endmodule

`default_nettype wire
