//============================================================================
//  soft_limiter —— 主输出软限幅（设计文档 4.主输出处理 第二步）
//
//  文档原文（myWorkPartThree.md 第二步）：
//      1. 包络检测：Env[n] = max(|VolL|, |VolR|)
//      2. 目标增益：Env ≤ Threshold 时 G_target = 1.0；否则 G_target = Threshold / Env
//         Threshold 例如 0x600000（24-bit，约 -2.5 dBFS）
//      3. 增益平滑：G_target < G_limit[n-1] 时立即响应（Attack ≈ 0）；
//         否则 G_limit[n] = G_limit[n-1] + Release*(G_target - G_limit[n-1])
//         G_limit 复位初值 1.0
//      4. LimL = sat24( (VolL * G_limit) >>> 15 )
//      5. 打一拍寄存
//
//  ⚠⚠ 2026-10-09 改动：**插入 3 级流水线**（原为单周期纯组合）
//  --------------------------------------------------------------------------
//  问题：原实现在 P&R 后出现 **566 个建立时间违例**、TNS = −2851.8 ns，
//        最差路径 slack = −25.907 ns（时钟周期 20.345 ns，数据延迟却要 46.208 ns）。
//        路径：master_volume 输出寄存器 → 本模块内部寄存器，全程无流水。
//        Gowin 不会因违例中止 P&R，照样生成 .fs，但主输出链路在真板上会出错。
//
//  改法：把 `env → msb_pos → mant → 倒数查表/插值 → ×THRESH` 这段拆成 3 级流水。
//        第 1 级：env → nk/mant（优先编码器 + 移位，原延迟大头）
//        第 2 级：mant/nk → recip_final（查表 + 插值 + 两次乘法 + 桶形移位）
//        第 3 级：recip_final → g_tgt → g_nxt → g，并施加增益输出
//
//  ⚠ **音频也必须跟着打同样的拍数**（l_d1/d2/d3、r_d1/d2/d3）。
//     否则"增益来自 3 拍前的包络、音频是当前采样"就错配了。
//     同步流水后，增益与音频**始终对齐**，文档要求的
//     「G_target 当拍生效、输出永不过冲」（L154-156 的原始设计意图）**完全保留**，
//     整体只是晚 3 个采样（62.5 µs @48 kHz），听感无影响。
//
//  ⚠ 流水寄存器**全部用 `en` 使能**。`en` 是采样节拍（约 1/1024 拍），
//     若不用 en 而每拍推进，流水会以错误的速率前进，结果全错。
//
//  仿真专用：`ifdef SIMULATION 下有一条 $display 用于 TB 观察增益（默认关）。
//============================================================================

`default_nettype none

module soft_limiter #(
    parameter integer AW   = 24,
    parameter signed [23:0] THRESH = 24'sh600000,  // -2.5 dBFS
    parameter integer RELEASE_SHIFT = 4            // 释放时间常数（越大越慢）
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 en,               // 采样节拍
    input  wire                 test_mode,        // 1 = 固定增益（不做动态压缩，附三要求）
    input  wire signed [AW-1:0] l_in, r_in,
    output reg  signed [AW-1:0] l_out, r_out,
    output reg  [15:0]          g_out             // 当前增益 Q1.15（1.0 = 32768），供 TB 观察
);

    //========================================================================
    // 函数定义（全部为纯组合，供各级流水调用）
    //========================================================================

    // ---------------- 幅度（|x|，注意 -2^23 的绝对值要用 24 位无符号装）----------------
    function [23:0] abs24;
        input signed [23:0] v;
        begin
            abs24 = v[23] ? (~v + 24'd1) : v[23:0];
        end
    endfunction

    // --- 倒数表：LUT[i] = round(32768 / (1 + i/32))，i = 0..32（33 项 / 32 段）---
    function [15:0] recip_lut;
        input [5:0] i;                       // 0..32
        begin
            case (i)
                6'd0 : recip_lut = 16'd32768;  6'd1 : recip_lut = 16'd31775;
                6'd2 : recip_lut = 16'd30840;  6'd3 : recip_lut = 16'd29959;
                6'd4 : recip_lut = 16'd29127;  6'd5 : recip_lut = 16'd28340;
                6'd6 : recip_lut = 16'd27594;  6'd7 : recip_lut = 16'd26887;
                6'd8 : recip_lut = 16'd26214;  6'd9 : recip_lut = 16'd25575;
                6'd10: recip_lut = 16'd24966;  6'd11: recip_lut = 16'd24385;
                6'd12: recip_lut = 16'd23831;  6'd13: recip_lut = 16'd23302;
                6'd14: recip_lut = 16'd22795;  6'd15: recip_lut = 16'd22310;
                6'd16: recip_lut = 16'd21845;  6'd17: recip_lut = 16'd21400;
                6'd18: recip_lut = 16'd20972;  6'd19: recip_lut = 16'd20560;
                6'd20: recip_lut = 16'd20165;  6'd21: recip_lut = 16'd19784;
                6'd22: recip_lut = 16'd19418;  6'd23: recip_lut = 16'd19065;
                6'd24: recip_lut = 16'd18725;  6'd25: recip_lut = 16'd18396;
                6'd26: recip_lut = 16'd18079;  6'd27: recip_lut = 16'd17772;
                6'd28: recip_lut = 16'd17476;  6'd29: recip_lut = 16'd17190;
                6'd30: recip_lut = 16'd16913;  6'd31: recip_lut = 16'd16644;
                default: recip_lut = 16'd16384;   // i = 32
            endcase
        end
    endfunction

    // --- 求 env 的最高有效位位置 k（env > 0 时调用；范围 21..23）---
    function [4:0] msb_pos;
        input [23:0] v;
        integer b;
        begin
            msb_pos = 5'd0;
            for (b = 0; b < 24; b = b + 1)
                if (v[b]) msb_pos = b[4:0];
        end
    endfunction

    // ---------------- 饱和 ----------------
    function signed [AW-1:0] sat24;
        input signed [47:0] v;
        begin
            if      (v >  48'sd8388607) sat24 = 24'sh7FFFFF;
            else if (v < -48'sd8388608) sat24 = 24'sh800000;
            else                        sat24 = v[AW-1:0];
        end
    endfunction

    //========================================================================
    //  2026-10-30：**本地复位再同步 + 同步复位**（修时序，不改音频行为）
    //
    //  P&R 报 66 个 Setup 违例，最差 −1.57 ns，全部是：
    //      u_full_top/rst_sync_2_s0/Q → u_full_top/u_master/g_lim.u_lim/env_d1_*_s0/D
    //  根因：rst_n 是全局高扇出网络，而 PRIMARY/LW 已 8/8 用满（时钟资源墙），
    //        它只能走通用布线，从复位同步器到本模块 200+ 个 FF 的连线长达 21.9 ns。
    //
    //  修法：
    //    ① 本模块内部再做 2 级复位同步 → rst_n_l 只在模块内扇出（~200 个 FF）
    //    ② 模块内全部改成**同步复位**（敏感表只留 posedge clk）
    //       ⇒ 复位不再是"全局异步网络"，而是"本地寄存器 → 邻近 FF"的普通路径
    //  行为差异：复位释放晚 2 个时钟（< 41 ns @49.152 MHz），对限幅器完全无影响。
    //========================================================================
    reg rst_n_meta, rst_n_l;
    always @(posedge clk) begin
        if (!rst_n) begin          // 这一处保留异步（唯一的异步复位点）
            rst_n_meta <= 1'b0;
            rst_n_l    <= 1'b0;
        end else begin
            rst_n_meta <= 1'b1;
            rst_n_l    <= rst_n_meta;
        end
    end

    //========================================================================
    // 流水级 0：输入 → 包络
    //========================================================================
    wire [23:0] al  = abs24(l_in);
    wire [23:0] ar  = abs24(r_in);
    wire [23:0] env = (al > ar) ? al : ar;

    reg  signed [AW-1:0] l_d1, r_d1;
    reg  [23:0]          env_d1;

    always @(posedge clk) begin
        if (!rst_n_l) begin
            l_d1   <= {AW{1'b0}};
            r_d1   <= {AW{1'b0}};
            env_d1 <= 24'd0;
        end else if (en) begin
            l_d1   <= l_in;
            r_d1   <= r_in;
            env_d1 <= env;
        end
    end

    //========================================================================
    // 流水级 1：env → 最高位 k + 7 位尾数 mant
    //
    //  原理：env 的最高有效位在 k，把尾数记为 mant = env 去掉最高位后的下 7 位：
    //            env = 2^k × (1 + mant/128)
    //        故  1/env = 2^(−k) × 1/(1 + mant/128)
    //        `recip_mant` 用 **32 段线性插值**逼近 1/(1+x)，x∈[0,1)。
    //  实测精度：最大相对误差 **0.024%**（≈0.0021 dB），比人耳阈值小 243 倍。
    //========================================================================
    wire [4:0]  nk_1   = msb_pos(env_d1);
    wire [23:0] nrem_1 = env_d1 - (24'd1 << nk_1);
    // 右移 (k−7) 取到 7 位尾数；k ≥ 21 时 k−7 ≥ 14，一定成立
    wire [23:0] nmant_1 = (nk_1 >= 5'd7) ? (nrem_1 >> (nk_1 - 5'd7)) : {17'd0, nrem_1[6:0]};
    wire [6:0]  mant_1 = nmant_1[6:0];

    reg  signed [AW-1:0] l_d2, r_d2;
    reg  [23:0]          env_d2;
    reg  [6:0]           mant_d2;
    reg  [4:0]           nk_d2;

    always @(posedge clk) begin
        if (!rst_n_l) begin
            l_d2    <= {AW{1'b0}};
            r_d2    <= {AW{1'b0}};
            env_d2  <= 24'd0;
            mant_d2 <= 7'd0;
            nk_d2   <= 5'd0;
        end else if (en) begin
            l_d2    <= l_d1;
            r_d2    <= r_d1;
            env_d2  <= env_d1;
            mant_d2 <= mant_1;
            nk_d2   <= nk_1;
        end
    end

    //========================================================================
    // 流水级 2：mant/nk → 倒数（查表 + 线性插值 + ×THRESH + 2^(−k) 缩放）
    //========================================================================

    // --- 32 段线性插值：i = mant[6:2]，f = mant[1:0] ---
    wire [5:0]  li_2   = {1'b0, mant_d2[6:2]};              // 0..31
    wire [15:0] la_2   = recip_lut(li_2);
    wire [15:0] lb_2   = recip_lut(li_2 + 6'd1);
    wire signed [16:0] ldiff_2 = $signed({1'b0, lb_2}) - $signed({1'b0, la_2});   // 负
    wire signed [31:0] lprod_2 = ldiff_2 * $signed({1'b0, mant_d2[1:0]});         // ×0..3
    wire signed [31:0] lstep_2 = lprod_2 >>> 2;            // diff*f/4
    wire signed [31:0] rsum_2  = $signed({16'd0, la_2}) + lstep_2;
    //  1/(1+mant/128) 的 Q1.15 值（0.5~1.0，bit15 量级）
    wire [15:0] recip_mant_2 = rsum_2[15:0];

    // --- 2^(−k) 缩放 + 乘 THRESH ---
    //  推导（**必须按这个顺序，否则精度崩**）：
    //    期望 g_Q15 = THRESH/env × 2^15
    //    env = 2^k × M（M = 1+mant/128 ∈ [1,2)），recip_mant_Q15 = (1/M)×2^15
    //    ⇒ g_Q15 = THRESH × recip_mant_Q15 × 2^(−k)
    //    ⇒ g     = (recip_mant × THRESH) >> k          ← **先乘后移**
    //  ⚠ 曾经写成 `(recip_mant >> (k−15))`（先移后乘）：在 k=23 时右移 8 位
    //    会把 recip_mant 的低 8 位直接丢掉，实测相对误差飙到 **1.44%**；
    //    先乘后移降到 **0.0248%**（0.00215 dB）。穷举测试（`sim/tb_recip.v`）抓到的。
    //  位宽：recip_mant ≤ 32768，THRESH = 2^22.58 ⇒ 积 ≤ 2^37.58 < 2^48 ✓（用 48 位）
    wire [47:0] gprod_2     = recip_mant_d3 * {24'd0, THRESH[23:0]};
    wire [15:0] recip_raw_2 = gprod_2 >> nk_d3;            // nk_d2 = k
    //  --- 保守余量：g −= (g >> 7)，即再降约 0.39%（0.034 dB，听感无感）---
    //  ⚠ 为什么必须留余量：倒数近似有 **+0.021%** 的增益误差，而该误差会经
    //    **包络反馈**放大（增益偏大 → 输出偏大 → env 偏大 → 再看下一拍）。
    //    实测不留余量时过载输出会**越过阈值 0.4%**（6295166 > 6291456），
    //    `tb_limiter` 第 2/5 项就会失败。留 0.39% 后全场景都不越阈值。
    //  2026-10-26：补零位数修正 —— {9'd0, x[15:7]} 是 9+9 = 18 位（多出 2 位），
    //    应为 7+9 = 16 位。功能完全等价（结果恒 < 2^16），只是消除综合警告 EX3791 并省 2 位减法器。
    wire [15:0] recip_final_3 = recip_raw_2 - {7'd0, recip_raw_2[15:7]};

    reg  signed [AW-1:0] l_d3, r_d3;
    reg  [23:0]          env_d3;
    reg  [15:0]          recip_d3;
    //  2026-10-24：拆两级（修 mant_d2 → recip_d3 的 20.255 ns 违例路径）
    reg  [15:0]          recip_mant_d3;   // 插值结果打一拍，THRESH 乘法放到下一拍
    reg  [4:0]           nk_d3;           // 与之一同延迟的 k
    reg  [15:0]          recip_d4;
    reg  signed [AW-1:0] l_d4, r_d4;      // 音频同步多延迟一拍
    reg  [23:0]          env_d4;

    always @(posedge clk) begin
        if (!rst_n_l) begin
            l_d3     <= {AW{1'b0}};
            r_d3     <= {AW{1'b0}};
            env_d3   <= 24'd0;
            recip_d3 <= 16'd0;
            recip_mant_d3 <= 16'd0;
            nk_d3         <= 5'd0;
        end else if (en) begin
            l_d3     <= l_d2;
            r_d3     <= r_d2;
            env_d3   <= env_d2;
            recip_mant_d3 <= recip_mant_2;
            nk_d3         <= nk_d2;
        end
    end

    always @(posedge clk) begin
        if (!rst_n_l) begin
            l_d4 <= {AW{1'b0}}; r_d4 <= {AW{1'b0}};
            env_d4 <= 24'd0; recip_d4 <= 16'd0;
        end else if (en) begin
            l_d4 <= l_d3; r_d4 <= r_d3; env_d4 <= env_d3;
            recip_d4 <= recip_final_3;
        end
    end

    //========================================================================
    // 流水级 3：目标增益 → 增益平滑 → 施加增益 + 饱和输出
    //========================================================================

    // 测试模式：阈值拉满 → env 永不超阈值 → 增益恒为 1.0（附三"Threshold 设为 1.0"）
    //  ⚠ test_mode 是准静态配置信号，不打拍；它若在运行中变化，只影响当拍，
    //     下一拍起 env_d3/recip_d3 就与新值一致了（无累积误差）。
    wire [23:0] th_eff_3 = test_mode ? 24'sh7FFFFF : THRESH;
    wire [15:0] g_tgt_3  = (env_d4 <= th_eff_3) ? 16'd32768 : recip_d4;

    // ---------------- 增益平滑：Attack 立即、Release 一阶 ----------------
    //  文档："G_target 小于 G_limit[n-1] 时立即响应" → 压下来不延迟（防爆音）
    //  ⚠ 用**本拍**的 g_cur 去算本拍输出，而不是打一拍后的寄存器 g：
    //    否则过载出现的那一拍用旧增益（1.0），输出会瞬间超过阈值。
    //    这就是"Attack ≈ 0"的落法：G_target 当拍就生效，输出永不过冲。
    //    （本改动把 env/recip 整体流水 3 拍，但音频 l_d3/r_d3 同步延迟，
    //       g_tgt_3 与 l_d3/r_d3 始终对应同一采样，语义不变。）
    reg  [15:0] g;                                   // Q1.15，初值 1.0
    wire [15:0] g_diff = (g > g_tgt_3) ? (g - g_tgt_3) : (g_tgt_3 - g);
    // 释放用的一阶步长：+ 四舍五入，保证能走到 +1；差值 ≤1 时直接到位
    wire [15:0] g_rel  = (g_tgt_3 > g) ? (((g_diff >> RELEASE_SHIFT) == 0) ? 16'd1
                                                                          : (g_diff >> RELEASE_SHIFT))
                                       : 16'd0;
    wire [15:0] g_nxt  = (g_tgt_3 <  g) ? g_tgt_3                     // Attack：当拍压到位
                       : (g_tgt_3 >  g) ? ((g + g_rel > g_tgt_3) ? g_tgt_3 : (g + g_rel))
                       :                   g;
    wire [15:0] g_cur  = (g_tgt_3 < g) ? g_tgt_3 : g;                 // 本拍实际生效的增益

    always @(posedge clk) begin
        if (!rst_n_l) begin
            g <= 16'd32768;                          // 复位初值 1.0（文档要求）
        end else if (en) begin
            g <= g_nxt;
        end
    end

    wire signed [47:0] lp = $signed(l_d4) * $signed({1'b0, g_cur});
    wire signed [47:0] rp = $signed(r_d4) * $signed({1'b0, g_cur});

    always @(posedge clk) begin
        if (!rst_n_l) begin
            l_out <= {AW{1'b0}};
            r_out <= {AW{1'b0}};
            g_out <= 16'd32768;
        end else if (en) begin
            l_out <= sat24(lp >>> 15);
            r_out <= sat24(rp >>> 15);
            g_out <= g_cur;
        end
    end

endmodule

`default_nettype wire
