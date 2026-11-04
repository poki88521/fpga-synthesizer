//============================================================================
//  voice_slot_seq —— 声部时隙时序器（模块三的"时间基准"）
//
//  职责：产生通道处理层需要的 `slot` / `slot_vld` 节拍 ——
//        每个采样周期内发出 **G 个时隙脉冲**，每个脉冲对齐一个固定拍号。
//
//  为什么必须"固定拍号"（而不是"有活干才发"）：
//    通道处理层与效果层的流水深度是按**固定时序**设计的。
//    只有时隙边界固定、与采样同步，才能保证
//        G × L + 开销 ≤ 1024
//    并且**延迟恒定无抖动**（赛题拓展要求 ≤5 ms 且确定性）。
//    参考 `技术文档.md` §三「声部并行架构」与 `模块速查表` 的时钟预算。
//
//  时序（默认 N_CYC = 1024、G = 4、STRIDE = 8）：
//      cyc:  1  2 ... 9  10 ... 17 18 ... 25 26 ...        ... 1023
//      slot: 0       1          2         3                （之后不再发）
//      slot_vld: 每个时隙起始打 1 拍
//    → 4 个时隙共占 32 拍（约 3%），之后通道层有 32 拍累加 + 16 拍输出，
//      其余拍数留给效果器与主输出，余量 > 800 拍。
//
//  ⚠ 实现要点：
//    ① `cyc` 由 `frame_stb`（采样帧起始）复位 → 与采样严格同步；
//    ② `slot_vld` 是**单拍脉冲**，宽度 1 个时钟；
//    ③ 用"显式判等"决定脉冲位置，不依赖任何初始值（X 安全）；
//    ④ 时隙数 = G，由参数决定，扩展声部数时只改 G（不增硬件）。
//============================================================================

`default_nettype none

module voice_slot_seq #(
    parameter integer G      = 4,     // 时隙数（= 串行组数）
    parameter integer N_CYC  = 1024,  // 每采样拍数
    parameter integer STRIDE = 8,     // 时隙间隔（拍）
    parameter integer SW     = 2      // 时隙号位宽 = clog2(G)
)(
    input  wire            clk,
    input  wire            rst_n_sync,   // 同步复位（低有效）；与调度层统一命名
    input  wire            frame_stb,   // 采样帧起始（来自 pt8211_tx.sample_stb）
    output reg  [SW-1:0]   slot,        // 当前时隙号
    output reg             slot_vld,    // 时隙有效（单拍脉冲）
    output reg  [1:0]      phase,       // 供调试/观测：0=写时隙 1=累加 2=输出 3=空闲
    output reg             frame_done   // 本采样所有时隙已发完
);

    localparam integer CW = 11;                     // 够表示 0 ~ 2047
    reg [CW-1:0] cyc;

    // ---------------- 拍计数：与采样帧同步 ----------------
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync)              cyc <= {CW{1'b0}};
        else if (frame_stb)      cyc <= {CW{1'b0}};
        else if (cyc != N_CYC[CW-1:0] - 1) cyc <= cyc + 1'b1;
        // 计到 N_CYC-1 就停住（等下一个 frame_stb 再复位），避免回绕后又发脉冲
    end

    // ---------------- 时隙脉冲生成 ----------------
    //  第 k 个时隙在 cyc == 1 + k*STRIDE 那一拍发出（k = 0..G-1）
    integer k;

    //  ⚠ 组合块**开头必须给所有被驱动信号的默认值**（否则综合会推 latch）。
    //    这里是标准写法：先给默认，再按条件覆盖。
    //  ⚠⚠ 2026-10-18：**输出必须寄存一拍**。
    //     原来 `slot_vld` / `slot` 直接由 `cyc`（11 位计数器）组合解码输出 ——
    //     等于"11 位计数器 → 4 路比较器 → 全系统几百个使能端"，
    //     P&R 实测最差的 25 条路径**全部**从 `cyc` 的某一位出发，
    //     终点分散到 voice_fetch / fx_delay / midi_parse 等各处 —— 这就是全局 Fmax 的瓶颈。
    //
    //     改成：组合解码只驱动 2 个寄存器（扇出极小），
    //     再由寄存器输出驱动下游（布线器可以插缓冲树）。
    //
    //     副作用：slot/slot_vld 整体晚 1 拍。帧内有 1024 拍，浪费 1 拍无影响；
    //     两个 voice_slot_seq 实例（full_top 与 sched_subsystem）都由同一个
    //     frame_stb 复位，延迟相同 → 仍然同相。
    //     chan_layer 的 slot_cnt 由 frame_stb 复位、slot_vld 递增，相对关系不变。
    reg [SW-1:0] slot_c;
    reg          slot_vld_c;

    always @(*) begin
        slot_vld_c = 1'b0;
        slot_c     = {SW{1'b0}};
        for (k = 0; k < G; k = k + 1) begin
            // 目标拍号 = 1 + k*STRIDE；写成常量比较，综合成比较器树
            if (cyc == (1 + k*STRIDE)) begin
                slot_vld_c = 1'b1;
                slot_c     = k[SW-1:0];
            end
        end
    end

    //  ⚠⚠ 2026-10-19：`slot` 必须**保持住**上一个时隙号，不能回落到 0。
    //     原因：声部音频有约 23 拍的流水延迟（波表扫描 17 拍 + SVF 4 级），
    //     上游 chan_buf 是在**延迟 23 拍之后**才采样的。
    //     如果 slot 在脉冲后回落成 0，那时读到的永远是 0
    //     → 4 个时隙的数据全写进 slot 0 的地址 → 只有 1/4 的声部拿得到数据。
    //     （实测症状：峰峰值只有 ±1，几乎无声。）
    //     改成"只在脉冲时更新，其余时间保持"后，延迟采样时 slot 仍是正确的当前时隙号。
    //     ⚠ voice_fetch 用的 nslot 是在脉冲当拍组合计算的，语义不变。
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            slot     <= {SW{1'b0}};
            slot_vld <= 1'b0;
        end else begin
            slot_vld <= slot_vld_c;
            if (slot_vld_c) slot <= slot_c;   // 只有脉冲时才更新，否则保持
        end
    end

    // ---------------- 相位指示（便于上板用 LED / GAO 观察） ----------------
    //  写时隙阶段 / 累加阶段 / 输出阶段 / 空闲
    wire [CW-1:0] t_last = 1 + (G-1)*STRIDE;
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            phase      <= 2'd0;
            frame_done <= 1'b0;
        end else if (frame_stb) begin
            phase      <= 2'd0;
            frame_done <= 1'b0;
        end else begin
            if      (cyc <= t_last)          phase <= 2'd0;   // 收声部
            else if (cyc <= t_last + 32)     phase <= 2'd1;   // 通道累加（32 拍）
            else if (cyc <= t_last + 48)     phase <= 2'd2;   // 通道串行输出（16 拍）
            else                             phase <= 2'd3;   // 空闲（效果器与主输出用）
            frame_done <= (cyc == t_last + 48);
        end
    end

endmodule

`default_nettype wire
