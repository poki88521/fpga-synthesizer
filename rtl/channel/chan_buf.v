//============================================================================
//  chan_buf —— 声部样本暂存（通道处理层 第一步的前半）
//
//  一个采样周期内，32 个声部分 G 个时隙到达，每时隙 P 路并行。
//  本模块在 slot_vld 有效时把 P 路并行数据写进暂存堆，锁住本采样周期的
//  全部声部样本，供后面的串行累加读取。
//
//  地址：声部号 = slot * P + lane，与调度层的「声部编号 -> (组, 泳道) 映射固定」
//        约定一致。
//
//  用寄存器堆（不是 BSRAM）的理由：
//      P 路并行写需要 P 个写端口，BSRAM 只有 1 ~ 2 个，做不到；
//      32 x 28 bit = 896 个触发器，对本器件（138K）完全不算什么。
//============================================================================

`default_nettype none

module chan_buf #(
    parameter integer P  = 8,       // 并行泳道数
    parameter integer G  = 4,       // 串行组数（时隙数）
    parameter integer AW = 24,      // 音频位宽
    parameter integer CW = 4,       // 通道号位宽
    parameter integer SW = 2        // 时隙号位宽 = clog2(G)
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // 来自单声部处理层
    input  wire                    slot_vld,   // 本时隙数据有效（1 拍脉冲）
    input  wire [SW-1:0]           slot,       // 时隙号 0 ~ G-1
    input  wire [P-1:0]            vld,        // 每路有效位
    input  wire [P*CW-1:0]         ch_in,      // 每路通道号
    input  wire [P*AW-1:0]         aud_in,     // 每路干信号（单声道）

    // 给累加器读
    input  wire [4:0]              rd_addr,    // 0 ~ P*G-1
    output wire [CW-1:0]           rd_ch,
    output wire signed [AW-1:0]    rd_aud
);

    localparam integer N = P * G;              // 声部总数

    reg [CW+AW-1:0] vmem [0:N-1];

    integer i;
    integer widx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < N; i = i + 1) vmem[i] <= {(CW+AW){1'b0}};
        end else if (slot_vld) begin
            for (i = 0; i < P; i = i + 1) begin
                widx = slot * P + i;
                // 无效泳道写 0：空闲声部对通道总线的贡献必须是 0
                vmem[widx] <= vld[i] ? {ch_in[i*CW +: CW], aud_in[i*AW +: AW]}
                                    : {(CW+AW){1'b0}};
            end
        end
    end

    // 组合读（寄存器堆，读延迟为 0）
    assign rd_ch  = vmem[rd_addr][CW+AW-1:AW];
    assign rd_aud = vmem[rd_addr][AW-1:0];

endmodule

`default_nettype wire
