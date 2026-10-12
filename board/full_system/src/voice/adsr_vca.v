//============================================================================
//  adsr_vca —— ADSR 包络 + VCA（单个泳道）
//
//  依据：documents/技术文档.md  §五.1.6（ADSR / VCA）
//        documents/硬件实现.md §五.5.3（接口）、§四.2（2）
//
//  口径（新文档为准）：
//    · 状态：IDLE / ATTACK / DECAY / SUSTAIN / PENDING_RELEASE / RELEASE
//      **不再保留 `pending_release` 标志** —— 状态机的状态是唯一权威
//    · env_value 为 **Q1.15，满量程 32767**（不是旧稿的 0~65535）
//    · attack_step = 32768 / (adsr_attack_ms × fs / 1000)
//    · adsr_curve：0 = 线性，1 = 指数
//    · VCA：voice_out = sat24( (p48 × g_vt) >>> 30 )
//              g_vt = (velocity_gain × vca_gain) >>> 15      （控制率先合并两个慢变系数）
//              p48  = audio_in × env_value （40 位，符号扩展进 48 位）
//      **中间不截断，只在最后饱和一次** —— 这是"口径混用=增益出错"的正解
//
//  指数曲线的实现选择（文档只给了方向，未定死）：
//    用一阶趋近 `x += (step × (target − x)) >>> 15`，初斜率与线性一致，
//    x → target 时增量自然变小；并强制增量 ≥ 1 保证有限时间收敛。
//    该式是「移位 + 减法」类近似的等价展开形式，只需 1 个乘法器。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module adsr_vca (
    input  wire        clk,
    input  wire        rst_n_sync,
    input  wire        sample_en,
    input  wire signed [23:0] audio_in,       // 来自 SVF，Q1.23
    input  wire        gate,                  // 按键按下 = 1
    input  wire        sustain_pedal,         // 延音踏板踩下 = 1
    input  wire [1:0]  adsr_curve,            // 0 = 线性，1 = 指数
    input  wire [15:0] attack_step,
    input  wire [15:0] decay_step,
    input  wire [15:0] sustain_level,
    input  wire [15:0] release_step,
    input  wire [15:0] velocity_gain,         // Q1.15
    input  wire [15:0] vca_gain,              // Q1.15
    output reg  signed [23:0] audio_out,      // 送往通道混音层
    output reg  [15:0] env_value,             // 写回声部状态表（Q1.15，0~32767）
    output reg  [2:0]  env_state              // 写回声部状态表
);

    localparam [2:0] IDLE            = 3'd0;
    localparam [2:0] ATTACK          = 3'd1;
    localparam [2:0] DECAY           = 3'd2;
    localparam [2:0] SUSTAIN         = 3'd3;
    localparam [2:0] PENDING_RELEASE = 3'd4;
    localparam [2:0] RELEASE         = 3'd5;

    localparam [15:0] MAX_ENV = 16'd32767;    // Q1.15 满量程

    // sustain_level 是 16 位字段，按 Q1.15 语义上限钳到 32767
    wire [15:0] sl = (sustain_level > MAX_ENV) ? MAX_ENV : sustain_level;

    //---------------- 指数曲线的增量 / 减量 ----------------
    // 一阶趋近：初斜率 = step，接近目标时自动减小
    wire [16:0] att_gap = {1'b0, MAX_ENV} - {1'b0, env_value};
    wire [32:0] att_mul = attack_step * att_gap[15:0];
    wire [15:0] att_inc = att_mul[30:15];                       // × step >>> 15
    wire [15:0] att_inc1 = (att_inc == 16'd0) ? 16'd1 : att_inc;

    wire [16:0] dec_gap = ({1'b0, env_value} > {1'b0, sl})
                        ? ({1'b0, env_value} - {1'b0, sl}) : 17'd0;
    wire [32:0] dec_mul = decay_step * dec_gap[15:0];
    wire [15:0] dec_dec = dec_mul[30:15];
    wire [15:0] dec_dec1 = (dec_dec == 16'd0) ? 16'd1 : dec_dec;

    wire [32:0] rel_mul = release_step * env_value;
    wire [15:0] rel_dec = rel_mul[30:15];
    wire [15:0] rel_dec1 = (rel_dec == 16'd0) ? 16'd1 : rel_dec;

    //---------------- 状态机（组合下一值） ----------------
    reg [15:0] env_next;
    reg [2:0]  state_next;

    wire [16:0] att_lin_sum = {1'b0, env_value} + {1'b0, attack_step};
    wire [16:0] att_exp_sum = {1'b0, env_value} + {1'b0, att_inc1};
    wire [16:0] dec_lin_thr = {1'b0, sl} + {1'b0, decay_step};
    wire [16:0] dec_exp_thr = {1'b0, sl} + {1'b0, dec_dec1};

    always @(*) begin
        env_next   = env_value;
        state_next = env_state;
        case (env_state)
            IDLE: begin
                env_next = 16'd0;
                if (gate) state_next = ATTACK;
            end

            ATTACK: begin
                if (adsr_curve == 2'd1) begin
                    if (att_exp_sum >= {1'b0, MAX_ENV}) begin
                        env_next = MAX_ENV; state_next = DECAY;
                    end else
                        env_next = env_value + att_inc1;
                end else begin
                    if (att_lin_sum >= {1'b0, MAX_ENV}) begin
                        env_next = MAX_ENV; state_next = DECAY;
                    end else
                        env_next = env_value + attack_step;
                end
            end

            DECAY: begin
                if (adsr_curve == 2'd1) begin
                    if ({1'b0, env_value} <= dec_exp_thr) begin
                        env_next = sl; state_next = SUSTAIN;
                    end else
                        env_next = env_value - dec_dec1;
                end else begin
                    if ({1'b0, env_value} <= dec_lin_thr) begin
                        env_next = sl; state_next = SUSTAIN;
                    end else
                        env_next = env_value - decay_step;
                end
            end

            SUSTAIN: begin
                env_next = sl;
                if (!gate) begin
                    if (sustain_pedal) state_next = PENDING_RELEASE;
                    else               state_next = RELEASE;
                end
            end

            PENDING_RELEASE: begin
                env_next = sl;
                if (gate)                state_next = SUSTAIN;
                else if (!sustain_pedal) state_next = RELEASE;
            end

            RELEASE: begin
                if (adsr_curve == 2'd1) begin
                    if ({1'b0, env_value} <= {1'b0, rel_dec1}) begin
                        env_next = 16'd0; state_next = IDLE;
                    end else
                        env_next = env_value - rel_dec1;
                end else begin
                    if ({1'b0, env_value} <= {1'b0, release_step}) begin
                        env_next = 16'd0; state_next = IDLE;
                    end else
                        env_next = env_value - release_step;
                end
            end

            default: begin
                env_next = 16'd0; state_next = IDLE;
            end
        endcase
    end

    //---------------- VCA ----------------
    // 控制率先合并两个慢变系数：g_vt = (velocity_gain × vca_gain) >>> 15
    //  ⚠ 2026-10-12：两个操作数**显式扩展到 32 位**再相乘。
    //     实测（iverilog）当前写法结果与显式扩展一致（赋值上下文会把表达式拉到 32 位），
    //     但依赖工具推断。本项目在 fx_reverb 上踩过"操作数没扩展 → 乘积被截断"的坑，
    //     故统一改成显式扩展，语义不依赖上下文。
    wire [31:0] g_vt = (({16'd0, velocity_gain}) * ({16'd0, vca_gain})) >>> 15;

    // 采样率路径：p48 = audio_in × env_value（40 位，符号扩展进 48 位）
    wire signed [39:0] p40    = audio_in * $signed({1'b0, env_value});
    wire signed [47:0] p48    = {{8{p40[39]}}, p40};

    // voice_out = sat24( (p48 × g_vt) >>> 30 )
    wire signed [63:0] p48_ext = {{16{p48[47]}}, p48};
    wire signed [63:0] g_ext   = {{32{1'b0}}, g_vt};
    wire signed [63:0] prod    = p48_ext * g_ext;
    wire signed [63:0] norm    = prod >>> 30;

    wire signed [23:0] vca_sat;
    sat24 #(.ACCW(64), .OUTW(24), .SHIFT(0)) u_vca_sat (
        .acc (norm),
        .y   (vca_sat)
    );

    //---------------- 时序 ----------------
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            env_value <= 16'd0;
            env_state <= IDLE;
            audio_out <= 24'sd0;
        end else if (sample_en) begin
            env_value <= env_next;
            env_state <= state_next;
            audio_out <= vca_sat;
        end
    end

endmodule

`default_nettype wire
