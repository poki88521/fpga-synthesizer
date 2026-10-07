//============================================================================
//  voice_slot_seq —— 声部时隙时序器（调度层 · 周期类）
//
//  依据：documents/硬件实现.md §三.七
//
//  四条硬性契约（违反则下游行为未定义）：
//    1) 每采样周期**恰好发 G 个** slot_vld，且位置固定；
//    2) 每个脉冲**恰好 1 拍宽**；
//    3) slot 在 slot_vld 那一拍有效，取 0,1,…,G-1 **顺序递增**；
//    4) 第一个脉冲距 frame_stb **至少 1 拍**（不能同拍）。
//
//  默认参数 STRIDE = 8 拍间距 → G × STRIDE = 32 拍，占 1024 拍的 3.1%。
//  cyc 式的拍计数由 frame_stb 复位（时隙边界与采样同步，这是确定性延迟的前提）。
//
//  实现说明：用"距下一个脉冲还有几拍"的递减计数器，避免变量乘法；
//  第 n 个脉冲落在 frame_stb 之后第 2 + n·STRIDE 拍。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module voice_slot_seq #(
    parameter G      = 4,              // 时隙数
    parameter STRIDE = 8               // 时隙间距（拍）
)(
    input  wire                 clk,
    input  wire                 rst_n_sync,
    input  wire                 frame_stb,   // 采样帧起始
    output reg  [$clog2(G)-1:0] slot,        // 当前时隙号
    output reg                  slot_vld     // 单拍脉冲
);
    localparam SW = $clog2(G);

    reg [9:0]  wait_cnt;               // 距下一个 slot_vld 的拍数
    reg [SW:0] sidx;                   // 已发出的脉冲数（0..G）

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            wait_cnt <= 10'd1;
            sidx     <= {(SW+1){1'b0}};
            slot     <= {SW{1'b0}};
            slot_vld <= 1'b0;
        end else begin
            slot_vld <= 1'b0;                       // 默认：脉冲只 1 拍宽
            if (frame_stb) begin
                // 契约 4：frame_stb 之后至少 1 拍才发第一个脉冲
                wait_cnt <= 10'd1;
                sidx     <= {(SW+1){1'b0}};
            end
            else if (sidx < G[SW:0]) begin
                if (wait_cnt <= 10'd1) begin
                    slot_vld <= 1'b1;               // 下一拍发出
                    slot     <= sidx[SW-1:0];       // 与 slot_vld 同拍有效
                    sidx     <= sidx + {{SW{1'b0}}, 1'b1};
                    wait_cnt <= STRIDE[9:0];        // 下一个脉冲等 STRIDE 拍
                end else begin
                    wait_cnt <= wait_cnt - 10'd1;
                end
            end
            // sidx == G：本帧脉冲已发完，保持空闲到下一个 frame_stb
        end
    end

endmodule
`default_nettype wire
