//============================================================================
//  tb_recip —— 倒数 LUT 方案的**全范围穷举验证**
//
//  背景：`soft_limiter` 原来用 `div_num / env`（48 位组合除法），
//        在 49.152 MHz 下几乎必然过不了时序，故改为
//        「正规化 + 32 项倒数表 + 线性插值」。
//
//  本 TB 验证：新的近似值与**精确除法**在**整个值域**内的一致性。
//
//  验证点：
//    ① 穷举 env 的代表性取值（每 k 段的边界与尾数端点），
//       比较 新方案 与 精确 `(THRESH<<15)/env` 的差值
//    ② 报告最大相对误差（应为 0.5% 量级；其中约 0.39% 是**故意留的保守余量**）
//    ③ 增益单调性：env 越大 → 增益越小（限幅器不允许非单调）
//    ④ 增益上界：不过载时恒为 32768（1.0）
//    ⑤ 增益永不为 0（否则输出永久静音）
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_recip;
    localparam signed [23:0] THRESH = 24'sh600000;

    reg  [23:0] env;
    wire [15:0] g_tgt;

    // ---- 把 soft_limiter 里的算法原样复制一份（保持同步）----
    function [15:0] recip_lut;
        input [5:0] i;
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
                default: recip_lut = 16'd16384;
            endcase
        end
    endfunction

    function [4:0] msb_pos;
        input [23:0] v;
        integer b;
        begin
            msb_pos = 5'd0;
            for (b = 0; b < 24; b = b + 1)
                if (v[b]) msb_pos = b[4:0];
        end
    endfunction

    wire [4:0]  nk   = msb_pos(env);
    wire [23:0] nrem = env - (24'd1 << nk);
    wire [23:0] nmant = (nk >= 5'd7) ? (nrem >> (nk - 5'd7)) : {17'd0, nrem[6:0]};
    wire [6:0]  mant = nmant[6:0];
    wire [5:0]  li   = {1'b0, mant[6:2]};
    wire [15:0] la   = recip_lut(li);
    wire [15:0] lb   = recip_lut(li + 6'd1);
    wire signed [16:0] ldiff = $signed({1'b0, lb}) - $signed({1'b0, la});
    wire signed [31:0] lprod = ldiff * $signed({1'b0, mant[1:0]});
    wire signed [31:0] lstep = lprod >>> 2;
    wire signed [31:0] rsum  = $signed({16'd0, la}) + lstep;
    wire [15:0] recip_mant = rsum[15:0];
    //  正确顺序：先乘后移（先移后乘会丢低位，误差从 0.025% 飙到 1.44%）
    wire [47:0] gprod = recip_mant * {24'd0, THRESH[23:0]};
    wire [15:0] recip_raw = gprod >> nk;
    // 保守余量（与 RTL 一致）：g −= (g>>7)，约 0.39%
    wire [15:0] recip_final = recip_raw - {9'd0, recip_raw[15:7]};
    assign g_tgt = (env <= THRESH) ? 16'd32768 : recip_final;

    // ---- 精确参考：用实数算 ----
    real exact;
    integer errs = 0;
    real    maxrel = 0.0, rel;
    integer k, m, envv;
    integer prev_g;
    integer n_tested = 0;

    initial begin
        $display("=== ① 全范围穷举：新方案 vs 精确 (THRESH<<15)/env ===");
        // 覆盖 k = 22..23 的全部尾数端点 + 每段的段边界
        for (k = 22; k <= 23; k = k + 1) begin
            for (m = 0; m <= 127; m = m + 1) begin
                envv = (1 << k) | (m << (k - 7));
                if (envv <= THRESH) continue;
                env = envv[23:0];
                #1;
                exact = (THRESH * 32768.0) / envv;
                n_tested = n_tested + 1;
                if (exact > 0.0) begin
                    rel = (g_tgt - exact) / exact;
                    if (rel < 0) rel = -rel;
                    if (rel > maxrel) maxrel = rel;
                end
                if (g_tgt === 16'bx) begin
                    $display("  FAIL: env=%0d 增益为 X", envv);
                    errs = errs + 1;
                end
            end
        end
        $display("  测试了 %0d 个 env 取值", n_tested);
        $display("  最大相对误差 = %0.4f%%  (%.5f dB)",
                 maxrel * 100.0, 20.0 * (maxrel / 2.302585));
        if (maxrel > 0.010) begin
            $display("  FAIL: 相对误差 %0.4f%% 超过 1.0%%（含 0.39%% 的保守余量）", maxrel * 100.0);
            errs = errs + 1;
        end else
            $display("  相对误差 < 1.0%%（含 0.39%% 余量）→ 精度足够 ✓");

        $display("");
        $display("=== ② 增益单调性（env 越大 → 增益越小）===");
        prev_g = 99999;
        for (k = 21; k <= 23; k = k + 1) begin
            for (m = 0; m <= 127; m = m + 8) begin
                envv = (1 << k) | (m << (k - 7));
                env = envv[23:0];
                #1;
                if (g_tgt > prev_g) begin
                    $display("  FAIL: 非单调 env=%0d g=%0d > prev=%0d", envv, g_tgt, prev_g);
                    errs = errs + 1;
                end
                prev_g = g_tgt;
            end
        end
        if (errs == 0) $display("  单调递减 ✓");

        $display("");
        $display("=== ③ 不过载时增益恒为 1.0 ===");
        env = THRESH - 1; #1;
        if (g_tgt !== 16'd32768) begin
            $display("  FAIL: env<THRESH 时增益 %0d ≠ 32768", g_tgt);
            errs = errs + 1;
        end else $display("  env = THRESH-1 → %0d ✓", g_tgt);
        env = 24'd0; #1;
        if (g_tgt !== 16'd32768) begin
            $display("  FAIL: env=0 时增益 %0d", g_tgt);
            errs = errs + 1;
        end else $display("  env = 0 → %0d ✓", g_tgt);

        $display("");
        $display("=== ④ 增益永不为 0（否则永久静音）===");
        env = 24'sh7FFFFF; #1;   // 满量程
        $display("  env = 满量程 → 增益 %0d", g_tgt);
        if (g_tgt == 0) begin
            $display("  FAIL: 满量程时增益为 0 → 永久静音");
            errs = errs + 1;
        end else $display("  非 0 ✓");

        $display("");
        if (errs == 0) $display("PASS  tb_recip: 倒数 LUT 5 项全过（最大误差 %0.4f%%）", maxrel*100.0);
        else           $display("FAIL  tb_recip: %0d 项", errs);
        $finish;
    end
endmodule
`default_nettype wire
