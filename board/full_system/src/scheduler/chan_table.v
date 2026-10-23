//============================================================================
//  chan_table —— 通道状态表（调度层 · 事件类）
//
//  依据：documents/硬件实现.md §三.四（存储组织 / 待写缓冲与提交 / 派生字段）
//        + documents/技术文档.md §四.1「通道状态表」字段表（23 字段，共 182 bit）
//
//  存储：双缓冲（两份 16 项 × 182 bit 的参数寄存器区）+ 1 bit bank 选择位
//        · 读方整帧只读当前 bank ⇒ 不会"半新半旧"，双缓冲足够（§三.四.2）
//        · `frame_stb` 边界把待写 FIFO 内全部条目写入**后台 bank**，写完翻转 bank
//  写侧：
//        · CC / PC  → 待写 FIFO（深度 4，25 bit = {ch, field_id, value}），帧边界提交
//        · note_count（分配器）与配置项（上位机）→ **直接写当前 bank**，立即生效
//          （分配器要在同帧内读改写；通道层不读 note_count，所以不需要双缓冲）
//  读侧：
//        · 1 个单读口（给 voice_alloc / timbre_map 读通道状态）
//        · P 个并行读口（给通道处理层按 ch_in 取通道参数；单口 BSRAM 会停拍）
//  派生字段（§三.四.3，只在提交时算一次，不在读侧每拍算）：
//        · pan_gL / pan_gR：等功率表 pan_gl.hex / pan_gr.hex（65 项，i=0..64，
//          θ = i/64·π/2）+ pan[0] 线性插值
//        · bend_ratio：指数表 bend_exp.hex（512 项，覆盖 ±24 半音，步长 0.09375
//          半音）+ 线性插值；Δsemi = (bend_value−8192)/8192 × bend_range
//          ⚠ 格式是 **Q2.14 无符号**（中心 16384 = 1.0，量程到 4.0），**不是 Q1.15**：
//            向上弯音要求 ratio > 1.0，而 Q1.15 最大只有 32767（≈1.0）表示不了；
//            文档 §三.四.3 写的"Q1.15 / 中心值 32768"在数学上不可表示（0x8000
//            在有符号 Q1.15 里是 −1.0），已在本次实现中修正，需同步回文档。
//
//  字段位分配（0..181，合计 182）：
//      [6:0]   volume            [13:7]  pan
//      [20:14] expression        [27:21] program
//      [43:28] pan_gL            [59:44] pan_gR
//      [75:60] bend_ratio        [89:76] bend_value(14)   [96:90] bend_range
//      [103:97] attack_mod       [110:104] release_mod    [117:111] resonance_mod
//      [124:118] filter_cutoff_mod
//      [131:125] send_reverb     [138:132] send_chorus    [145:139] send_delay
//      [152:146] bank_msb        [159:153] bank_lsb
//      [167:160] default_timbre(8)   [173:168] max_voices(6)  [179:174] note_count(6)
//      [180]  sustain_pedal      [181]  sostenido→sostenuto_pedal
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module chan_table #(
    parameter        P           = 8,      // 泳道数（并行读口数）
    parameter        NCH         = 16,     // 通道数
    parameter        FIFO_DEPTH  = 4,
    //  ⚠ 2026-10-17 改 8 → 32：赛题拓展要求"复音数 ≥32"。
    //     原来 8 → 单通道最多 8 个音同时响（第 9 个会抢断最早的），
    //     要凑到 32 复音必须分到 4 个通道上弹，不满足"单通道 32 复音"。
    //     物理声部总共就 32 个（P=8 × G=4），设成 32 等于取消单通道限制。
    parameter [5:0]  DEF_MAX_VOICES    = 6'd32,  // 每通道默认最大声部数
    parameter [7:0]  DEF_DEFAULT_TIMBRE= 8'd0
)(
    input  wire        clk,
    input  wire        rst_n_sync,
    input  wire        frame_stb,          // 帧边界 = 唯一提交时刻

    // ——— 事件写口（来自 midi_filter）———
    input  wire        ev_cc_wr,
    input  wire [3:0]  ev_cc_ch,
    input  wire [4:0]  ev_cc_field,
    input  wire [15:0] ev_cc_val,
    input  wire        ev_pc,
    input  wire [3:0]  ev_pc_ch,
    input  wire [6:0]  ev_pc_prog,

    // ——— 分配器写口（note_count，直接写当前 bank）———
    input  wire        alloc_wr,
    input  wire [3:0]  alloc_ch,
    input  wire [5:0]  alloc_nc,

    // ——— 配置写口（上位机，直接写当前 bank）———
    input  wire        cfg_wr,
    input  wire [3:0]  cfg_ch,
    input  wire [7:0]  cfg_default_timbre,
    input  wire [5:0]  cfg_max_voices,

    // ——— 单读口（voice_alloc / timbre_map）———
    input  wire [3:0]  rd_ch,
    output wire [6:0]  rd_volume,
    output wire [6:0]  rd_pan,
    output wire [15:0] rd_pan_gL,
    output wire [15:0] rd_pan_gR,
    output wire [6:0]  rd_expression,
    output wire [15:0] rd_bend_ratio,
    output wire [13:0] rd_bend_value,
    output wire [6:0]  rd_bend_range,
    output wire [6:0]  rd_program,
    output wire [6:0]  rd_bank_msb,
    output wire [6:0]  rd_bank_lsb,
    output wire [7:0]  rd_default_timbre,
    output wire [5:0]  rd_max_voices,
    output wire [5:0]  rd_note_count,
    output wire        rd_sustain_pedal,
    output wire        rd_sostenuto_pedal,
    output wire [6:0]  rd_attack_mod,
    output wire [6:0]  rd_release_mod,
    output wire [6:0]  rd_resonance_mod,
    output wire [6:0]  rd_cutoff_mod,
    output wire [6:0]  rd_send_reverb,
    output wire [6:0]  rd_send_chorus,
    output wire [6:0]  rd_send_delay,

    // ——— P 个并行读口（通道处理层，按 ch_in 取参数）———
    input  wire [P*4-1:0]  prd_ch,
    output wire [P*16-1:0] prd_pan_gL,
    output wire [P*16-1:0] prd_pan_gR,
    output wire [P*7-1:0]  prd_volume,
    output wire [P*7-1:0]  prd_expression,
    output wire [P*7-1:0]  prd_send_reverb,
    output wire [P*7-1:0]  prd_send_chorus,
    output wire [P*7-1:0]  prd_send_delay,
    output wire [P-1:0]    prd_sust_pedal,  // 给 chan_param_shadow / voice_fetch 预取

    // ——— 状态 ———
    output reg         wr_ovf,             // FIFO 溢出（丢弃最旧）
    output wire        dumping,            // 正在提交
    output wire        fifo_empty
);
    //========================================================================
    // 派生字段用的表（由脚本生成的 hex，$readmemh 初始化）
    //========================================================================
    reg [15:0] pan_gl_tbl [0:64];          // 等功率左增益（65 项，i=0..64）
    reg [15:0] pan_gr_tbl [0:64];          // 等功率右增益
    //  ⚠ 2026-10-16：原为 512 项（步长 0.125 半音），在 apply_field 里被**组合读取**，
    //     综合后是 512 选 1 的 16 位 mux → 这是 1092 个时序违例的根源（接上 rd_bend_ratio 后暴露）。
    //     缩到 64 项（步长 1 半音）+ 8 位线性插值：mux 小 8 倍，插值误差约 0.7 音分（听感无差异）。
    //     表由 simulation/tools/gen_bend_exp.py 生成。
    reg [15:0] bend_tbl   [0:63];          // 2^(Δsemi/12)，覆盖 ±24 半音，步长 1 半音

    initial begin
        $readmemh("data/pan_gl.hex",   pan_gl_tbl);
        $readmemh("data/pan_gr.hex",   pan_gr_tbl);
        $readmemh("data/bend_exp.hex", bend_tbl);
    end

    //========================================================================
    // 字段位段
    //========================================================================
    localparam [8:0] B_VOLUME   = 9'd6,    B_VOLUME_L   = 9'd0;
    localparam [8:0] B_PAN      = 9'd13,   B_PAN_L      = 9'd7;
    localparam [8:0] B_EXPR     = 9'd20,   B_EXPR_L     = 9'd14;
    localparam [8:0] B_PROGRAM  = 9'd27,   B_PROGRAM_L  = 9'd21;
    localparam [8:0] B_PANGL    = 9'd43,   B_PANGL_L    = 9'd28;
    localparam [8:0] B_PANGR    = 9'd59,   B_PANGR_L    = 9'd44;
    localparam [8:0] B_BRATIO   = 9'd75,   B_BRATIO_L   = 9'd60;
    localparam [8:0] B_BVALUE   = 9'd89,   B_BVALUE_L   = 9'd76;
    localparam [8:0] B_BRANGE   = 9'd96,   B_BRANGE_L   = 9'd90;
    localparam [8:0] B_ATTACK   = 9'd103,  B_ATTACK_L   = 9'd97;
    localparam [8:0] B_RELEASE  = 9'd110,  B_RELEASE_L  = 9'd104;
    localparam [8:0] B_RESON    = 9'd117,  B_RESON_L    = 9'd111;
    localparam [8:0] B_CUTOFF   = 9'd124,  B_CUTOFF_L   = 9'd118;
    localparam [8:0] B_SREV     = 9'd131,  B_SREV_L     = 9'd125;
    localparam [8:0] B_SCHO     = 9'd138,  B_SCHO_L     = 9'd132;
    localparam [8:0] B_SDEL     = 9'd145,  B_SDEL_L     = 9'd139;
    localparam [8:0] B_BMSB     = 9'd152,  B_BMSB_L     = 9'd146;
    localparam [8:0] B_BLSB     = 9'd159,  B_BLSB_L     = 9'd153;
    localparam [8:0] B_DTIMB    = 9'd167,  B_DTIMB_L    = 9'd160;
    localparam [8:0] B_MAXV     = 9'd173,  B_MAXV_L     = 9'd168;
    localparam [8:0] B_NCNT     = 9'd179,  B_NCNT_L     = 9'd174;
    localparam [8:0] B_SUST     = 9'd180;
    localparam [8:0] B_SOST     = 9'd181;

    //========================================================================
    // 双缓冲本体
    //========================================================================
    reg [181:0] bank0 [0:15];
    reg [181:0] bank1 [0:15];
    reg         bank_sel;                  // 0：读 bank0，1：读 bank1

    // 组合读（前台 + 后台）
    wire [181:0] cur_item  = bank_sel ? bank1[rd_ch] : bank0[rd_ch];
    wire [181:0] back_item = bank_sel ? bank0[rd_ch] : bank1[rd_ch];

    //========================================================================
    // 待写 FIFO（CC / PC）
    //========================================================================
    reg [24:0] fifo [0:3];
    reg [1:0]  fifo_wp, fifo_rp;           // 深度 4 → 必须只用 2 位，靠回绕索引
    reg [2:0]  fifo_cnt;                   // 0..4，需要 3 位
    wire       fifo_full = (fifo_cnt >= FIFO_DEPTH[2:0]);
    assign     fifo_empty = (fifo_cnt == 3'd0);

    // 写请求：CC 优先（同拍不会同时来）
    // 用上升沿检测：接口约定 ev_cc_wr 是单拍脉冲，但即使上游把它保持多拍，
    // 这里也只写一次，避免同一条 CC 被重复入队。
    reg  ev_cc_wr_d;
    always @(posedge clk or negedge rst_n_sync)
        if (!rst_n_sync) ev_cc_wr_d <= 1'b0;
        else             ev_cc_wr_d <= ev_cc_wr;
    wire ev_cc_pulse = ev_cc_wr & ~ev_cc_wr_d;

    //  ⚠ 声明必须在使用之前（Verilog 要求）：本行原来在 190 行之后，
    //     而 `wr_en` 在它之前就引用了 `dumping_wait` → iverilog 报
    //     `Unable to bind wire/reg/memory 'dumping_wait'`。
    reg       copying;
    reg       dumping_r;
    wire      dumping_wait = dumping_r | copying;   // 提交期间不接受新条目

    wire        wr_en   = (ev_cc_pulse | ev_pc) & ~dumping_wait;
    wire [3:0]  wr_ch   = ev_cc_pulse ? ev_cc_ch    : ev_pc_ch;
    wire [4:0]  wr_fld  = ev_cc_pulse ? ev_cc_field : 5'd14;       // PC → program
    wire [15:0] wr_val  = ev_cc_pulse ? ev_cc_val   : {9'd0, ev_pc_prog};

    //========================================================================
    // 提交（dumping）：把 FIFO 内条目逐拍写入后台 bank，写完翻转 bank
    //   ⚠ `copying` / `dumping_r` / `dumping_wait` 已提前到上面声明
    //     （`wr_en` 要先用到 `dumping_wait`，Verilog 要求先声明后使用）
    //========================================================================
    reg [2:0] dump_left;
    assign    dumping = dumping_r;

    //========================================================================
    // 字段应用（把一条 FIFO 条目作用到 182 位项上，并重算派生字段）
    //========================================================================
    //  ⚠ 2026-10-18：`apply_field` 拆成两拍执行（见下方 dump 状态机）。
    //     原来的组合链"FIFO读 → d_old mux → 乘法 → 查表(64选1) → 插值乘法 → 加法"
    //     实测 32.0 ns（要求 28.98），是全局 Fmax 的瓶颈（25 条最差路径全在这里）。
    //     现在把"乘法 + bidx 计算"放到第 1 拍（约 8 ns），
    //     "查表 + 插值 + 加法"留在第 2 拍（约 14.7 ns），两次都在 20.3 ns 内。
    //     `p_bidx` / `p_dsemi` 是第 1 拍算好锁存的。
    function [181:0] apply_field;
        input [181:0] old;
        input [4:0]   fld;
        input [15:0]  val;
        input [7:0]        p_bidx;      // 第 1 拍算好的表索引（已钳位到 48）
        input signed [15:0] p_dsemi;    // 第 1 拍算好的 Q8.8 半音数
        reg   [181:0] t;
        reg   [6:0]   pan_v;
        reg   [6:0]   pidx;
        reg   [13:0]  bv;
        reg   [6:0]   br;
        reg signed [21:0] prod;            // (bv-8192) × br，最大 ±1040384 → 需 21 位
        reg signed [15:0] dsemi;           // Q8.8 半音，范围 ±6144（±24 半音）
        reg   [9:0]   bidx;                // 0..511
        reg   [15:0]  r0, r1;
    //  ⚠ 2026-10-16：插值乘积必须用 **32 位容器**。
    //     Verilog 的 `a * b` 结果位宽 = max(width(a), width(b))，不是相加！
    //     原来 r0/r1 是 16 位、插值分是 5 位 → 乘积 500×31 恰好塞得进 16 位；
    //     插值加到 8 位后 1033×255 = 263415 被截成 16 位（=1271），结果只加了 4。
    reg   [31:0]  interp;
        integer       bi;
        begin
            t = old;
            case (fld)
                5'd0 : t[B_VOLUME  :B_VOLUME_L ] = val[6:0];
                5'd1 : begin
                    t[B_PAN :B_PAN_L] = val[6:0];
                    pan_v = val[6:0];
                    // 等功率：idx = pan[6:1]（0..63），pan[0] 在半步之间插值
                    // ⚠ idx 必须用 7 位：6 位时 idx=63 处的 +1 会回绕成 0，读错表项
                    pidx = {1'b0, pan_v[6:1]};
                    r0 = pan_gl_tbl[pidx];
                    r1 = pan_gl_tbl[pidx + 7'd1];
                    t[B_PANGL:B_PANGL_L] = pan_v[0] ? ((r0 + r1) >> 1) : r0;
                    r0 = pan_gr_tbl[pidx];
                    r1 = pan_gr_tbl[pidx + 7'd1];
                    t[B_PANGR:B_PANGR_L] = pan_v[0] ? ((r0 + r1) >> 1) : r0;
                end
                5'd2 : t[B_EXPR   :B_EXPR_L   ] = val[6:0];
                5'd3 : t[B_SUST]                 = val[0];
                5'd4 : t[B_SOST]                 = val[0];
                5'd5 : t[B_ATTACK :B_ATTACK_L ] = val[6:0];
                5'd6 : t[B_RELEASE:B_RELEASE_L] = val[6:0];
                5'd7 : t[B_RESON  :B_RESON_L  ] = val[6:0];
                5'd8 : t[B_CUTOFF :B_CUTOFF_L ] = val[6:0];
                5'd9 : t[B_SREV   :B_SREV_L   ] = val[6:0];
                5'd10: t[B_SCHO   :B_SCHO_L   ] = val[6:0];
                5'd11: t[B_SDEL   :B_SDEL_L   ] = val[6:0];
                5'd12: t[B_BMSB   :B_BMSB_L   ] = val[6:0];
                5'd13: t[B_BLSB   :B_BLSB_L   ] = val[6:0];
                5'd14: t[B_PROGRAM:B_PROGRAM_L] = val[6:0];
                5'd15: begin
                    t[B_BVALUE:B_BVALUE_L] = val[13:0];
                    //  乘法与 bidx 已在第 1 拍算好（见 p_bidx / p_dsemi）
                    r0 = bend_tbl[p_bidx[5:0]];
                    r1 = bend_tbl[p_bidx[5:0] + 6'd1];
                    //  ⚠ 2026-10-17 修：只把结果放进 32 位 reg 不够 ——
                    //     `(r1-r0) * {...}` 这个**表达式本身**仍在 16 位下求值
                    //     （Verilog 的乘法结果位宽 = max(操作数宽度)），
                    //     超过 16 位的部分在赋值前就已经丢了。
                    //     iverilog 按 32 位算（测试才通过），**Gowin 按 16 位** ——
                    //     综合日志报 "Expression size 25 truncated to fit in target size 16"。
                    //     修法：把操作数显式补零扩到 32 位，让乘积也在 32 位下算。
                    interp = {16'd0, (r1 - r0)} * {8'd0, p_dsemi[7:0]};
                    t[B_BRATIO:B_BRATIO_L] = r0 + (interp >>> 8);
                end
                5'd16: begin
                    t[B_BRANGE:B_BRANGE_L] = val[6:0];
                    r0 = bend_tbl[p_bidx[5:0]];
                    r1 = bend_tbl[p_bidx[5:0] + 6'd1];
                    //  ⚠ 2026-10-17 修：只把结果放进 32 位 reg 不够 ——
                    //     `(r1-r0) * {...}` 这个**表达式本身**仍在 16 位下求值
                    //     （Verilog 的乘法结果位宽 = max(操作数宽度)），
                    //     超过 16 位的部分在赋值前就已经丢了。
                    //     iverilog 按 32 位算（测试才通过），**Gowin 按 16 位** ——
                    //     综合日志报 "Expression size 25 truncated to fit in target size 16"。
                    //     修法：把操作数显式补零扩到 32 位，让乘积也在 32 位下算。
                    interp = {16'd0, (r1 - r0)} * {8'd0, p_dsemi[7:0]};
                    t[B_BRATIO:B_BRATIO_L] = r0 + (interp >>> 8);
                end
                default: ;                                  // 17 = 保留
            endcase
            apply_field = t;
        end
    endfunction

    //========================================================================
    //  dump 两拍流水（2026-10-18）
    //    第 1 拍：FIFO 读 → d_old 通道 mux → 弯音乘法 → bidx   （实测约 8 ns）
    //    第 2 拍：查表(64选1) + 插值乘法 + 加法 → 写回          （实测约 14.7 ns）
    //  原来两者挤在一拍，实测 32.0 ns > 周期 20.3 ns，
    //  是全局 Fmax = 42.771 MHz 的唯一瓶颈（25 条最差路径全在此锥）。
    //  dump 周期从 16 拍变 32 拍，相对 1024 拍/样本只有 3%。
    //========================================================================
    wire [3:0]   d_ch    = fifo[fifo_rp][24:21];
    wire [4:0]   d_fld   = fifo[fifo_rp][20:16];
    wire [15:0]  d_val   = fifo[fifo_rp][15:0];
    wire [181:0] d_old   = bank_sel ? bank0[d_ch] : bank1[d_ch];

    // ---- 第 1 拍：弯音乘法与表索引预计算 ----
    //  fld=15 改 bend_value（用新的 bv + 旧的 br）
    //  fld=16 改 bend_range（用旧的 bv + 新的 br）
    wire [13:0]        pre_bv    = (d_fld == 5'd15) ? d_val[13:0] : d_old[B_BVALUE:B_BVALUE_L];
    wire [6:0]         pre_br    = (d_fld == 5'd16) ? d_val[6:0]  : d_old[B_BRANGE:B_BRANGE_L];
    wire signed [21:0] pre_prod  = ($signed({4'b0, pre_bv}) - 22'sd8192) * $signed({15'd0, pre_br});
    wire signed [15:0] pre_dsemi = pre_prod >>> 5;                  // ×br/32 → Q8.8 半音
    wire [9:0]         pre_idx10 = (pre_dsemi + 16'sd6144) >>> 8;    // [0,48]，步长 1 半音
    wire [7:0]         pre_bidx  = (pre_idx10 > 10'd48) ? 8'd48 : pre_idx10[7:0];

    // ---- 第 1 拍锁存 ----
    reg  [181:0]      d_old_r;
    reg  [4:0]        d_fld_r;
    reg  [15:0]       d_val_r;
    reg  [3:0]        d_ch_r;
    reg  [7:0]        d_bidx_r;
    reg  signed [15:0] d_dsemi_r;
    reg               dump_ph;        // 0 = 第 1 拍结束（已锁存），1 = 该写回

    // ---- 第 2 拍 ----
    wire [181:0] d_new = apply_field(d_old_r, d_fld_r, d_val_r, d_bidx_r, d_dsemi_r);

    //========================================================================
    // 主时序
    //========================================================================
    integer k;
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            bank_sel  <= 1'b0;
            fifo_wp   <= 2'd0;
            fifo_rp   <= 2'd0;
            fifo_cnt  <= 3'd0;
            copying   <= 1'b0;
            dumping_r <= 1'b0;
            dump_left <= 3'd0;
            dump_ph   <= 1'b0;
            d_old_r   <= 182'd0;
            d_fld_r   <= 5'd0;
            d_val_r   <= 16'd0;
            d_ch_r    <= 4'd0;
            d_bidx_r  <= 8'd0;
            d_dsemi_r <= 16'sd0;
            wr_ovf    <= 1'b0;
            for (k = 0; k < 16; k = k + 1) begin
                bank0[k] <= 182'd0;
                bank1[k] <= 182'd0;
            end
            // 配置项载入默认值（两份 bank 都载入，避免翻转后丢失）
            for (k = 0; k < 16; k = k + 1) begin
                bank0[k][B_DTIMB :B_DTIMB_L] <= DEF_DEFAULT_TIMBRE;
                bank1[k][B_DTIMB :B_DTIMB_L] <= DEF_DEFAULT_TIMBRE;
                bank0[k][B_MAXV  :B_MAXV_L  ] <= DEF_MAX_VOICES;
                bank1[k][B_MAXV  :B_MAXV_L  ] <= DEF_MAX_VOICES;

                //  ⚠ **上电可发声的默认参数**（2026-10-08 加，集成时发现的问题）：
                //     原先三份 bank 全 0 → `ext_volume=0` → 通道层增益 0
                //     → **MIDI 收到了、声部也分配了，但整链没声音**。
                //     实测症状：`ch_vld` 在跑、`ch_l` 恒 0、`mx_l` 恒 0。
                //     GM 默认：音量 100、表情 127、声像 64（居中）。
                //     `pan_gL/R` 是**派生字段**，由 pan=64 经等功率律算出，不必在此写。
                bank0[k][B_VOLUME :B_VOLUME_L] <= 7'd100;
                bank1[k][B_VOLUME :B_VOLUME_L] <= 7'd100;
                bank0[k][B_EXPR   :B_EXPR_L  ] <= 7'd127;
                bank1[k][B_EXPR   :B_EXPR_L  ] <= 7'd127;
                bank0[k][B_PAN    :B_PAN_L   ] <= 7'd64;
                bank1[k][B_PAN    :B_PAN_L   ] <= 7'd64;

                //  ⚠⚠ 2026-10-18：**CC71/72/73/74 的通道级调制量必须复位成 64（中心 = 不调制）**。
                //     原来这几项留 0，而 full_system 的换算是"64 = 中心"：
                //       q_coeff     = 16384 + ((0−64)<<8) = **0**      → 阻尼为 0，滤波器自激啸叫
                //       f_coeff     = 30000 + ((0−64)<<8) = 13616      → 截止被拉到 4.6 kHz（闷）
                //       attack_step = clamp(5 + ((0−64)>>1)) = **1**   → 瞬间起音（咔哒）
                //       release_step= clamp(8 + ((0−64)>>1)) = **1**   → 瞬间释放（咔哒）
                //     实板症状：**所有音色都"炸"**（啸叫 + 每次按键咔哒），
                //     但上电的测试模式正常 —— 因为测试模式走 test_voice_gen，
                //     **不经过 SVF/ADSR**。这是定位的关键线索。
                //  ⚠ 注意：在 `chan_param_shadow` 里设 64 是**没用的** ——
                //     它每帧从本表扫描，第一帧就被这里的 0 覆盖掉。
                //     默认值必须在**本表**里设。
                bank0[k][B_ATTACK :B_ATTACK_L ] <= 7'd64;
                bank1[k][B_ATTACK :B_ATTACK_L ] <= 7'd64;
                bank0[k][B_RELEASE:B_RELEASE_L] <= 7'd64;
                bank1[k][B_RELEASE:B_RELEASE_L] <= 7'd64;
                bank0[k][B_RESON  :B_RESON_L  ] <= 7'd64;
                bank1[k][B_RESON  :B_RESON_L  ] <= 7'd64;
                bank0[k][B_CUTOFF :B_CUTOFF_L ] <= 7'd64;
                bank1[k][B_CUTOFF :B_CUTOFF_L ] <= 7'd64;

                //  ⚠ **效果器发送量的默认值**（2026-10-17 加）：
                //     原来三项全 0 → 混响/合唱/延迟的返回信号恒为 0 →
                //     **三个效果器从来没响过**（代码都在，只是发送量为零）。
                //     这和 2026-10-08 修的 `volume=0` 是同一个坑，只是换了个字段。
                //     GM 惯例：混响常开一点，合唱/延迟默认关（由 CC93/94 打开）。
                bank0[k][B_SREV :B_SREV_L ] <= 7'd40;      // 混响 40/127 ≈ 31%
                bank1[k][B_SREV :B_SREV_L ] <= 7'd40;
                bank0[k][B_SCHO :B_SCHO_L ] <= 7'd0;       // 合唱默认关
                bank1[k][B_SCHO :B_SCHO_L ] <= 7'd0;
                bank0[k][B_SDEL :B_SDEL_L ] <= 7'd0;       // 延迟默认关
                bank1[k][B_SDEL :B_SDEL_L ] <= 7'd0;
                bank1[k][B_PAN    :B_PAN_L   ] <= 7'd64;

                //  `pan_gL/R` 是**派生字段**，正常只在"字段变化"时重算
                //  （见本文件 §字段应用）。复位时不初始化就会留 0 → 增益 0 → 无声。
                //  这里直接写等功率表在 pan=64（居中）处的值：
                //      gL = gR = cos(π/4) = 0.7071 → Q1.15 = 23170
                //  （`pan_gl.hex` / `pan_gr.hex` 第 64 项就是这个值，故一致。）
                bank0[k][B_PANGL  :B_PANGL_L ] <= 16'sd23170;
                bank1[k][B_PANGL  :B_PANGL_L ] <= 16'sd23170;
                bank0[k][B_PANGR  :B_PANGR_L ] <= 16'sd23170;
                bank1[k][B_PANGR  :B_PANGR_L ] <= 16'sd23170;

                //  ⚠ 2026-10-13 补：弯音三个字段同样是"派生/待用值"，
                //     复位不初始化就会留 0 → `bend_ratio = 0` → 相位增量 ×0 → **完全无声**。
                //     `bend_ratio` 是 **Q2.14 无符号**（1.0 = 16384，见本文件开头注释），
                //     所以中心的 1.0 就是 16384（**不是 32768**，Q1.15 表示不了 1.0）。
                //     `bend_value` 是 14 位、中心 8192；`bend_range` 按 MIDI 惯例默认 ±2 半音。
                bank0[k][B_BRATIO :B_BRATIO_L ] <= 16'd16384;   // Q2.14，1.0
                bank1[k][B_BRATIO :B_BRATIO_L ] <= 16'd16384;
                bank0[k][B_BVALUE :B_BVALUE_L ] <= 14'd8192;    // 14 位中心
                bank1[k][B_BVALUE :B_BVALUE_L ] <= 14'd8192;
                bank0[k][B_BRANGE :B_BRANGE_L ] <= 7'd2;        // ±2 半音（MIDI 默认）
                bank1[k][B_BRANGE :B_BRANGE_L ] <= 7'd2;
            end
        end else begin
            //================================================================
            // 1) 分配器 / 配置：直接写当前 bank（立即生效）
            //================================================================
            if (alloc_wr) begin
                if (bank_sel) bank1[alloc_ch][B_NCNT:B_NCNT_L] <= alloc_nc;
                else          bank0[alloc_ch][B_NCNT:B_NCNT_L] <= alloc_nc;
            end
            if (cfg_wr) begin
                if (bank_sel) begin
                    bank1[cfg_ch][B_DTIMB:B_DTIMB_L] <= cfg_default_timbre;
                    bank1[cfg_ch][B_MAXV :B_MAXV_L ] <= cfg_max_voices;
                end else begin
                    bank0[cfg_ch][B_DTIMB:B_DTIMB_L] <= cfg_default_timbre;
                    bank0[cfg_ch][B_MAXV :B_MAXV_L ] <= cfg_max_voices;
                end
            end

            //================================================================
            // 2) CC / PC 入 FIFO（提交期间不收，避免与倾倒争用读写指针）
            //================================================================
            if (wr_en) begin
                if (fifo_full) begin
                    // 丢弃最旧：读指针+1，计数不变，然后写入
                    fifo_rp <= fifo_rp + 2'd1;
                    wr_ovf  <= 1'b1;
                end else begin
                    fifo_cnt <= fifo_cnt + 3'd1;
                end
                fifo[fifo_wp] <= {wr_ch, wr_fld, wr_val};
                fifo_wp       <= fifo_wp + 2'd1;
            end

            //================================================================
            // 3) 提交：frame_stb 起把 FIFO 条目逐拍写入后台 bank
            //================================================================
            // ⚠ 双缓冲的关键：必须先把**前台整体复制到后台**，再在后台应用本帧改动。
            //    否则后台里"本帧未改动的通道"仍是上一帧的旧值，翻转后它们会无故回退。
            if (frame_stb && !dumping_r && !copying && (fifo_cnt != 3'd0)) begin
                copying <= 1'b1;
            end

            if (copying) begin
                if (bank_sel) begin
                    for (k = 0; k < 16; k = k + 1) bank0[k] <= bank1[k];
                end else begin
                    for (k = 0; k < 16; k = k + 1) bank1[k] <= bank0[k];
                end
                copying   <= 1'b0;
                dumping_r <= 1'b1;
                dump_left <= fifo_cnt;
            end

            if (dumping_r) begin
                if (!dump_ph) begin
                    // —— 第 1 拍：锁存 + 预算弯音 ——
                    d_old_r   <= d_old;
                    d_fld_r   <= d_fld;
                    d_val_r   <= d_val;
                    d_ch_r    <= d_ch;
                    d_bidx_r  <= pre_bidx;
                    d_dsemi_r <= pre_dsemi;
                    dump_ph   <= 1'b1;
                end else begin
                    // —— 第 2 拍：查表插值 + 写回 ——
                    if (bank_sel) bank0[d_ch_r] <= d_new;   // 后台 = bank0
                    else          bank1[d_ch_r] <= d_new;   // 后台 = bank1
                    fifo_rp   <= fifo_rp + 2'd1;
                    fifo_cnt  <= fifo_cnt - 3'd1;
                    dump_ph   <= 1'b0;
                    if (dump_left <= 3'd1) begin
                        dumping_r <= 1'b0;
                        bank_sel  <= ~bank_sel;             // 提交完成 → 翻转（整帧可见）
                    end else begin
                        dump_left <= dump_left - 3'd1;
                    end
                end
            end
        end
    end

    //========================================================================
    // 单读口输出
    //========================================================================
    assign rd_volume        = cur_item[B_VOLUME  :B_VOLUME_L ];
    assign rd_pan           = cur_item[B_PAN     :B_PAN_L    ];
    assign rd_expression    = cur_item[B_EXPR    :B_EXPR_L   ];
    assign rd_program       = cur_item[B_PROGRAM :B_PROGRAM_L];
    assign rd_pan_gL        = cur_item[B_PANGL   :B_PANGL_L  ];
    assign rd_pan_gR        = cur_item[B_PANGR   :B_PANGR_L  ];
    assign rd_bend_ratio    = cur_item[B_BRATIO  :B_BRATIO_L ];
    assign rd_bend_value    = cur_item[B_BVALUE  :B_BVALUE_L ];
    assign rd_bend_range    = cur_item[B_BRANGE  :B_BRANGE_L ];
    assign rd_attack_mod    = cur_item[B_ATTACK  :B_ATTACK_L ];
    assign rd_release_mod   = cur_item[B_RELEASE :B_RELEASE_L];
    assign rd_resonance_mod = cur_item[B_RESON   :B_RESON_L  ];
    assign rd_cutoff_mod    = cur_item[B_CUTOFF  :B_CUTOFF_L ];
    assign rd_send_reverb   = cur_item[B_SREV    :B_SREV_L   ];
    assign rd_send_chorus   = cur_item[B_SCHO    :B_SCHO_L   ];
    assign rd_send_delay    = cur_item[B_SDEL    :B_SDEL_L   ];
    assign rd_bank_msb      = cur_item[B_BMSB    :B_BMSB_L   ];
    assign rd_bank_lsb      = cur_item[B_BLSB    :B_BLSB_L   ];
    assign rd_default_timbre= cur_item[B_DTIMB   :B_DTIMB_L  ];
    assign rd_max_voices    = cur_item[B_MAXV    :B_MAXV_L   ];
    assign rd_note_count    = cur_item[B_NCNT    :B_NCNT_L   ];
    assign rd_sustain_pedal = cur_item[B_SUST];
    assign rd_sostenuto_pedal = cur_item[B_SOST];

    //========================================================================
    // P 个并行读口（通道处理层）
    //========================================================================
    genvar gi;
    generate
        for (gi = 0; gi < P; gi = gi + 1) begin : g_prd
            wire [3:0]  ch_i  = prd_ch[gi*4 +: 4];
            wire [181:0] it   = bank_sel ? bank1[ch_i] : bank0[ch_i];
            assign prd_pan_gL     [gi*16 +: 16] = it[B_PANGL :B_PANGL_L ];
            assign prd_pan_gR     [gi*16 +: 16] = it[B_PANGR :B_PANGR_L ];
            assign prd_volume     [gi*7  +: 7 ] = it[B_VOLUME:B_VOLUME_L];
            assign prd_expression [gi*7  +: 7 ] = it[B_EXPR  :B_EXPR_L  ];
            assign prd_send_reverb[gi*7  +: 7 ] = it[B_SREV  :B_SREV_L  ];
            assign prd_send_chorus[gi*7  +: 7 ] = it[B_SCHO  :B_SCHO_L  ];
            assign prd_send_delay [gi*7  +: 7 ] = it[B_SDEL  :B_SDEL_L  ];
            assign prd_sust_pedal [gi]          = it[B_SUST];
        end
    endgenerate

    // 后台项的组合读（提交时用）—— 单独引出便于波形观察
    wire [181:0] back_probe = back_item;
    wire _unused = |back_probe;

endmodule
`default_nettype wire
