//============================================================================
//  chan_layer —— 通道处理层顶层
//
//  对应设计文档「模块三」第 0 部分。数据流：
//
//      单声部层（P 路并行 x G 个时隙）
//            |  slot_vld
//            v
//      chan_buf  32 x 28bit 暂存（锁住本采样周期的全部声部样本）
//            |  串行读，声部号 0 -> 31
//            v
//      串行累加   ChAcc[0..15]，32-bit（|Σ| <= 32 x 2^23 = 2^28）
//            |
//      通道增益与声像（系数由 chan_coef 在控制率预算好）
//            |
//            v
//      串行通道流  ch_vld / ch_addr / ch_l / ch_r
//
//  时序预算（1024 拍/采样）：
//      时隙捕获  由上游驱动（G x L ~ 80 拍）
//      串行累加  32 拍
//      通道扫描  16 拍
//      合计      约 128 拍 = 12.5%，余量充足
//
//  ch_acc 的清零安排在 ST_CHAN 的最后一拍，这样下一帧的第一次累加读到的
//  就是 0。读是组合的、写是寄存的，所以同一个通道在相邻两拍被累加时，
//  第二拍能直接看到第一拍写入的新值，不需要额外旁路。
//============================================================================

`default_nettype none

module chan_layer #(
    parameter integer P   = 8,
    parameter integer G   = 4,
    parameter integer AW  = 24,
    parameter integer CW  = 4,
    parameter integer NCH = 16,
    parameter integer SW  = 2       // 时隙号位宽 = clog2(G)
)(
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire                    frame_stb,   // 采样帧起始，用于时隙计数再同步

    // ---- 来自单声部处理层 ----
    input  wire                    slot_vld,
    input  wire [SW-1:0]           slot,
    input  wire [P-1:0]            vld,
    input  wire [P*CW-1:0]         ch_in,
    input  wire [P*AW-1:0]         aud_in,

    // ---- 来自通道状态表（调度层）----
    input  wire [NCH*7-1:0]        volume,
    input  wire [NCH*7-1:0]        expression,
    input  wire signed [NCH*16-1:0] pan_gL,
    input  wire signed [NCH*16-1:0] pan_gR,

    // ---- 串行通道流输出 ----
    output reg                     ch_vld,
    output reg [CW-1:0]            ch_addr,
    output reg signed [AW-1:0]     ch_l,
    output reg signed [AW-1:0]     ch_r,
    output reg                     frame_done   // 本帧 16 条通道输出完毕
);

    localparam integer N      = P * G;      // 32
    localparam integer AWX    = 32;         // 累加器位宽
    //  ⚠ 2026-10-14 修正：必须是 **48 位有符号**常量。
    //     原来写成 32 位、又在调用处用位拼接 `{{16{1'b0}}, RND}` 扩宽 ——
    //     **位拼接在 Verilog 里永远是无符号的**，会让 `pl + ...` 整个表达式变成无符号，
    //     随后的 `>>> 15` 退化成**逻辑右移**（补 0），负数被转成巨大正数再饱和到 0x7FFFFF。
    //     现象：ch_l 恒为 [0, 8388607]、从不为负、主混音恒饱和、力度差异被抹平。
    localparam signed [AWX+16-1:0] RND = 48'sd16384;   // 2^14，四舍五入（48 位有符号）

    // ---------------- 暂存 + 系数 ----------------
    wire [CW-1:0]        rd_ch;
    wire signed [AW-1:0] rd_aud;

    reg  [4:0]           acc_i;

    chan_buf #(.P(P), .G(G), .AW(AW), .CW(CW), .SW(SW)) u_buf (
        .clk(clk), .rst_n(rst_n),
        .slot_vld(slot_vld), .slot(slot),
        .vld(vld), .ch_in(ch_in), .aud_in(aud_in),
        .rd_addr(acc_i), .rd_ch(rd_ch), .rd_aud(rd_aud)
    );

    wire signed [NCH*16-1:0] gL_flat, gR_flat;

    chan_coef #(.NCH(NCH)) u_coef (
        .clk(clk), .rst_n(rst_n),
        .volume(volume), .expression(expression),
        .pan_gL(pan_gL), .pan_gR(pan_gR),
        .gL_flat(gL_flat), .gR_flat(gR_flat)
    );

    // ---------------- 串行累加器 ----------------
    reg signed [AWX-1:0] ch_acc [0:NCH-1];

    wire signed [AW-1:0]    cur_aud = rd_aud;
    wire [CW-1:0]           cur_ch  = rd_ch;
    wire signed [AWX-1:0]   cur_ext = {{(AWX-AW){cur_aud[AW-1]}}, cur_aud};
    wire signed [AWX-1:0]   acc_nxt = ch_acc[cur_ch] + cur_ext;

    // ---------------- 通道增益与声像 ----------------
    // ⚠ 入口必须是 48-bit：调用点传进来的 (pl + RND) >>> 15 是 48-bit，
    //   如果这里声明成 32-bit，会在比较大小之前先被截断，溢出判断直接失效。
    function automatic signed [AW-1:0] sat24;
        input signed [47:0] v;
        begin
            if      (v >  48'sd8388607) sat24 = 24'sh7FFFFF;
            else if (v < -48'sd8388608) sat24 = 24'sh800000;
            else                        sat24 = v[AW-1:0];
        end
    endfunction

    reg [3:0] cscan;

    wire signed [AW-1:0]  acc_sat = sat24(ch_acc[cscan]);          // 32 -> 24
    wire signed [15:0]    gL_c    = gL_flat[cscan*16 +: 16];
    wire signed [15:0]    gR_c    = gR_flat[cscan*16 +: 16];
    wire signed [AWX+16-1:0] pl   = acc_sat * gL_c;                // 24 x 16 = 40
    wire signed [AWX+16-1:0] pr   = acc_sat * gR_c;
    //  ⚠ 2026-10-15：中间量写成**显式 signed wire**，消除内联表达式的符号性歧义。
    //     （iverilog 与 Gowin 对"位拼接/内联表达式的符号性"处理可能不同。）
    wire signed [AWX+16-1:0] pl_r = pl + RND;
    wire signed [AWX+16-1:0] pr_r = pr + RND;
    wire signed [AW-1:0]     chl_nxt = sat24(pl_r >>> 15);
    wire signed [AW-1:0]     chr_nxt = sat24(pr_r >>> 15);

    // ---------------- 时隙计数 ----------------
    reg [SW-1:0] slot_cnt;
    wire last_slot = slot_vld && (slot_cnt == (G-1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)         slot_cnt <= {SW{1'b0}};
        else if (frame_stb) slot_cnt <= {SW{1'b0}};
        else if (slot_vld)  slot_cnt <= (slot_cnt == (G-1)) ? {SW{1'b0}} : (slot_cnt + 1'b1);
    end

    // ---------------- 主状态机 ----------------
    localparam [1:0] ST_IDLE = 2'd0,
                     ST_ACC  = 2'd1,
                     ST_CHAN = 2'd2;

    reg [1:0] st;

    integer k;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st         <= ST_IDLE;
            acc_i      <= 5'd0;
            cscan      <= 4'd0;
            ch_vld     <= 1'b0;
            ch_addr    <= 4'd0;
            ch_l       <= 24'sd0;
            ch_r       <= 24'sd0;
            frame_done <= 1'b0;
            for (k = 0; k < NCH; k = k + 1) ch_acc[k] <= 32'sd0;
        end else begin
            ch_vld     <= 1'b0;
            frame_done <= 1'b0;

            case (st)
                // ---- 等 4 个时隙全部到齐 ----
                ST_IDLE: begin
                    if (last_slot) begin
                        st    <= ST_ACC;
                        acc_i <= 5'd0;
                    end
                end

                // ---- 32 拍串行累加 ----
                ST_ACC: begin
                    ch_acc[cur_ch] <= acc_nxt;
                    if (acc_i == N-1) begin
                        st    <= ST_CHAN;
                        cscan <= 4'd0;
                    end else begin
                        acc_i <= acc_i + 5'd1;
                    end
                end

                // ---- 16 拍通道增益 + 声像，串行输出 ----
                ST_CHAN: begin
                    ch_vld  <= 1'b1;
                    ch_addr <= cscan;
                    ch_l    <= chl_nxt;
                    ch_r    <= chr_nxt;

                    if (cscan == NCH-1) begin
                        st         <= ST_IDLE;
                        cscan      <= 4'd0;
                        frame_done <= 1'b1;
                        // 清累加器，供下一帧使用（本拍已读完 ch_acc[NCH-1]）
                        for (k = 0; k < NCH; k = k + 1) ch_acc[k] <= 32'sd0;
                    end else begin
                        cscan <= cscan + 4'd1;
                    end
                end

                default: st <= ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
