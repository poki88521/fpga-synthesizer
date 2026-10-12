//============================================================================
//  svf_voice —— Chamberlin 数字状态变量滤波器（单个泳道）
//
//  依据：documents/技术文档.md  §五.1.5（SVF）、§五.1.6
//        documents/硬件实现.md §五.5.2（接口）、§四.2（2）（限幅与钳位）
//
//  差分方程（按文档逐行顺序：high 用**更新后**的 low，band 用**更新后**的 high）：
//      low  = low  + f × band
//      high = input − low − q × band
//      band = band + f × high
//
//  状态变量 ↔ 声部状态表字段：low ↔ filter_ic1，band ↔ filter_ic2（集成电路状态）
//  内部状态 32 位有符号，输出取 [31:8] 得 24 位。
//  f_coeff / q_coeff 为 Q1.15（最大 32767 代表 0.99997）。
//
//  §四.2（2）「滤波器内部状态：先对系数 f 限幅（保证稳定），再对状态幅值钳位兜底」
//   → 本模块两件都做：F_MAX 限幅 + sat32 钳位。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module svf_voice #(
    // f 的上限（Q1.15）。32767 ≈ 0.99997 为 Q1.15 本身的上限。
    // 调小可换取更高 Q 下的稳定余量（Chamberlin 在 f→2 时发散）。
    parameter signed [15:0] F_MAX = 16'sd32767
) (
    input  wire        clk,
    input  wire        rst_n_sync,
    input  wire        sample_en,
    input  wire signed [23:0] audio_in,     // 来自 DDS，Q1.23
    input  wire [15:0] f_coeff,             // Q1.15
    input  wire [15:0] q_coeff,             // Q1.15
    input  wire [1:0]  filter_type,         // 0=LP, 1=BP, 2=HP
    output reg  signed [23:0] audio_out,    // 送往 VCA
    output wire signed [31:0] filter_ic1,   // = low ，写回声部状态表
    output wire signed [31:0] filter_ic2    // = band，写回声部状态表
);

    reg signed [31:0] low, band, high;

    assign filter_ic1 = low;
    assign filter_ic2 = band;

    //---------------- 系数扩展与限幅 ----------------
    // 显式 $signed：f_coeff 与 F_MAX 一个有符号一个无符号时，Verilog 会按无符号比较。
    wire signed [15:0] f_lim = ($signed(f_coeff) > F_MAX) ? F_MAX : $signed(f_coeff);

    // 全部用 64 位有符号容器，避免 32×32 乘法在自决定上下文里被截成 32 位
    wire signed [63:0] f_ext  = {{48{f_lim[15]}},    f_lim};
    wire signed [63:0] q_ext  = {{48{q_coeff[15]}},  q_coeff};
    wire signed [63:0] low64  = {{32{low[31]}},      low};
    wire signed [63:0] band64 = {{32{band[31]}},     band};

    // ⚠ 尺度对齐：内部状态是 **Q1.31**（32 位有符号，输出取 [31:8] 得 Q1.23），
    //   而 audio_in 是 Q1.23（24 位）。两者差 8 位，必须先把输入 **左移 8 位**
    //   抬到 Q1.31。旧稿写的是 `{{8{audio_in[23]}}, audio_in}`（仅符号扩展、
    //   没有移位），会让整个滤波器**固定衰减 2^-8 ≈ −48 dB**。
    //   24 位 Q1.23 左移 8 位恰好填满 32 位 Q1.31，不丢位、不溢出。
    wire signed [63:0] in_ext = {{40{audio_in[23]}}, audio_in} <<< 8;

    //---------------- 状态钳位（§四.2（2）兜底） ----------------
    function signed [31:0] sat32;
        input signed [63:0] v;
        begin
            if      (v >  64'sd2147483647) sat32 = 32'sh7FFFFFFF;
            else if (v < -64'sd2147483648) sat32 = 32'sh80000000;
            else                           sat32 = v[31:0];
        end
    endfunction

    //---------------- 差分方程 ----------------
    // ⚠ Verilog 有符号陷阱：拼接 {a, b} **永远是无符号的**（与 a、b 是否有符号无关）。
    //   若把拼接直接写进乘法 `f_ext * {{32{high_n[31]}}, high_n}`，
    //   整个乘法表达式会变成无符号 → 紧随其后的 `>>>` 退化为**逻辑右移**，
    //   负的 high_n 会瞬间把状态冲到 32 位上限。
    //   因此每个操作数都必须先落到「已声明为 wire signed 的中间量」再参与运算。
    //  ⚠ 量程说明（lint 会警告"乘积可能被截断"，此处**经核算不会溢出**）：
    //     f_ext 是 Q1.15 的 f 做符号扩展 → |f_ext| ≤ 32767
    //     band64 是 32 位 band 的符号扩展 → |band64| ≤ 2^31
    //     乘积 ≤ 2^46 << 2^63，64 位绰绰有余。
    //     但**前提是 f 始终保持 Q1.15（≤1.0）**；若将来改 f 的定标，必须重新核算。
    wire signed [63:0] f_band = (f_ext * band64) >>> 15;   // f × band（旧 band）
    wire signed [63:0] q_band = (q_ext * band64) >>> 15;   // q × band（旧 band）

    wire signed [63:0] low_n64  = low64 + f_band;
    wire signed [31:0] low_n    = sat32(low_n64);

    wire signed [63:0] low_n64e = {{32{low_n[31]}}, low_n};
    wire signed [63:0] high_n64 = in_ext - low_n64e - q_band;
    wire signed [31:0] high_n   = sat32(high_n64);

    wire signed [63:0] high64   = {{32{high_n[31]}}, high_n};
    wire signed [63:0] f_high   = (f_ext * high64) >>> 15;
    wire signed [63:0] band_n64 = band64 + f_high;
    wire signed [31:0] band_n   = sat32(band_n64);

    //---------------- 时序 ----------------
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            low       <= 32'sd0;
            band      <= 32'sd0;
            high      <= 32'sd0;
            audio_out <= 24'sd0;
        end else if (sample_en) begin
            low  <= low_n;
            high <= high_n;
            band <= band_n;

            case (filter_type)
                2'd0:    audio_out <= low_n[31:8];    // 低通
                2'd1:    audio_out <= band_n[31:8];   // 带通
                2'd2:    audio_out <= high_n[31:8];   // 高通
                default: audio_out <= low_n[31:8];
            endcase
        end
    end

endmodule

`default_nettype wire
