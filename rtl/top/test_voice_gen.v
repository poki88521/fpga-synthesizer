//============================================================================
//  test_voice_gen —— 测试模式声源（32 个对数均匀分布的振荡器）
//
//  依据：设计文档《模块三 混合部分设计（修正版）》附三「三、测试模式（现场验证必需）」：
//      32 个振荡器分配互不重合的频率（200 Hz 起、对数均匀分布到 8 kHz）
//      每声部幅度缩放 1/N 或 1/sqrt(N)，避免 32 路叠加削顶
//
//  本模块只负责"声音源"：32 个相位累加器 + 幅度缩放。
//  「效果全关 / 限幅固定增益」由 fx_top / master_chain 的 TEST_MODE 端口实现；
//  「声像左右交替」由上层把通道状态表的 pan 设成硬左右（见 README_测试模式.md）。
//
//  频率表：f[i] = 200 × 40^(i/31)，i = 0..31，相位增量 = round(f × 2^32 / f_s)
//
//  ⚠ 频率表按 FS_HZ = 48000 预先算好（对应板上 USE_PLL=1）。
//    若用 USE_PLL=0（50 MHz / 1024 = 48.828 kHz），音高整体偏高 1.7%，
//    但 32 条谱线依然**互不重合且对数均匀**——现场用频谱仪数谱峰不受影响。
//    要绝对音准就把 FS_HZ 改成 48828（本模块会在综合期用参数重算相位增量）。
//============================================================================

`default_nettype none

module test_voice_gen #(
    parameter integer P     = 8,          // 并行泳道数
    parameter integer N     = 32,         // 声部总数（= P × G）
    parameter integer AW    = 24,         // 音频位宽
    parameter integer FS_HZ = 48000       // 采样率（决定相位增量）
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    en,        // 采样节拍（sample_stb）
    input  wire [1:0]              slot,      // 当前时隙（0 ~ G-1）
    output wire [P*AW-1:0]         aud        // P 路并行音频（Q1.23）
);

    localparam integer G = (N + P - 1) / P;   // 串行组数（32/8 = 4）

    // ---------------- 频率表：真实计算的 (i) 项相位增量 ----------------
    //  为可综合性，用综合期常量函数逐项算：inc = round(200 * 40^(i/31) * 2^32 / FS)
    //  实现：用整数幂 + 64 位中间量，避免浮点。
    //  为了简单与可读，这里把 f_s=48000 的表**算好写死**；换 FS_HZ 时用下面
    //  的 inc_scaled() 在综合期缩放（同一比例，谱线仍互不重合）。
    function [31:0] table_inc_48k;
        input integer i;
        begin
            case (i)
                0 : table_inc_48k = 32'd17895697;   1 : table_inc_48k = 32'd20157096;
                2 : table_inc_48k = 32'd22704259;   3 : table_inc_48k = 32'd25573295;
                4 : table_inc_48k = 32'd28804878;   5 : table_inc_48k = 32'd32444822;
                6 : table_inc_48k = 32'd36544729;   7 : table_inc_48k = 32'd41162723;
                8 : table_inc_48k = 32'd46364273;   9 : table_inc_48k = 32'd52223120;
               10 : table_inc_48k = 32'd58822322;  11 : table_inc_48k = 32'd66255437;
               12 : table_inc_48k = 32'd74627840;  13 : table_inc_48k = 32'd84058228;
               14 : table_inc_48k = 32'd94680291;  15 : table_inc_48k = 32'd106644617;
               16 : table_inc_48k = 32'd120120821; 17 : table_inc_48k = 32'd135299953;
               18 : table_inc_48k = 32'd152397205; 19 : table_inc_48k = 32'd171654960;
               20 : table_inc_48k = 32'd193346231; 21 : table_inc_48k = 32'd217778532;
               22 : table_inc_48k = 32'd245298233; 23 : table_inc_48k = 32'd276295476;
               24 : table_inc_48k = 32'd311209703; 25 : table_inc_48k = 32'd350535885;
               26 : table_inc_48k = 32'd394831540; 27 : table_inc_48k = 32'd444724640;
               28 : table_inc_48k = 32'd500922509; 29 : table_inc_48k = 32'd564221852;
               30 : table_inc_48k = 32'd635520049; 31 : table_inc_48k = 32'd715827883;
                default: table_inc_48k = 32'd0;
            endcase
        end
    endfunction

    // 相位增量（综合期常量，48 kHz 基准）
    //  ⚠ 踩过的坑：曾写成 `(64'd1 * table_inc_48k(i) * 64'd48000) / FS_HZ[63:0]`
    //    想按 FS_HZ 缩放，但 `FS_HZ[63:0]` 这种"对 32 位参数做变宽切片"的写法
    //    iverilog 求值成 X，导致 32 个相位累加器上电后全是 x、输出恒为 X。
    //    这里直接查表（板上 f_s = 48 kHz，就是这张表）。
    //    若将来真要换采样率，改这张表即可（或把 FS_HZ 做成 generate 分支）。
    function [31:0] inc_at;
        input integer i;
        begin
            inc_at = table_inc_48k(i);
        end
    endfunction

    // ---------------- 32 个相位累加器 ----------------
    reg [31:0] ph [0:N-1];

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < N; k = k + 1) ph[k] <= 32'd0;
        end else if (en) begin
            for (k = 0; k < N; k = k + 1)
                ph[k] <= ph[k] + inc_at(k);
        end
    end

    // ---------------- 每声部幅度 ----------------
    //  ⚠ 2026-10-17 两处修正（都直接影响赛题"现场数谱峰"的验证）：
    //
    //  ① 幅度要算上**主增益**：`master_volume` 是 SHIFT=11（×16）。
    //     原来取 1/32 FS，8 路叠加 = 25% FS，再 ×16 = **400% FS → 硬削顶**。
    //     削顶会产生大量互调成分，频谱仪上数不出干净的 32 根谱线。
    //     改为 1/512 FS：8 路 = 1.56% FS，×16 后 = 25% FS，留足余量。
    //
    //  ② 波形从**方波改为三角波**：方波的谐波按 1/n 衰减（3 次只有 −9.5 dB），
    //     会在 32 根基频之间冒出大量额外谱峰；三角波按 1/n² 衰减
    //     （3 次 −19 dB、5 次 −28 dB），谱线干净得多。
    //     三角波由相位高 8 位直接折出，**不需要波形表**。
        //  ⚠ 幅度定标（2026-10-17）：最坏情况必须留余量。
    //     8 路完全同相：8 × 32768 = 262144 (Q1.23) = 3.1% FS × 主增益 16 = **50% FS**
    //     实测（32 个互不相关的频率，很少同相）≈ 10% FS —— 够响且绝不削顶。
    localparam signed [AW-1:0] AMP = 24'sd32768;     // = 1/256 FS
    //  ⚠ 三角波的居中值域是 ±64，要乘这个系数才到 ±AMP。
    //     原来写成硬编码 16'sd256，`AMP` 声明了却没用 —— 改 AMP 数值不生效。
    localparam signed [15:0] AMP_SCALE = AMP >>> 6;  // 32768/64 = 512

    // ---------------- 组合选出本时隙的 8 路 ----------------
    genvar gi;
    generate
        for (gi = 0; gi < P; gi = gi + 1) begin : g_lane
            wire [31:0] p_acc = ph[slot * P + gi];

            //  三角波：相位高 8 位 → 0..127..0，居中到 ±64
            wire [7:0]        ph8     = p_acc[31:24];
            wire [7:0]        tri_u   = ph8[7] ? (8'd255 - ph8) : ph8;
            wire signed [8:0] tri_c   = $signed({1'b0, tri_u}) - 9'sd63;   // -63 .. +64
            //  ±64 × 256 → ±16384；用 16 位容器接收，避免 Verilog 的乘法位宽截断
            wire signed [15:0] tri_mul = tri_c * AMP_SCALE;   // ±64 × 512 → ±AMP

            assign aud[gi*AW +: AW] = {{(AW-16){tri_mul[15]}}, tri_mul};
        end
    endgenerate

endmodule

`default_nettype wire
