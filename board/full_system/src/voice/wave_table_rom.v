//============================================================================
//  wave_table_rom —— 全局唯一的波表 ROM（16384 × 16 bit）
//
//  依据：documents/硬件实现.md §五.1（音色槽与波表）、§五.4（波表读取）、§五.9
//
//  口径：8 槽 × 2048 点 = 16384 点，地址 14 位 = {timbre_slot[2:0], addr[10:0]}
//        数据 16 位有符号补码（−1 写 FFFF，32767 写 7FFF）
//        容量 16384 × 16 = 256 Kbit → 16 块 BSRAM（16 Kbit 模式）
//
//  ⚠ 综合时本模块应替换为高云 BSRAM 只读 IP（.mi 初值文件，Address_depth=16384，
//    Data_width=16）。这里给的是**行为级等价模型**，供仿真使用；
//    需要初值时可给 INIT_FILE 一个 .hex（$readmemh 格式）路径。
//
//  同步读：dout 比 addr 晚 1 拍（BSRAM 的真实行为，见 §五.4「实现要点」1）
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module wave_table_rom #(
    parameter integer DEPTH     = 16384,
    parameter integer AW        = 14,
    parameter integer DW        = 16,
    parameter         INIT_FILE = ""        // 非空时用 $readmemh 载入
) (
    input  wire            clk,
    input  wire [AW-1:0]   addr,
    output reg  [DW-1:0]   dout
);

    reg [DW-1:0] mem [0:DEPTH-1];

    generate
        if (INIT_FILE != "") begin : g_init
            initial $readmemh(INIT_FILE, mem);
        end
    endgenerate

    always @(posedge clk)
        dout <= mem[addr];

endmodule

`default_nettype wire
