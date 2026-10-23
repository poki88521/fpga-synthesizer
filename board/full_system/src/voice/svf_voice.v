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
    input  wire [1:0]  slot,                // 当前时隙号（4 份状态的选择子，2026-10-21）
    input  wire signed [23:0] audio_in,     // 来自 DDS，Q1.23
    input  wire [15:0] f_coeff,             // Q1.15
    input  wire [15:0] q_coeff,             // Q1.15
    input  wire [1:0]  filter_type,         // 0=LP, 1=BP, 2=HP
    output reg  signed [23:0] audio_out,    // 送往 VCA
    output wire signed [31:0] filter_ic1,   // = low ，写回声部状态表
    output wire signed [31:0] filter_ic2    // = band，写回声部状态表
);

    //  4 份滤波器状态（2026-10-21，方案 A）：
    //    一条泳道时分复用服务 4 个声部，而 low/band 只有一套 → 4 个声部的滤波器
    //    状态互相污染（每帧被推进 4 次、还混着别的声部的输入）。
    //    改成按 slot 索引的 4 份状态；流水启动时锁存时隙号，收尾写回同一份。
    //    资源：64 bit × 4 × 8 泳道 = 2048 个寄存器。
    reg signed [31:0] low_r  [0:3];
    reg signed [31:0] band_r [0:3];
    reg        [1:0]  s1_slot;          // 本次流水对应的时隙（写回用）
    integer i;

    wire signed [31:0] low  = low_r [slot];
    wire signed [31:0] band = band_r[slot];

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

    //====================================================================
    //  4 级流水（2026-10-18）
    //
    //  原实现是"单周期组合算完整条差分方程"：
    //      f×band（64 位乘）→ 加 → sat32(64 位比较) → 符号扩展
    //      → 减 → sat32 → 符号扩展 → f×high（第二次 64 位乘）→ 加 → sat32
    //  两次 64 位乘法串联 + 三次 64 位比较，P&R 实测 **33.69 ns**，
    //  而时钟周期只有 20.345 ns → 最差 slack −5.209 ns、1655 个违例。
    //
    //  ⚠ 为什么可以拆：SVF 每个样本只更新一次（`sample_en` = 时隙节拍），
    //    而时钟是它的 1024 倍（49.152 MHz vs 48 kHz）。**有 1024 拍可用**，
    //    拆 4 级只占 4 拍，对功能零影响，只是输出晚 3 拍（≈61 ns）。
    //
    //  **数学保持完全不变**（只插入寄存器，不改变运算顺序与舍入），
    //  所以 `tb_svf_voice` 的"逐样本位精确比对"仍然成立（采样点顺延即可）。
    //====================================================================

    //  —— 第 1 级：两次系数乘法（并行）——
    wire signed [63:0] f_band_p = (f_ext * band64) >>> 15;   // f × band（旧 band）
    wire signed [63:0] q_band_p = (q_ext * band64) >>> 15;   // q × band（旧 band）

    //  —— 第 2 级：low_n ——
    //  ⚠ 2026-10-20：曾试过加直流泄漏项（`s1_low - (s1_low >>> 12)`）来治
    //     "低音区炸"的问题。**实测证明 SVF 本来就没有漂移**（见下），故已撤回。
    //     测试方法：单独例化本模块，喂 C2/C4/C6 正弦各 10 万采样，量
    //       max|low| / max|band| / 输出直流 —— 三档频率结果**完全相同**：
    //         max|low| = 47.7%、max|band| = 0.3%、直流 < 1.4 万（可忽略）
    //     说明积分器有界、无漂移、无频率依赖。
    //     **撤掉泄漏项是为了保住 tb_svf_voice 的逐位精确比对**（那是本工程最强的测试）。
    wire signed [63:0] low_n64_p  = s1_low + s1_fband;
    wire signed [31:0] low_n_p    = sat32(low_n64_p);

    //  —— 第 3 级：high_n ——
    wire signed [63:0] low_n_e_p  = {{32{s2_low_n[31]}}, s2_low_n};
    wire signed [63:0] high_n64_p = s1_in - low_n_e_p - s1_qband;
    wire signed [31:0] high_n_p   = sat32(high_n64_p);

    //  —— 第 4 级：band_n + 写回 + 输出 ——
    wire signed [63:0] high_e_p   = {{32{s3_high_n[31]}}, s3_high_n};
    wire signed [63:0] f_high_p   = (s1_f * high_e_p) >>> 15;
    wire signed [63:0] band_n64_p = s1_band + f_high_p;
    wire signed [31:0] band_n_p   = sat32(band_n64_p);

    //  —— 流水寄存器 ——
    reg [2:0]  ph;                       // 0=空闲，1..3=各级，4=收尾
    reg signed [63:0] s1_fband, s1_qband, s1_in, s1_low, s1_band, s1_f;
    reg        [1:0]  s1_ftype;
    reg signed [31:0] s2_low_n;
    reg signed [31:0] s3_high_n;

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            ph        <= 3'd0;
            for (i = 0; i < 4; i = i + 1) begin
                low_r [i] <= 32'sd0;
                band_r[i] <= 32'sd0;
            end
            s1_slot   <= 2'd0;
            audio_out <= 24'sd0;
            s1_fband  <= 64'sd0;
            s1_qband  <= 64'sd0;
            s1_in     <= 64'sd0;
            s1_low    <= 64'sd0;
            s1_band   <= 64'sd0;
            s1_f      <= 64'sd0;
            s1_ftype  <= 2'd0;
            s2_low_n  <= 32'sd0;
            s3_high_n <= 32'sd0;
        end else begin
            case (ph)
                3'd0: if (sample_en) begin
                          // 锁存旧状态、输入与系数，启动第 1 级
                          s1_slot  <= slot;
                          s1_fband <= f_band_p;
                          s1_qband <= q_band_p;
                          s1_in    <= in_ext;
                          s1_low   <= low64;
                          s1_band  <= band64;
                          s1_f     <= f_ext;
                          s1_ftype <= filter_type;
                          ph       <= 3'd1;
                      end
                3'd1: begin s2_low_n  <= low_n_p;   ph <= 3'd2; end
                3'd2: begin s3_high_n <= high_n_p;  ph <= 3'd3; end
                3'd3: begin
                          low_r [s1_slot] <= s2_low_n;
                          band_r[s1_slot] <= band_n_p;
                          case (s1_ftype)
                              2'd0:    audio_out <= s2_low_n[31:8];    // 低通
                              2'd1:    audio_out <= band_n_p[31:8];   // 带通
                              2'd2:    audio_out <= s3_high_n[31:8];  // 高通
                              default: audio_out <= s2_low_n[31:8];
                          endcase
                          ph <= 3'd4;
                      end
                default: ph <= 3'd0;
            endcase
        end
    end
endmodule

`default_nettype wire
