//============================================================================
//  master_volume —— 主输出处理 第一步：主音量 + 静音
//
//  ⚠ 2026-10-15：SHIFT 由 15 改为 **11 = +24 dB（×16）主增益**。先是改到 13（+12dB）实测只有"一点点声音"，再提一档。
//     原因：chan_layer 的符号性 bug 修复后，输出不再"整流+饱和"，
//     单音满力度只剩约 14%（-17 dBFS），实测听不到声音。
//     修复前的"响"是 bug 造成的虚假响度（负半周被转成 +满量程）。
//     这里补回真实增益：单音满力度 → 约 56%，多音齐奏由 soft_limiter 兜底。
//     ⚠ 调这个 SHIFT 即可：每减 1 = +6 dB。soft_limiter 会兜住过量峰值。
//
//  文档：模块三设计文档 4.主输出处理 第一步
//
//  定点：
//      音频 MainL/MainR : 24-bit Q1.23 有符号
//      主音量 vol       : 14-bit（0 ~ 16383，来自 SysEx）
//      G_master         : 16-bit Q1.15。因为 G = V/16383 ≈ V/16384，
//                         所以 G_Q15 = V << 1（误差 < 0.006%）
//
//  静音/音量切换走 ±RAMP_STEP 的一阶斜坡（默认约 10 ms），避免咔哒声。
//      RAMP_STEP = 64 时：32768/64 = 512 个采样 ≈ 10.7 ms @48 kHz
//============================================================================

`default_nettype none

module master_volume #(
    parameter integer RAMP_STEP = 64,       // 每采样增益变化量（Q1.15 LSB）
    parameter integer OUT_W     = 24
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    en,          // 采样节拍
    input  wire signed [OUT_W-1:0] l_in,
    input  wire signed [OUT_W-1:0] r_in,
    input  wire        [13:0]      vol,         // 0 ~ 16383
    input  wire                    mute,        // 1 = 静音
    output wire signed [OUT_W-1:0] l_out,
    output wire signed [OUT_W-1:0] r_out
);

    // G_Q15 = vol << 1，范围 0 ~ 32766（正的，所以有符号 16-bit 也能表示）
    wire [15:0] g_tgt = mute ? 16'd0 : {vol, 1'b0};

    reg  [15:0] g;                              // 当前增益，Q1.15

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g <= 16'd0;
        end else if (en) begin
            if (g < g_tgt) begin
                g <= ((g_tgt - g) > RAMP_STEP) ? (g + RAMP_STEP[15:0]) : g_tgt;
            end else if (g > g_tgt) begin
                g <= ((g - g_tgt) > RAMP_STEP) ? (g - RAMP_STEP[15:0]) : g_tgt;
            end
        end
    end

    wire signed [15:0] g_s = g[15:0];

    // 24 x 16 = 40-bit，符号扩展到 48 位后走通用归一化单元
    wire signed [39:0] pl = l_in * g_s;
    wire signed [39:0] pr = r_in * g_s;

    //  ⚠⚠ 2026-10-19：SHIFT 由 11（×16）改为 **12（×8）**。
    //     历史：10-15 从 15 提到 11（×16），是因为当时**声部层还是坏的**
    //     （包络状态错乱、电平极低），只好用大增益补偿，注释里写着
    //     "改到 13 实测只有一点点声音"。
    //     声部层修好后电平正常了，实测单声部：
    //       voice_aud 1,108,563 × gL 0.548 = 607,599（7.2% 满量程）
    //       ×16 = 9,721,584  vs 24 位满量程 8,388,607  → **116%**，
    //       限幅器被持续深压缩，输出恒贴在 96% 满量程
    //       → 实板听感"音量很大、很炸"（不是失真，是增益过猛被压扁）。
    //     改成 ×8 后单声部约 58% 满量程，余量充足；
    //     复音时仍会超过满量程，由 soft_limiter 兜住（这是它的职责）。
    //     ⚠ 再调这个 SHIFT 即可：每减 1 = +6 dB。
    //
    //  ⚠⚠ 2026-11-03：SHIFT 由 12（×8）改为 **13（×4）**，整体 −6 dB。
    //     症状：**和弦**（≥2 个音同时）有"几十 Hz 的嗡嗡/震荡"，**单音没有**；
    //           program 0/1/2/3 四个音色都有；与力度、混响量、CC1(mod wheel=0) 都无关。
    //           ⇒ 与波表分音无关、与颤音无关，是**互调（IMD）**的特征。
    //     实测（C24 = dbg_sd 的 1 位 ΣΔ 探针，按 1.65 V = 1.0 FS 解码）：
    //           单音 C4   峰值 0.565 FS
    //           C4+C5     峰值 0.740 FS
    //           C4+A4     峰值 0.763 FS
    //     ⇒ 双音峰值正好压在 soft_limiter 的 0.75 FS 阈值上，离 24 位硬饱和(1.0) 只有 2.4 dB。
    //       即"单音干净、双音刚好把后级推到近满刻度"，于是后级（PT8211 R-2R 的码跳变毛刺、
    //       功放、耳机）的码型相关失真以差频（C4+E4 → 68 Hz）的包络调制出现 —— 听感就是"嗡嗡"。
    //     改成 ×4 后：双音峰值 0.76 → 0.38 FS，单音 0.28 FS，
    //       三级非线性（0.75 软限幅 / 1.0 硬饱和 / 后级）全部远离，R-2R 码跳变能量也减半。
    //     代价：整体小 6 dB（数字侧补不回来，vol_sh 只能衰减）⇒ 用功放/耳机音量补。
    //     ⚠ 再调这个 SHIFT 即可：每减 1 = +6 dB。
    norm_sat #(.IN_W(48), .SHIFT(13), .OUT_W(OUT_W)) u_vol_l (   // 2026-11-03：12->13 = ×4（−6 dB，给后级留余量）
        .acc({{8{pl[39]}}, pl}), .y(l_out)
    );
    norm_sat #(.IN_W(48), .SHIFT(13), .OUT_W(OUT_W)) u_vol_r (   // ⚠ 同上
        .acc({{8{pr[39]}}, pr}), .y(r_out)
    );

endmodule

`default_nettype wire
