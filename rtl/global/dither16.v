//============================================================================
//  dither16 —— 主输出处理 第四步：TPDF 抖动 + 24-bit -> 16-bit
//
//  文档：模块三设计文档 4.主输出处理 第四步
//
//  为什么必须做：板载 DAC 是 PT8211（16-bit），内部 24-bit 到 16-bit 是有损
//  截断，必须加抖动，否则小信号会出现量化失真。
//
//  幅度推导：
//      两个独立的 32-bit 最大长度 LFSR（抽头 32/22/2/1），取低 16 位相减：
//          diff = lfsr1[15:0] - lfsr2[15:0]   ∈ [-65535, 65535]
//          tpdf = diff >>> 8                  ∈ [-256, 255]
//      16-bit 的 1 LSB 相当于 24-bit 域的 2^8 = 256，
//      所以 tpdf 正好是 ±1 LSB(16-bit) 的三角分布（TPDF）。
//
//  LFSR 初值必须非零且两个不同 —— 全零会锁死，抖动直接失效。
//============================================================================

`default_nettype none

module dither16 (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                en,              // 采样节拍
    input  wire signed [23:0]  l_in,
    input  wire signed [23:0]  r_in,
    output wire signed [15:0]  l_out,
    output wire signed [15:0]  r_out
);

    localparam [31:0] LFSR1_SEED = 32'hDEAD_BEEF;
    localparam [31:0] LFSR2_SEED = 32'h1234_5678;

    reg [31:0] lfsr1, lfsr2;
    wire fb1 = lfsr1[31] ^ lfsr1[21] ^ lfsr1[1] ^ lfsr1[0];
    wire fb2 = lfsr2[31] ^ lfsr2[21] ^ lfsr2[1] ^ lfsr2[0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr1 <= LFSR1_SEED;    // 非零初值
            lfsr2 <= LFSR2_SEED;    // 与 lfsr1 不同
        end else if (en) begin
            lfsr1 <= {lfsr1[30:0], fb1};
            lfsr2 <= {lfsr2[30:0], fb2};
        end
    end

    // 共用的抖动源（左右同源，保持立体声像稳定）
    wire signed [16:0] diff = $signed({1'b0, lfsr1[15:0]})
                            - $signed({1'b0, lfsr2[15:0]});
    wire signed [23:0] tpdf = diff >>> 8;

    // 加抖动 -> 饱和到 24-bit -> 取高 16 位
    function automatic signed [23:0] sat24;
        input signed [24:0] v;
        begin
            if (v > 25'sd8388607)       sat24 = 24'sh7FFFFF;
            else if (v < -25'sd8388608) sat24 = 24'sh800000;
            else                        sat24 = v[23:0];
        end
    endfunction

    // ⚠ 同样要注意宽度：24 位 + 24 位的结果宽度仍是 24 位，会先回绕。
    //   先把两边都扩到 25 位再相加。
    wire signed [24:0] l_in_x = {{1{l_in[23]}}, l_in};
    wire signed [24:0] r_in_x = {{1{r_in[23]}}, r_in};
    wire signed [24:0] tpdf_x = {{1{tpdf[23]}}, tpdf};

    wire signed [23:0] l24 = sat24(l_in_x + tpdf_x);
    wire signed [23:0] r24 = sat24(r_in_x + tpdf_x);

    assign l_out = l24[23:8];
    assign r_out = r24[23:8];

endmodule

`default_nettype wire
