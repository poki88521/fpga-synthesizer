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
    end else if (start_d) begin     // ⚠ 2026-10-15 修：用 start_d（延后1拍）锁存，
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
    reg       start_dd;                   // 再延迟 1 拍（保证 an_r 已锁存生效后再开扫）

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            start_d  <= 1'b0;
            start_dd <= 1'b0;
        end else begin
            start_d  <= sample_en;
            start_dd <= start_d;
        end
    end

    // 扫描地址：c < NCT 时取第 c 个；否则给 0（收尾拍，数据不使用）
    //
    //  ⚠⚠ 2026-10-23：把 rom_addr 从"组合驱动"改成"mux 结果打一拍再送 ROM"。
    //
    //  原因（P&R 实测）：原写法路径 = an_r/an1_r 寄存器 → 8 选 1 mux → ROM 的 AD 脚，
    //      数据延时 21.6 ns > 时钟周期 20.345 ns → slack −1.227 ns，
    //      194 个 Setup 违例端点全集中在这一族（接入 LCD 后布局被挤走就爆了；
    //      此前它一直只有 +0.005 ~ +0.014 ns 余量，是全设计最弱的一环）。
    //  修法：mux 结果先落一拍再驱动 ROM 的 AD 口 → 路径拆成两段，
    //      段1 an_r → mux → rom_addr_r（约 6~10 ns）
    //      段2 rom_addr_r → ROM AD（约 3~5 ns，FF 直连 BSRAM）
    //  代价：ROM 读延迟 1 拍 → 2 拍，所以下面两处必须同步改：
    //      · 存数索引 c-1 → c-2（见"样本寄存器"块）
    //      · 扫描长度 NCT → NCT+1（见"扫描控制"块的收尾判据）
    integer lane;
    reg [AW-1:0] mux_addr;
    always @(*) begin
        lane = c >> 1;
        if (c < NCT) begin
            if (c[0]) mux_addr = an1_r[lane*AW +: AW];
            else      mux_addr = an_r [lane*AW +: AW];
        end else
            mux_addr = {AW{1'b0}};
    end

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) rom_addr <= {AW{1'b0}};
        else             rom_addr <= mux_addr;
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
        end else if (running && (c > 1) && ((c - 2) < NCT)) begin
            // 本拍 rom_dout 对应**两拍前**presented 的地址（rom_addr 已打一拍 + BSRAM 读延迟一拍），
            // 即索引 c-2（原来是 c-1）。
            //   索引为偶数 → 那次读的是 addr_n  → 存 tabn
            //   索引为奇数 → 那次读的是 addr_n1 → 存 tabn1
            // 索引 (c-2) 与 c 同奇偶，所以判据是"c 偶数存 tabn"（原来的 c 奇数存 tabn 已翻转）。
            if (c[0]) tabn1[(c-2) >> 1] <= rom_dout;
            else      tabn [(c-2) >> 1] <= rom_dout;
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

            if (start_dd) begin           // 锁存后再一拍开始扫（保证 an_r 已生效）
                c       <= 6'd0;
                running <= 1'b1;
            end else if (running) begin
                // 2026-10-23：rom_addr 打了一拍，最后一个地址 #(NCT-1) 的数据要到 c == NCT+1 才回来
                //   （原来是 c == NCT，因为那时候地址是组合直连的、只差 BSRAM 一拍）。
                if (c == NCT6 + 6'd1) begin
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
