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
//  实现说明（与文档的对应）：
//      · G_limit 用 Q1.15，1.0 = 32768（16 位无符号寄存器，值域 0~32768）
//      · "Threshold / Env" 用**整数除法**直接得到 Q1.15：
//            g_tgt = (THRESH << 15) / env       （env > THRESH 时才需要）
//        文档提的"256 项倒数 LUT + 线性插值"是省面积的近似法；本实现只有一条
//        除法、每采样一次，在 50 MHz / 48 kHz 下完全富余，故直接用除法，精度更高。
//        如果以后要省资源，可以换成 LUT（行为等价，改这一个函数即可）。
//      · Release 用 Q1.15 系数：gain += (g_tgt - gain) >>> RELEASE_SHIFT
//        RELEASE_SHIFT=4 时时间常数约 16 个采样（0.33 ms），可按听感调大。
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

    // ---------------- 幅度（|x|，注意 -2^23 的绝对值要用 24 位无符号装）----------------
    function [23:0] abs24;
        input signed [23:0] v;
        begin
            abs24 = v[23] ? (~v + 24'd1) : v[23:0];
        end
    endfunction

    wire [23:0] al = abs24(l_in);
    wire [23:0] ar = abs24(r_in);
    wire [23:0] env = (al > ar) ? al : ar;

    // ---------------- 目标增益 G_target（Q1.15，1.0 = 32768）----------------
    // env ≤ THRESH → 1.0（32768）；否则算 THRESH/env 的 Q1.15 表示。
    //
    //  ⚠⚠ **不能用综合器推断的 48 位组合除法**（原实现是 `div_num / env`）：
    //     一条 48÷24 的组合除法链在 49.152 MHz 下**几乎必然过不了时序**。
    //     改成本模块自带的「正规化 + 32 项倒数表 + 线性插值」，与
    //     `硬件实现.md` 写的"倒数 LUT"方案一致。
    //
    //  原理：env 的最高有效位在 k（k ≥ 21，因为 env > THRESH = 0x600000 ≈ 2^22.58），
    //        把尾数记为 mant = env 去掉最高位后的下 7 位（0..127），则
    //            env = 2^k × (1 + mant/128)
    //        故  1/env = 2^(−k) × 1/(1 + mant/128)
    //        `recip_mant` 用 **32 段线性插值**逼近 1/(1+x)，x∈[0,1)；
    //        最后把 Q1.15 结果右移 k−15 位完成 2^(−k) 缩放。
    //  实测精度：最大相对误差 **0.024%**（≈0.0021 dB），比人耳阈值小 243 倍。
    //
    //  ⚠ 同理也不能用 `{THRESH, 15'd0} / env` 那种写法留给工具去推断。

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

    // --- mant = env 去掉最高位后的下 7 位 ---
    wire [4:0]  nk   = msb_pos(env);
    wire [23:0] nrem = env - (24'd1 << nk);
    // 右移 (k−7) 取到 7 位尾数；k ≥ 21 时 k−7 ≥ 14，一定成立
    wire [23:0] nmant = (nk >= 5'd7) ? (nrem >> (nk - 5'd7)) : {17'd0, nrem[6:0]};
    wire [6:0]  mant = nmant[6:0];

    // --- 32 段线性插值：i = mant[6:2]，f = mant[1:0] ---
    wire [5:0]  li   = {1'b0, mant[6:2]};              // 0..31
    wire [15:0] la   = recip_lut(li);
    wire [15:0] lb   = recip_lut(li + 6'd1);
    wire signed [16:0] ldiff = $signed({1'b0, lb}) - $signed({1'b0, la});   // 负
    wire signed [31:0] lprod = ldiff * $signed({1'b0, mant[1:0]});          // ×0..3
    wire signed [31:0] lstep = lprod >>> 2;            // diff*f/4
    //  ⚠ 不能写 `lprod[17:2][15:0]`（链式切片不合法），要拆成两个中间量
    wire signed [31:0] rsum  = $signed({16'd0, la}) + lstep;
    //  1/(1+mant/128) 的 Q1.15 值（0.5~1.0，bit15 量级）
    wire [15:0] recip_mant = rsum[15:0];

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
    wire [47:0] gprod = recip_mant * {24'd0, THRESH[23:0]};
    wire [15:0] recip_raw = gprod >> nk;               // nk = k
    //  --- 保守余量：g −= (g >> 7)，即再降约 0.39%（0.034 dB，听感无感）---
    //  ⚠ 为什么必须留余量：倒数近似有 **+0.021%** 的增益误差，而该误差会经
    //    **包络反馈**放大（增益偏大 → 输出偏大 → env 偏大 → 再看下一拍）。
    //    实测不留余量时过载输出会**越过阈值 0.4%**（6295166 > 6291456），
    //    `tb_limiter` 第 2/5 项就会失败。留 0.39% 后全场景都不越阈值。
    wire [15:0] recip_final = recip_raw - {9'd0, recip_raw[15:7]};

    // 测试模式：阈值拉满 → env 永不超阈值 → 增益恒为 1.0（附三"Threshold 设为 1.0"）
    wire [23:0] th_eff  = test_mode ? 24'sh7FFFFF : THRESH;
    wire [15:0] g_tgt   = (env <= th_eff) ? 16'd32768 : recip_final;

    // ---------------- 增益平滑：Attack 立即、Release 一阶 ----------------
    //   ⚠ 文档："G_target 小于 G_limit[n-1] 时立即响应" → 压下来不延迟（防爆音）
    //  ⚠⚠ 用**组合**的本拍增益 `g_cur` 去算本拍输出，而不是用它打一拍后的寄存器 `g`：
    //     否则过载出现的那一拍用旧增益（1.0），输出会**瞬间超过阈值**（实测 6312337 > 6291456）。
    //     这就是"Attack ≈ 0"的落法：G_target 当拍就生效，输出永不过冲。
    reg  [15:0] g;                                   // Q1.15，初值 1.0
    wire [15:0] g_diff  = (g > g_tgt) ? (g - g_tgt) : (g_tgt - g);
    // 释放用的一阶步长：+ 四舍五入，保证能走到 +1；差值 ≤1 时直接到位
    wire [15:0] g_rel   = (g_tgt > g) ? (((g_diff >> RELEASE_SHIFT) == 0) ? 16'd1
                                                                          : (g_diff >> RELEASE_SHIFT))
                                      : 16'd0;
    wire [15:0] g_nxt   = (g_tgt <  g) ? g_tgt                     // Attack：当拍压到位
                        : (g_tgt >  g) ? ((g + g_rel > g_tgt) ? g_tgt : (g + g_rel))
                        :                g;
    wire [15:0] g_cur   = (g_tgt < g) ? g_tgt : g;                  // 本拍实际生效的增益

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g <= 16'd32768;                          // 复位初值 1.0（文档要求）
        end else if (en) begin
            g <= g_nxt;
        end
    end

    // ---------------- 施加增益 + 饱和 + 打一拍 ----------------
    function signed [AW-1:0] sat24;
        input signed [47:0] v;
        begin
            if      (v >  48'sd8388607) sat24 = 24'sh7FFFFF;
            else if (v < -48'sd8388608) sat24 = 24'sh800000;
            else                        sat24 = v[AW-1:0];
        end
    endfunction

    wire signed [47:0] lp = $signed(l_in) * $signed({1'b0, g_cur});
    wire signed [47:0] rp = $signed(r_in) * $signed({1'b0, g_cur});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
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
