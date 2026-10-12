//============================================================================
//  wave_fetch —— 波表取数器：时隙内串行读 + 寄存器缓存（全局 1 份）
//
//  依据：documents/硬件实现.md §五.4「方案：时隙内串行读 + 寄存器缓存」
//
//  问题：P 条泳道同拍要各自读插值的相邻两点 → 每拍 2P 次读；
//        而单口 BSRAM 每拍只能读 1 次。
//  方案：**全片只保留 1 份波表 ROM**，时隙开始处用 2P 拍把该时隙所需的
//        样本依次读出并存入寄存器，之后 P 条泳道照常并行计算。
//
//  时序（1 个时隙、P = 8、含插值两点；每拍 1 个地址）：
//    拍:   0      1      2      3    ...   14     15     16...
//    操作: 读n0 → 读n0+1 → 读n1 → 读n1+1 → ... 读n7 → 读n7+1 → [rdy]
//          └──────────── 2P 拍串行读（单口）────────────┘
//
//  开销：2P × G = 16 × 4 = 64 拍 / 1024（6.3%）；做成预取可完全隐藏。
//
//  ⚠ 地址由 dds_voice 组合产生（含槽内回绕语义），本模块只负责：
//      · 在 sample_en 那拍把 P×2 个地址**锁存**下来
//      · 延后 1 拍再开始扫（等锁存后的地址生效，避免采到上一时隙的旧地址）
//      · 扫完 2P 个地址后拉高 rdy 单拍脉冲
//    BSRAM 同步读有 1 拍延迟，扫描循环里已把这 1 拍算进去。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module wave_fetch #(
    parameter integer P = 8,              // 泳道数
    parameter integer AW = 14,            // 波表地址位宽
    parameter integer DW = 16,            // 波表数据位宽
    parameter         INIT_FILE = ""
) (
    input  wire                clk,
    input  wire                rst_n_sync,
    input  wire                sample_en,          // 时隙节拍（slot_vld）
    input  wire [P*AW-1:0]     addr_n_flat,        // 来自各泳道 dds_voice
    input  wire [P*AW-1:0]     addr_n1_flat,
    output reg                 rdy,                // 两点都到齐，单拍脉冲
    output wire [P*DW-1:0]     tab_n_flat,         // 插值左点
    output wire [P*DW-1:0]     tab_n1_flat         // 插值右点
);

    //---------------- 波表（全局唯一 1 份） ----------------
    reg  [AW-1:0] rom_addr;
    wire [DW-1:0] rom_dout;

    wave_table_rom #(.DEPTH(1 << AW), .AW(AW), .DW(DW), .INIT_FILE(INIT_FILE)) u_rom (
        .clk  (clk),
        .addr (rom_addr),
        .dout (rom_dout)
    );

    //---------------- 地址锁存 ----------------
    reg [P*AW-1:0] an_r, an1_r;

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            an_r  <= {P*AW{1'b0}};
            an1_r <= {P*AW{1'b0}};
        end else if (sample_en) begin
            an_r  <= addr_n_flat;
            an1_r <= addr_n1_flat;
        end
    end

    //---------------- 扫描计数 ----------------
    localparam integer NCT = 2 * P;       // 需读的地址个数
    localparam [5:0]   NCT6 = NCT[5:0];
    reg [5:0] c;                          // 0 .. NCT（NCT 用于收尾那一拍）
    reg       running;
    reg       start_d;                    // sample_en 延迟 1 拍

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) start_d <= 1'b0;
        else             start_d <= sample_en;
    end

    // 扫描地址：c < NCT 时取第 c 个；否则给 0（收尾拍，数据不使用）
    integer lane;
    always @(*) begin
        lane = c >> 1;
        if (c < NCT) begin
            if (c[0]) rom_addr = an1_r[lane*AW +: AW];
            else      rom_addr = an_r [lane*AW +: AW];
        end else
            rom_addr = {AW{1'b0}};
    end

    //---------------- 样本寄存器 ----------------
    reg [DW-1:0] tabn  [0:P-1];
    reg [DW-1:0] tabn1 [0:P-1];

    integer j;
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            for (j = 0; j < P; j = j + 1) begin
                tabn[j]  <= {DW{1'b0}};
                tabn1[j] <= {DW{1'b0}};
            end
        end else if (running && (c > 0) && ((c - 1) < NCT)) begin
            // 本拍 rom_dout 对应**上一拍**presented 的地址，即索引 c-1。
            //   c-1 为偶数 → 那次读的是 addr_n  → 存 tabn
            //   c-1 为奇数 → 那次读的是 addr_n1 → 存 tabn1
            // 即：c 为奇数存 tabn，c 为偶数存 tabn1。
            if (c[0]) tabn [(c-1) >> 1] <= rom_dout;
            else      tabn1[(c-1) >> 1] <= rom_dout;
        end
    end

    //---------------- 扫描控制 ----------------
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            c       <= 6'd0;
            running <= 1'b0;
            rdy     <= 1'b0;
        end else begin
            rdy <= 1'b0;

            if (start_d) begin            // 锁存后一拍开始扫
                c       <= 6'd0;
                running <= 1'b1;
            end else if (running) begin
                if (c == NCT6) begin
                    rdy     <= 1'b1;      // 最后一个地址的数据本拍已回
                    running <= 1'b0;
                end else
                    c <= c + 6'd1;
            end
        end
    end

    //---------------- 输出展开 ----------------
    genvar g;
    generate
        for (g = 0; g < P; g = g + 1) begin : g_flat
            assign tab_n_flat [g*DW +: DW] = tabn [g];
            assign tab_n1_flat[g*DW +: DW] = tabn1[g];
        end
    endgenerate

endmodule

`default_nettype wire
