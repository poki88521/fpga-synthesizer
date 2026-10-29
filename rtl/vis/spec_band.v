//  ============================================================================
//  spec_band.v —— 32 频带实时频谱（Goertzel 旋转式，2026-10-29 第 4 版）
//
//  ── 为什么前三版都失败（答应我，改之前先读完这段）────────────────────────────
//  v1  32 个并行 Goertzel，`reg [31:0] y1[0:31]` + **变量索引**读写
//      ⇒ 综合成 32 选 1 读 + 32 选 1 写译码，单拍 27.5 ns
//      ⇒ 588 个 Setup 违例，最差 −7.16 ns，音频域 Fmax 49 → 36.4 MHz
//  v2  y1/y2/bars 改三块 RAM、读写分相位 ⇒ 编译过但功能错（相位/地址/系数错配）
//  v3  单点扫描（256 采样算一个频带、32 轮换）+ **柱高取 msb(|y1|)**
//      ⇒ 数学是错的。60 Hz 频带极点几乎在 z=1，等效于对输入求平均；
//        1 kHz 单音的窗内均值不为 0，被放大上万倍 ⇒ band0~5 直接饱和。
//      Python 复现 v3 错法：1 kHz 输入时 32 根柱 23 根 > 25 px，峰值落在 band0。
//
//  ── 本版做法（数学先在 Python 定死：scratch/spec/spec_fixed.py）──────────────
//  · **旋转式单数据通路**：一份 Goertzel 运算单元，32 个频带的状态放 32 级**移位环**。
//    每个采样把环正好转一圈（每频带 2 拍）⇒ **32 个频带每采样都更新**（不是 v3 的
//    每 256 采样才更新一个），刷新 46.9 Hz。
//    环里只有相邻寄存器的直接传递（ry1_00 <= ry1_01 ...），没有变量索引、没有数组。
//  ⚠ 移位环**必须写成 32 个显式标量寄存器**（ry1_00 … ry1_31），绝不能写回
//    `reg [33:0] ry1 [0:31]`。用数组时 Gowin 综合器会把 32×68 bit 的环推断成
//    2 块 BSRAM（SDPX9B），u_spec 的触发器从 2176 掉到 780；门级仿真（prim_sim.v）
//    表明该映射读不出状态 —— 输出柱高恒 0，而同一激励跑 RTL 是 79 px。
//    标量形式没有"可寻址数组"可供推断，代价是多 2176 个触发器（设备占 1.6%）。
//  · 每采样 1024 拍（49.152 MHz / 48 kHz），本模块用 1 + 32×2 = **65 拍**，余量 15 倍。
//  · 幅度用正确的 Goertzel 幅度 mag² = y1² + y2² − 2cosω·y1·y2（不是 |y1|）。
//  · 加**汉宁窗**（64 级表，纯 case，不需要 ROM/hex）：低频端 −41 → −78 dBFS。
//  · 系数 **Q20**（2cosω × 2^20，22 bit）：Q14 时 60 Hz 与 71.8 Hz 会量化成同一个
//    滤波器（都是 32767），最坏频率误差 14.6 Hz > 频带间距 11.85 Hz。
//  · 窗长 N=1024（21.33 ms）；柱高 vs 浮点黄金参考最大误差 3.4 px。
//
//  ── 定点规格（与 spec_fixed.py 逐位一致）────────────────────────────────────
//    系数  c  = round(2cos(w) * 2^20)         int22，32 项
//    窗    w64= round(hann * 64)              int7 (0..64)，64 项，w[n]=tab[n[9:4]]
//    加权  xw = (x * w64) >>> 6
//    状态  y1,y2 : 34 bit（满刻度 60 Hz 单音实测 2^30，留 3 位余量）
//    递推  prod = (c*y1 + 2^19) >>> 20
//          y1' = wrap34(xw + prod - y2) ; y2' = y1
//    幅度  块浮点 e = max(0, msb(max|y1|,|y2|) − 14)，ys = y >>> e（≤16 bit）
//          t = (c*ys2) >>> 20 ;  mag2 = ys1² + ys2² − t·ys1
//    对数  lg = log2_q8(mag2)（5 bit 尾数表）; L_Q5 = (lg*385) >>> 10
//    电平  level_Q5 = L_Q5 + 192e + ((42e)>>>6) − 4431
//    柱高  tt = level_Q5 + 2304 ; px = clamp((tt*25) >>> 9, 0, 100)  → -72..-8 dBFS
//    平滑  attack 1 帧；release old − (old>>>3)（约 170 ms）
//  ============================================================================
`default_nettype none

module spec_band #(
    parameter integer NB = 32,
    parameter integer AW = 16,
    parameter integer N  = 1024,
    parameter integer SW = 34,          // y1/y2 位宽
    parameter integer CQ = 20,          // 系数定标
    parameter integer CW = 22           // 系数位宽
)(
    input  wire                 clk,        // 音频域 49.152 MHz
    input  wire                 rst_n,
    input  wire                 sample_stb, // 每 1024 拍一次
    input  wire signed [AW-1:0] aud_in,
    output wire [NB*8-1:0]      bars,       // 32 × 8 bit 柱高（0..100）
    output reg                  bars_vld,   // 一轮窗口算完的一拍脉冲
    output reg                  bars_tgl    // 跨时钟域用的翻转标志（原子提交）
);
    localparam integer AWX = AW + 3;                 // 加窗后的 x 位宽（19）
    localparam signed [15:0] REF_Q5    = 16'sd4431;  // round(20log10(32768*N/2*mean(w))*32)
    localparam signed [15:0] PX_OFF_Q5 = 16'sd2304;  // 72 dB × 32

    //========================================================================
    //  1. 汉宁窗表 64 项 × 7 bit（第 n 个采样用 tab[n/16]）
    //========================================================================
    function [6:0] win_of;
        input [5:0] i;
        begin
            case (i)
                6'd0 : win_of = 7'd0 ;  6'd1 : win_of = 7'd0 ;  6'd2 : win_of = 7'd1 ;
                6'd3 : win_of = 7'd1 ;  6'd4 : win_of = 7'd2 ;  6'd5 : win_of = 7'd4 ;
                6'd6 : win_of = 7'd5 ;  6'd7 : win_of = 7'd7 ;  6'd8 : win_of = 7'd9 ;
                6'd9 : win_of = 7'd12;  6'd10: win_of = 7'd14;  6'd11: win_of = 7'd17;
                6'd12: win_of = 7'd20;  6'd13: win_of = 7'd23;  6'd14: win_of = 7'd26;
                6'd15: win_of = 7'd29;  6'd16: win_of = 7'd32;  6'd17: win_of = 7'd35;
                6'd18: win_of = 7'd38;  6'd19: win_of = 7'd41;  6'd20: win_of = 7'd44;
                6'd21: win_of = 7'd47;  6'd22: win_of = 7'd50;  6'd23: win_of = 7'd52;
                6'd24: win_of = 7'd55;  6'd25: win_of = 7'd57;  6'd26: win_of = 7'd59;
                6'd27: win_of = 7'd60;  6'd28: win_of = 7'd62;  6'd29: win_of = 7'd63;
                6'd30: win_of = 7'd63;  6'd31: win_of = 7'd64;  6'd32: win_of = 7'd64;
                6'd33: win_of = 7'd64;  6'd34: win_of = 7'd63;  6'd35: win_of = 7'd63;
                6'd36: win_of = 7'd62;  6'd37: win_of = 7'd60;  6'd38: win_of = 7'd59;
                6'd39: win_of = 7'd57;  6'd40: win_of = 7'd55;  6'd41: win_of = 7'd52;
                6'd42: win_of = 7'd50;  6'd43: win_of = 7'd47;  6'd44: win_of = 7'd44;
                6'd45: win_of = 7'd41;  6'd46: win_of = 7'd38;  6'd47: win_of = 7'd35;
                6'd48: win_of = 7'd32;  6'd49: win_of = 7'd29;  6'd50: win_of = 7'd26;
                6'd51: win_of = 7'd23;  6'd52: win_of = 7'd20;  6'd53: win_of = 7'd17;
                6'd54: win_of = 7'd14;  6'd55: win_of = 7'd12;  6'd56: win_of = 7'd9 ;
                6'd57: win_of = 7'd7 ;  6'd58: win_of = 7'd5 ;  6'd59: win_of = 7'd4 ;
                6'd60: win_of = 7'd2 ;  6'd61: win_of = 7'd1 ;  6'd62: win_of = 7'd1 ;
                default: win_of = 7'd0;
            endcase
        end
    endfunction

    //========================================================================
    //  2. 系数表 2cos(w) × 2^20（32 项，22 bit 有符号）
    //     f_i = 60 × (16000/60)^(i/31)，fs = 48 kHz
    //========================================================================
    function signed [CW-1:0] coef_of;
        input [4:0] i;
        begin
            case (i)
                5'd0 : coef_of = 22'sd2097087;  5'd1 : coef_of = 22'sd2097059;
                5'd2 : coef_of = 22'sd2097019;  5'd3 : coef_of = 22'sd2096961;
                5'd4 : coef_of = 22'sd2096879;  5'd5 : coef_of = 22'sd2096760;
                5'd6 : coef_of = 22'sd2096590;  5'd7 : coef_of = 22'sd2096346;
                5'd8 : coef_of = 22'sd2095996;  5'd9 : coef_of = 22'sd2095495;
                5'd10: coef_of = 22'sd2094776;  5'd11: coef_of = 22'sd2093745;
                5'd12: coef_of = 22'sd2092268;  5'd13: coef_of = 22'sd2090150;
                5'd14: coef_of = 22'sd2087114;  5'd15: coef_of = 22'sd2082764;
                5'd16: coef_of = 22'sd2076532;  5'd17: coef_of = 22'sd2067606;
                5'd18: coef_of = 22'sd2054830;  5'd19: coef_of = 22'sd2036556;
                5'd20: coef_of = 22'sd2010447;  5'd21: coef_of = 22'sd1973201;
                5'd22: coef_of = 22'sd1920188;  5'd23: coef_of = 22'sd1844977;
                5'd24: coef_of = 22'sd1738773;  5'd25: coef_of = 22'sd1589823;
                5'd26: coef_of = 22'sd1382991;  5'd27: coef_of = 22'sd1099967;
                5'd28: coef_of = 22'sd721078 ;  5'd29: coef_of = 22'sd230538 ;
                5'd30: coef_of = -22'sd371843;  default: coef_of = -22'sd1048576;
            endcase
        end
    endfunction

    //========================================================================
    //  3. log2 尾数表（5 bit 尾数 → Q8 小数，32 项）
    //========================================================================
    function [7:0] log2frac;
        input [4:0] i;
        begin
            case (i)
                5'd0 : log2frac = 8'd0  ;  5'd1 : log2frac = 8'd11 ;
                5'd2 : log2frac = 8'd22 ;  5'd3 : log2frac = 8'd33 ;
                5'd4 : log2frac = 8'd44 ;  5'd5 : log2frac = 8'd54 ;
                5'd6 : log2frac = 8'd63 ;  5'd7 : log2frac = 8'd73 ;
                5'd8 : log2frac = 8'd82 ;  5'd9 : log2frac = 8'd92 ;
                5'd10: log2frac = 8'd100;  5'd11: log2frac = 8'd109;
                5'd12: log2frac = 8'd118;  5'd13: log2frac = 8'd126;
                5'd14: log2frac = 8'd134;  5'd15: log2frac = 8'd142;
                5'd16: log2frac = 8'd150;  5'd17: log2frac = 8'd157;
                5'd18: log2frac = 8'd165;  5'd19: log2frac = 8'd172;
                5'd20: log2frac = 8'd179;  5'd21: log2frac = 8'd186;
                5'd22: log2frac = 8'd193;  5'd23: log2frac = 8'd200;
                5'd24: log2frac = 8'd207;  5'd25: log2frac = 8'd213;
                5'd26: log2frac = 8'd220;  5'd27: log2frac = 8'd226;
                5'd28: log2frac = 8'd232;  5'd29: log2frac = 8'd238;
                5'd30: log2frac = 8'd244;  default: log2frac = 8'd250;
            endcase
        end
    endfunction

    //========================================================================
    //  4. 移位环 + 状态
    //========================================================================
    //  ⚠ 刻意写成 32 个标量而不是数组：数组会被综合器推断成 BSRAM
    //     （详见文件头）。不要「优化」回 `reg [33:0] ry1 [0:31]`。

    reg signed [SW-1:0] ry1_00, ry1_01, ry1_02, ry1_03;
    reg signed [SW-1:0] ry1_04, ry1_05, ry1_06, ry1_07;
    reg signed [SW-1:0] ry1_08, ry1_09, ry1_10, ry1_11;
    reg signed [SW-1:0] ry1_12, ry1_13, ry1_14, ry1_15;
    reg signed [SW-1:0] ry1_16, ry1_17, ry1_18, ry1_19;
    reg signed [SW-1:0] ry1_20, ry1_21, ry1_22, ry1_23;
    reg signed [SW-1:0] ry1_24, ry1_25, ry1_26, ry1_27;
    reg signed [SW-1:0] ry1_28, ry1_29, ry1_30, ry1_31;

    reg signed [SW-1:0] ry2_00, ry2_01, ry2_02, ry2_03;
    reg signed [SW-1:0] ry2_04, ry2_05, ry2_06, ry2_07;
    reg signed [SW-1:0] ry2_08, ry2_09, ry2_10, ry2_11;
    reg signed [SW-1:0] ry2_12, ry2_13, ry2_14, ry2_15;
    reg signed [SW-1:0] ry2_16, ry2_17, ry2_18, ry2_19;
    reg signed [SW-1:0] ry2_20, ry2_21, ry2_22, ry2_23;
    reg signed [SW-1:0] ry2_24, ry2_25, ry2_26, ry2_27;
    reg signed [SW-1:0] ry2_28, ry2_29, ry2_30, ry2_31;

    localparam [2:0] S_IDLE = 3'd0,
                     S_WIN  = 3'd1,
                     S_MUL  = 3'd2,
                     S_UPD  = 3'd3,
                     S_MEAS = 3'd4;

    reg [2:0]  st;
    reg [9:0]  wcnt;
    reg [4:0]  bcnt;
    reg [4:0]  mbnd;
    reg [3:0]  mst;

    reg signed [AW-1:0]    x_r;
    reg        [6:0]       w_r;
    reg signed [AWX-1:0]   xw_r;
    reg signed [CW-1:0]    c_r;
    reg signed [SW-1:0]    h1, h2;
    reg signed [CW+SW-1:0] prod;

    //========================================================================
    //  5. Goertzel 递推（组合）
    //========================================================================
    //  prod + 2^19（21 bit 常量，避免 20 bit 有符号放不下 2^19）
    wire signed [CW+SW-1:0] prod_r = prod + {{(CW+SW-21){1'b0}}, 21'sd524288};
    wire signed [SW+1:0]    prodsh = prod_r >>> CQ;

    //  y1' = xw + prodsh - y2（37 bit 中间和；截成 34 bit 即回绕）
    wire signed [SW+2:0] y1n_w = {{(SW+3-AWX){xw_r[AWX-1]}}, xw_r}
                               + {{1{prodsh[SW+1]}}, prodsh}
                               - {{3{h2[SW-1]}}, h2};
    wire signed [SW-1:0] y1n = y1n_w[SW-1:0];

    //  加窗乘法：同样必须先在 24 bit 的 wire 上做，否则会在 19 bit 上下文里溢出
    wire signed [AW+7:0] xmul = x_r * $signed({1'b0, w_r});

    wire push_meas = (st == S_MEAS) && (mst == 4'd13);
    wire ring_shift = (st == S_UPD) || push_meas;
    //  测量阶段把环转一圈：一边逐个读出各频带的 y1/y2 算柱高，一边把**零**压回去
    //  ⇒ 转满 32 格后整环清零，下一个窗口从零开始（等价于块处理 Goertzel 的复位）。
    //  ⚠ 这一步不能省！Goertzel 的极点就在单位圆上，是**无阻尼**振荡器：
    //     不清零的话声音停了状态也永远不衰减，柱子会一直卡在满格（实测残留 100 px）。
    wire signed [SW-1:0] push_y1 = push_meas ? {SW{1'b0}} : y1n;
    wire signed [SW-1:0] push_y2 = push_meas ? {SW{1'b0}} : h1;

    integer k;                       // hgt 复位循环还在用
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ry1_00 <= {SW{1'b0}}; ry1_01 <= {SW{1'b0}}; ry1_02 <= {SW{1'b0}}; ry1_03 <= {SW{1'b0}};
            ry1_04 <= {SW{1'b0}}; ry1_05 <= {SW{1'b0}}; ry1_06 <= {SW{1'b0}}; ry1_07 <= {SW{1'b0}};
            ry1_08 <= {SW{1'b0}}; ry1_09 <= {SW{1'b0}}; ry1_10 <= {SW{1'b0}}; ry1_11 <= {SW{1'b0}};
            ry1_12 <= {SW{1'b0}}; ry1_13 <= {SW{1'b0}}; ry1_14 <= {SW{1'b0}}; ry1_15 <= {SW{1'b0}};
            ry1_16 <= {SW{1'b0}}; ry1_17 <= {SW{1'b0}}; ry1_18 <= {SW{1'b0}}; ry1_19 <= {SW{1'b0}};
            ry1_20 <= {SW{1'b0}}; ry1_21 <= {SW{1'b0}}; ry1_22 <= {SW{1'b0}}; ry1_23 <= {SW{1'b0}};
            ry1_24 <= {SW{1'b0}}; ry1_25 <= {SW{1'b0}}; ry1_26 <= {SW{1'b0}}; ry1_27 <= {SW{1'b0}};
            ry1_28 <= {SW{1'b0}}; ry1_29 <= {SW{1'b0}}; ry1_30 <= {SW{1'b0}}; ry1_31 <= {SW{1'b0}};
            ry2_00 <= {SW{1'b0}}; ry2_01 <= {SW{1'b0}}; ry2_02 <= {SW{1'b0}}; ry2_03 <= {SW{1'b0}};
            ry2_04 <= {SW{1'b0}}; ry2_05 <= {SW{1'b0}}; ry2_06 <= {SW{1'b0}}; ry2_07 <= {SW{1'b0}};
            ry2_08 <= {SW{1'b0}}; ry2_09 <= {SW{1'b0}}; ry2_10 <= {SW{1'b0}}; ry2_11 <= {SW{1'b0}};
            ry2_12 <= {SW{1'b0}}; ry2_13 <= {SW{1'b0}}; ry2_14 <= {SW{1'b0}}; ry2_15 <= {SW{1'b0}};
            ry2_16 <= {SW{1'b0}}; ry2_17 <= {SW{1'b0}}; ry2_18 <= {SW{1'b0}}; ry2_19 <= {SW{1'b0}};
            ry2_20 <= {SW{1'b0}}; ry2_21 <= {SW{1'b0}}; ry2_22 <= {SW{1'b0}}; ry2_23 <= {SW{1'b0}};
            ry2_24 <= {SW{1'b0}}; ry2_25 <= {SW{1'b0}}; ry2_26 <= {SW{1'b0}}; ry2_27 <= {SW{1'b0}};
            ry2_28 <= {SW{1'b0}}; ry2_29 <= {SW{1'b0}}; ry2_30 <= {SW{1'b0}}; ry2_31 <= {SW{1'b0}};
        end else if (ring_shift) begin
            ry1_00 <= ry1_01;
            ry1_01 <= ry1_02;
            ry1_02 <= ry1_03;
            ry1_03 <= ry1_04;
            ry1_04 <= ry1_05;
            ry1_05 <= ry1_06;
            ry1_06 <= ry1_07;
            ry1_07 <= ry1_08;
            ry1_08 <= ry1_09;
            ry1_09 <= ry1_10;
            ry1_10 <= ry1_11;
            ry1_11 <= ry1_12;
            ry1_12 <= ry1_13;
            ry1_13 <= ry1_14;
            ry1_14 <= ry1_15;
            ry1_15 <= ry1_16;
            ry1_16 <= ry1_17;
            ry1_17 <= ry1_18;
            ry1_18 <= ry1_19;
            ry1_19 <= ry1_20;
            ry1_20 <= ry1_21;
            ry1_21 <= ry1_22;
            ry1_22 <= ry1_23;
            ry1_23 <= ry1_24;
            ry1_24 <= ry1_25;
            ry1_25 <= ry1_26;
            ry1_26 <= ry1_27;
            ry1_27 <= ry1_28;
            ry1_28 <= ry1_29;
            ry1_29 <= ry1_30;
            ry1_30 <= ry1_31;
            ry1_31 <= push_y1;
            ry2_00 <= ry2_01;
            ry2_01 <= ry2_02;
            ry2_02 <= ry2_03;
            ry2_03 <= ry2_04;
            ry2_04 <= ry2_05;
            ry2_05 <= ry2_06;
            ry2_06 <= ry2_07;
            ry2_07 <= ry2_08;
            ry2_08 <= ry2_09;
            ry2_09 <= ry2_10;
            ry2_10 <= ry2_11;
            ry2_11 <= ry2_12;
            ry2_12 <= ry2_13;
            ry2_13 <= ry2_14;
            ry2_14 <= ry2_15;
            ry2_15 <= ry2_16;
            ry2_16 <= ry2_17;
            ry2_17 <= ry2_18;
            ry2_18 <= ry2_19;
            ry2_19 <= ry2_20;
            ry2_20 <= ry2_21;
            ry2_21 <= ry2_22;
            ry2_22 <= ry2_23;
            ry2_23 <= ry2_24;
            ry2_24 <= ry2_25;
            ry2_25 <= ry2_26;
            ry2_26 <= ry2_27;
            ry2_27 <= ry2_28;
            ry2_28 <= ry2_29;
            ry2_29 <= ry2_30;
            ry2_30 <= ry2_31;
            ry2_31 <= push_y2;
        end
    end

    //========================================================================
    //  6. 测量用寄存器 / 组合
    //========================================================================
    reg  [5:0]         e_r;
    reg  signed [15:0] ys1, ys2;
    reg  signed [55:0] mult;
    reg  signed [31:0] p12;
    reg  signed [36:0] p1, p2, mag2;
    reg  [5:0]         pm;
    reg  [4:0]         mant;

    //  mag² = ys1² + ys2² − (c·ys1·ys2) >>> CQ
    //  ⚠ 必须用**三重积**后只截断一次。原来写成 t=(c·ys2)>>>CQ 再 t·ys1，
    //    t 上 1 LSB 的截断误差会被 ys1（≈2^14）放大到和 mag² 同量级 ——
    //    低频带 mag² = (y1−y2)² 本身就很小，直接丢掉约 8 dB（band0 由 100 掉到 87）。
    wire signed [35:0] p3_w = mult >>> CQ;

    //  max(|h1|,|h2|)（35 bit 符号扩展后取绝对值，避免 −2^33 取负溢出）
    //  ⚠ 这里必须是**符号扩展** `{{1{h1[33]}}, h1}`；写成 `{1'b0, h1}` 会把负数的
    //    二进制补码当正数，取绝对值后完全错（曾导致 msb 恒为 34、柱高恒 84）。
    wire [SW:0] a1  = {{1{h1[SW-1]}}, h1};
    wire [SW:0] a1n = (~a1) + 1'b1;
    wire [SW:0] a2  = {{1{h2[SW-1]}}, h2};
    wire [SW:0] a2n = (~a2) + 1'b1;
    wire [SW:0] mm1 = h1[SW-1] ? a1n : a1;
    wire [SW:0] mm2 = h2[SW-1] ? a2n : a2;
    wire [SW:0] mmax = (mm1 > mm2) ? mm1 : mm2;

    //  msb(max(|h1|,|h2|))
    //  ⚠ 必须写成 function：如果把 `for` 循环放在 always @(*) 里，循环变量既是
    //    读又是写，会进 always @(*) 的敏感表 ⇒ 零延迟自触发，仿真直接卡死。
    function [5:0] msb_of;
        input [SW:0] v;
        integer j;
        begin
            msb_of = 6'd0;
            for (j = 0; j <= SW; j = j + 1)
                if (v[j]) msb_of = j[5:0];
        end
    endfunction

    function [5:0] msb37;
        input [36:0] v;
        integer j;
        begin
            msb37 = 6'd0;
            for (j = 0; j <= 36; j = j + 1)
                if (v[j]) msb37 = j[5:0];
        end
    endfunction

    wire [5:0] msb_v = msb_of(mmax);
    wire [5:0] e_w = (msb_v > 6'd14) ? (msb_v - 6'd14) : 6'd0;
    wire [5:0] e_sh = e_r;

    //  log2：把 mag2 的 MSB 对齐到固定位置，取低 5 位作尾数
    wire [36:0] mpos   = (mag2 > 0) ? mag2 : 37'sd0;
    wire [5:0]  sh_r   = (pm >= 6'd5) ? (pm - 6'd5) : 6'd0;
    wire [5:0]  sh_l   = 6'd5 - pm;
    wire [36:0] shifted = (pm >= 6'd5) ? (mpos >> sh_r) : (mpos << sh_l);
    wire [13:0] lg_w    = {pm, 8'd0} + {6'd0, log2frac(mant)};

    //  电平（Q5 = 1/32 dB）
    //  ⚠ Verilog 的表达式位宽会按**赋值上下文**决定：把 `lg_w*385` 直接写进
    //    15 bit 的赋值里，乘法就会在 15 bit 上溢出。必须先用足够宽的 wire 承接。
    wire signed [23:0] lg385 = lg_w * 15'sd385;
    wire signed [13:0] e192 = 192 * $signed({1'b0, e_sh});
    wire signed [13:0] e42  = (42 * $signed({1'b0, e_sh})) >>> 6;
    wire signed [15:0] lev_w = (lg385 >>> 10) + e192 + e42 - REF_Q5;

    //  柱高 px（从**已寄存**的 lev_r 算，链路只有 1 乘 + 1 移位 + 比较）
    wire signed [16:0] tt_r    = lev_r + PX_OFF_Q5;
    wire signed [24:0] tt25_rw = tt_r * 17'sd25;
    wire signed [16:0] tt25_r  = tt25_rw >>> 9;
    wire        [7:0]  px_w    = (tt_r <= 0) ? 8'd0 :
                                 (tt25_r > 17'sd100) ? 8'd100 : tt25_r[7:0];

    //========================================================================
    //  6b. 测量流水线寄存器（把原来"一拍算完"的长链切成 4 段）
    //      ⚠ 这里必须逐级寄存。早先版本把 lev5/pxraw 写成组合 wire，
    //        实测最差路径 mant→hgt 20.633 ns > 20.345 ns 周期，
    //        209 个违例端点全压在这一条链上（音频域 Fmax 49.152 → 47.570）。
    //========================================================================
    reg [13:0]        lg_r;
    reg signed [15:0] lev_r;
    reg        [7:0]  px_r;

    //========================================================================
    //  7. 柱高寄存器 + 输出（生成块并出，纯连线无 mux）
    //========================================================================
    reg [7:0] hgt [0:NB-1];

    genvar gi;
    generate
        for (gi = 0; gi < NB; gi = gi + 1) begin : g_bars
            assign bars[gi*8 +: 8] = hgt[gi];
        end
    endgenerate

    //  释放：old − (old>>>3) − 1。那个 −1 不能省：只写 old − (old>>>3) 时
    //  old < 8 之后 old>>>3 == 0，柱高会**永远卡在 7 px** 下不去。
    wire [8:0] rel9 = {1'b0, hgt[mbnd]} - {1'b0, (hgt[mbnd] >> 3)} - 9'd1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < NB; k = k + 1) hgt[k] <= 8'd0;
        end else if ((st == S_MEAS) && (mst == 4'd13)) begin
            hgt[mbnd] <= (px_r > hgt[mbnd]) ? px_r
                                            : (rel9[8] ? 8'd0 : rel9[7:0]);
        end
    end

    //========================================================================
    //  8. 主状态机
    //========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            wcnt     <= 10'd0;
            bcnt     <= 5'd0;
            mbnd     <= 5'd0;
            mst      <= 4'd0;
            x_r      <= {AW{1'b0}};
            w_r      <= 7'd0;
            xw_r     <= {AWX{1'b0}};
            c_r      <= {CW{1'b0}};
            h1       <= {SW{1'b0}};
            h2       <= {SW{1'b0}};
            prod     <= {CW+SW{1'b0}};
            e_r      <= 6'd0;
            ys1      <= 16'sd0;
            ys2      <= 16'sd0;
            mult     <= 56'sd0;
            p12      <= 32'sd0;
            p1       <= 37'sd0;
            p2       <= 37'sd0;
            mag2     <= 37'sd0;
            pm       <= 6'd0;
            mant     <= 5'd0;
            lg_r     <= 14'd0;
            lev_r    <= 16'sd0;
            px_r     <= 8'd0;
            bars_vld <= 1'b0;
            bars_tgl <= 1'b0;
        end else begin
            bars_vld <= 1'b0;

            case (st)
            //--------------------------------------------------------------
            S_IDLE: begin
                bcnt <= 5'd0;
                if (sample_stb) begin
                    x_r <= aud_in;
                    w_r <= win_of(wcnt[9:4]);
                    st  <= S_WIN;
                end
            end
            //--------------------------------------------------------------
            S_WIN: begin
                xw_r <= xmul >>> 6;
                c_r  <= coef_of(5'd0);
                h1   <= ry1_00;
                h2   <= ry2_00;
                st   <= S_MUL;
            end
            //--------------------------------------------------------------
            S_MUL: begin
                prod <= c_r * h1;
                st   <= S_UPD;
            end
            //--------------------------------------------------------------
            S_UPD: begin
                if (bcnt == NB-1) begin
                    if (wcnt == N-1) begin
                        wcnt <= 10'd0;
                        mbnd <= 5'd0;
                        mst  <= 4'd0;
                        st   <= S_MEAS;
                    end else begin
                        wcnt <= wcnt + 10'd1;
                        st   <= S_IDLE;
                    end
                end else begin
                    bcnt <= bcnt + 5'd1;
                    c_r  <= coef_of(bcnt + 5'd1);
                    h1   <= ry1_01;
                    h2   <= ry2_01;
                    st   <= S_MUL;
                end
            end
            //--------------------------------------------------------------
            S_MEAS: begin
                case (mst)
                4'd0: begin h1 <= ry1_00; h2 <= ry2_00; c_r <= coef_of(mbnd); mst <= 4'd1; end
                4'd1: begin e_r <= e_w;                                              mst <= 4'd2; end
                4'd2: begin ys1 <= h1 >>> e_sh;  ys2 <= h2 >>> e_sh;                 mst <= 4'd3; end
                4'd3: begin mult <= ys1 * ys2;                                       mst <= 4'd4; end
                4'd4: begin p12  <= mult[31:0];  mult <= ys1 * ys1;                  mst <= 4'd5; end
                4'd5: begin p1   <= mult;        mult <= ys2 * ys2;                  mst <= 4'd6; end
                4'd6: begin p2   <= mult;        mult <= c_r * p12;                  mst <= 4'd7; end
                4'd7: begin mag2 <= p1 + p2 - p3_w;                                  mst <= 4'd8; end
                4'd8: begin pm <= msb37(mag2);                                       mst <= 4'd9; end
                4'd9: begin mant <= shifted[4:0];                                    mst <= 4'd10; end
                //  ---- 以下 4 拍把原来"一拍算完"的长链切成 4 段（见 6b 节说明）----
                4'd10: begin lg_r  <= lg_w;                                          mst <= 4'd11; end
                4'd11: begin lev_r <= lev_w;                                         mst <= 4'd12; end
                4'd12: begin px_r  <= px_w;                                          mst <= 4'd13; end
                default: begin   // 4'd13：写柱高（hgt 在另一个 always 里更新）+ 转环
                    mbnd <= mbnd + 5'd1;
                    mst  <= 4'd0;
                    if (mbnd == NB-1) begin
                        bars_vld <= 1'b1;
                        bars_tgl <= ~bars_tgl;
                        st       <= S_IDLE;
                    end
                end
                endcase
            end
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
`default_nettype wire
