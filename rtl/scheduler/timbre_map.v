//============================================================================
//  timbre_map —— 音色映射（调度层 · 事件类）
//
//  依据：documents/硬件实现.md §三.五
//    · 输入 (bank_msb[6:0], program[6:0])，来自通道状态表
//    · 输出 timbre_slot[2:0]（0~7）
//    · 实现：组合逻辑 ROM / LUT（规模小，不用 BSRAM）
//    · 输出形式：**寄存器输出（打一拍）** —— 切断组合长链、让分配时序可预测；
//      代价是 timbre_slot 晚一拍，而分配在事件路径上，多一拍不敏感
//    · 本期内容：**恒等映射** timbre_slot = program[2:0]（单库）；真映射表接口
//      保留（bank_msb 作子表选择），将来换成 ROM 查表只改 map_fn
//
//  用法：分配器在 Note On 时拉高 req 一拍，同时给出该通道的 bank_msb/program，
//        下一拍 vld 与 timbre_slot 同时有效，分配器据此锁定声部的音色槽。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module timbre_map (
    input  wire       clk,
    input  wire       rst_n_sync,

    input  wire       req,             // 1 拍查询请求
    input  wire [6:0] bank_msb,        // 子表选择（本期未用，接口保留）
    input  wire [6:0] prog_num,        // 音色号 0~127（不能叫 program：它是 Verilog 关键字）

    output reg  [2:0] timbre_slot,     // 打一拍输出
    output reg        vld              // 与 timbre_slot 同拍有效
);
    //------------------------------------------------------------------
    // 映射函数：本期为单库恒等映射。
    // 将来若要真映射表，把这里换成 ROM 查表：
    //     map_fn = timbre_rom[{bank_msb[1:0], program}];
    // 端口与握手都不需要改。
    //------------------------------------------------------------------
    function [2:0] map_fn;
        input [6:0] bmsb;
        input [6:0] prog;
        begin
            map_fn = prog[2:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            timbre_slot <= 3'd0;
            vld         <= 1'b0;
        end else begin
            timbre_slot <= map_fn(bank_msb, prog_num);
            vld         <= req;
        end
    end

endmodule
`default_nettype wire
