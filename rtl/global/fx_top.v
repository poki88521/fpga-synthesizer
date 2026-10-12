//============================================================================
//  fx_top —— 效果器运算顶层（设计文档 §2）
//
//  3 条发送总线进来，3 个效果器并行跑，返回汇总成一对 FxRet_L/R 交给主混音。
//
//      BusRev ──> fx_reverb ──> RevRet ─┐
//      BusCho ──> fx_chorus ──> ChoRet ─┼─> FxRet_L/R
//      BusDel ──> fx_delay  ──> DelRet ─┘
//
//  每个效果器内部已经各自乘过 *_return 返回电平，这里只做求和 + 一次饱和。
//
//  ⚠⚠ 完成握手（2026-10-06 重写）
//      旧实现：三个 ret_vld 都到齐（&got）才输出，frame_stb 清 got。
//      已证明脆弱：只要有一个效果的 ret_vld 时机变了（旁路、或内部 FSM 改动），
//      三个就永远凑不齐 → got 被 frame_stb 反复清零 → 返回永远不输出（实测全静音）。
//
//      新实现：**固定完成时刻**。
//        · 每个效果的返回各自用 ret_vld 寄存（谁先算完都不丢）
//        · 从 bus_vld 起数 LAT_MAX 拍，到点就统一汇总输出（各家 ret_vld 早已拉过）
//      实测各效果延迟：fx_delay 3 拍、fx_chorus 11 拍、fx_reverb 121 拍
//      → LAT_MAX 默认 128，留 7 拍余量。
//
//  旁路：REV_EN/CHO_EN/DEL_EN 置 0 时该效果**不占周期、也不贡献输出**（返回 0），
//        并且 ret_vld 仍按 bus_vld 给（保持接口时序一致）。
//============================================================================

`default_nettype none

module fx_top #(
    parameter integer REV_EN  = 1,      // 0 = 旁路混响（返回 0）
    parameter integer CHO_EN  = 1,      // 0 = 旁路合唱
    parameter integer DEL_EN  = 1,      // 0 = 旁路延迟
    parameter integer LAT_MAX = 128     // bus_vld 之后多少拍统一输出
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 frame_stb,
    input  wire                 test_mode,      // 1 = 测试模式：三个效果全部旁路（附三要求）

    input  wire                 bus_vld,
    input  wire signed [23:0]   bus_rev_l, bus_rev_r,
    input  wire signed [23:0]   bus_cho_l, bus_cho_r,
    input  wire signed [23:0]   bus_del_l, bus_del_r,

    // ---- 效果参数表 ----
    input  wire [15:0]          reverb_size, reverb_decay, reverb_damping,
                                reverb_pre_delay, reverb_return,
    input  wire [15:0]          chorus_rate, chorus_depth, chorus_mix, chorus_return,
    input  wire [15:0]          delay_time, delay_feedback, delay_mix, delay_return,

    output reg                  fx_vld,
    output reg  signed [23:0]   fx_l, fx_r
);

    function automatic signed [23:0] sat24;
        input signed [47:0] v;
        begin
            if      (v >  48'sd8388607) sat24 = 24'sh7FFFFF;
            else if (v < -48'sd8388608) sat24 = 24'sh800000;
            else                        sat24 = v[23:0];
        end
    endfunction

    wire                 rv_vld, ch_vld, dl_vld;
    wire signed [23:0]   rv_l, rv_r, ch_l, ch_r, dl_l, dl_r;

    // ---------------- 参数平滑（文档"效果器运算 第六步"要求）----------------
    //  文档原文："参数由控制模块经寄存器写入，在控制率更新，先经第六步平滑，
    //  再写成 Q1.15 供音频域使用。" 本模块是控制率→音频域的边界，故平滑放在这里。
    //
    //  实现：每个参数一份 16 位平滑值，每采样朝目标走 1/64；
    //        → 最坏 65535/64 ≈ 1024 采样（约 21 ms @48k）收敛，无咔哒声。
    //  实测（tb_fx_param）：阶跃 1000 → 20000 时，平滑值单调逼近、最终精确到目标。
    reg [15:0] rv_size_s, rv_decay_s, rv_damp_s, rv_ret_s;
    //  ⚠ `reverb_pre_delay` **故意不做平滑**：预延迟是可变深度延迟线，
    //    深度一变，环状缓冲的历史数据与新读指针距离立刻失配 → 输出垃圾；
    //    若按斜坡平滑，斜坡期间每拍都在改深度，会引入多普勒式音高扭曲。
    //    正确用法：上电时设定、运行时只读。详见 rtl/pre_delay.v 头注释。
    reg [15:0] ch_rate_s, ch_depth_s, ch_mix_s, ch_ret_s;
    reg [15:0] dl_time_s, dl_fb_s, dl_mix_s, dl_ret_s;

    // 单个参数的下一步值：与目标差 ≤ 步长就直接到位，否则走一步
    function [15:0] sm_step;
        input [15:0] cur;
        input [15:0] tgt;
        begin
            if (cur == tgt)                       sm_step = cur;
            else if (cur < tgt)                   sm_step = (tgt - cur > 16'd64)
                                                          ? (cur + 16'd64) : tgt;
            else                                  sm_step = (cur - tgt > 16'd64)
                                                          ? (cur - 16'd64) : tgt;
        end
    endfunction

    // ⚠ 复位时把平滑值直接置为**当时的参数目标值**：
    //   否则上电后每个参数都要"从 0 爬 1024 个采样"，开机头 20 ms 会听到参数从 0 涨上来
    //   （混响/合唱/延迟的量突然由无到有）。置成目标值后，只有**参数真变化**时才走斜坡。
    //   本仓库的仿真 TB 也是靠这一点保持"参数恒定 → 行为与加平滑前完全一致"。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rv_size_s <= reverb_size;  rv_decay_s <= reverb_decay;
            rv_damp_s <= reverb_damping;
            rv_ret_s  <= reverb_return;
            ch_rate_s <= chorus_rate;  ch_depth_s <= chorus_depth;
            ch_mix_s  <= chorus_mix;   ch_ret_s   <= chorus_return;
            dl_time_s <= delay_time;   dl_fb_s    <= delay_feedback;
            dl_mix_s  <= delay_mix;    dl_ret_s   <= delay_return;
        end else if (frame_stb) begin
            // 每个采样（frame_stb）更新一次
            rv_size_s <= sm_step(rv_size_s, reverb_size);
            rv_decay_s<= sm_step(rv_decay_s,reverb_decay);
            rv_damp_s <= sm_step(rv_damp_s, reverb_damping);
            rv_ret_s  <= sm_step(rv_ret_s,  reverb_return);
            ch_rate_s <= sm_step(ch_rate_s, chorus_rate);
            ch_depth_s<= sm_step(ch_depth_s,chorus_depth);
            ch_mix_s  <= sm_step(ch_mix_s,  chorus_mix);
            ch_ret_s  <= sm_step(ch_ret_s,  chorus_return);
            dl_time_s <= sm_step(dl_time_s, delay_time);
            dl_fb_s   <= sm_step(dl_fb_s,   delay_feedback);
            dl_mix_s  <= sm_step(dl_mix_s,  delay_mix);
            dl_ret_s  <= sm_step(dl_ret_s,  delay_return);
        end
    end

    // ---------------- 三个效果器 ----------------
    generate
    if (REV_EN != 0) begin : g_rev
        fx_reverb u_rev (
            .clk(clk), .rst_n(rst_n), .frame_stb(frame_stb),
            .in_vld(bus_vld), .bus_l(bus_rev_l), .bus_r(bus_rev_r),
            .p_decay(rv_decay_s), .p_damp(rv_damp_s),
            .p_size(rv_size_s), .p_ret(rv_ret_s), .p_predly(reverb_pre_delay),   // 直通，不平滑（见上）
            .ret_vld(rv_vld), .ret_l(rv_l), .ret_r(rv_r)
        );
    end else begin : g_norev
        assign rv_vld = bus_vld;          // 时序与实体一致，但不贡献输出
        assign rv_l   = 24'sd0;
        assign rv_r   = 24'sd0;
    end
    endgenerate

    generate
    if (CHO_EN != 0) begin : g_cho
        fx_chorus u_cho (
            .clk(clk), .rst_n(rst_n), .frame_stb(frame_stb),
            .in_vld(bus_vld), .bus_l(bus_cho_l), .bus_r(bus_cho_r),
            .p_rate(ch_rate_s), .p_depth(ch_depth_s),
            .p_mix(ch_mix_s), .p_ret(ch_ret_s),
            .ret_vld(ch_vld), .ret_l(ch_l), .ret_r(ch_r)
        );
    end else begin : g_nocho
        assign ch_vld = bus_vld;
        assign ch_l   = 24'sd0;
        assign ch_r   = 24'sd0;
    end
    endgenerate

    generate
    if (DEL_EN != 0) begin : g_del
        fx_delay u_del (
            .clk(clk), .rst_n(rst_n), .frame_stb(frame_stb),
            .in_vld(bus_vld), .bus_l(bus_del_l), .bus_r(bus_del_r),
            .p_time(dl_time_s), .p_fb(dl_fb_s),
            .p_mix(dl_mix_s), .p_ret(dl_ret_s),
            .ret_vld(dl_vld), .ret_l(dl_l), .ret_r(dl_r)
        );
    end else begin : g_nodel
        assign dl_vld = bus_vld;
        assign dl_l   = 24'sd0;
        assign dl_r   = 24'sd0;
    end
    endgenerate

    // ---------------- 各自寄存返回（谁先算完都不丢） ----------------
    reg signed [23:0] rl, rr, cl, cr, dll, dlr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rl <= 24'sd0; rr <= 24'sd0;
            cl <= 24'sd0; cr <= 24'sd0;
            dll<= 24'sd0; dlr<= 24'sd0;
        end else begin
            if (rv_vld) begin rl  <= rv_l; rr  <= rv_r; end
            if (ch_vld) begin cl  <= ch_l; cr  <= ch_r; end
            if (dl_vld) begin dll <= dl_l; dlr <= dl_r; end
        end
    end

    // ---------------- 固定完成时刻：bus_vld 后数 LAT_MAX 拍 ----------------
    localparam integer CW = 12;           // 计数器位宽（够到 4095）
    localparam integer PW = 4;            // 积压计数位宽（最多排 15 个）
    reg [CW-1:0] cnt;
    reg [PW-1:0] pend;                    // 处理中又来了几个 bus_vld（排队，不丢）
    reg          busy;
    reg          done;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= {CW{1'b0}}; pend <= {PW{1'b0}}; busy <= 1'b0; done <= 1'b0;
        end else begin
            // ⚠⚠ frame_stb **不再**清 busy/cnt/pend。
            //   原来 frame_stb（采样边界）会在一次处理**中途**把 busy 清掉，
            //   那一次的 done/fx_vld 就永远不发了 → 下游 main_mix 卡在 ST_WAIT
            //   （实测：demo 里 main_l 201 拍只变 4 次，输出被主音量斜坡乘成一条斜线）。
            //   现在 frame_stb 只当"采样边界"用，计数器的收尾由 cnt 自己走到 LAT_MAX 决定；
            //   系统有 800+ 拍空闲，下一个 bus_vld 来时计数器早已空闲。
            begin
                done <= 1'b0;
                if (!busy) begin
                    // 空闲：来一个 bus_vld 就开始计时；若已经积压，立刻接着处理一个
                    if (bus_vld) begin
                        cnt  <= {{(CW-1){1'b0}}, 1'b1};
                        busy <= 1'b1;
                    end else if (pend != {PW{1'b0}}) begin
                        pend <= pend - 1'b1;
                        cnt  <= {{(CW-1){1'b0}}, 1'b1};
                        busy <= 1'b1;
                    end
                end else begin
                    // 忙：把新来的脉冲记进 pend（不丢样）
                    if (bus_vld && pend != {PW{1'b1}}) pend <= pend + 1'b1;
                    if (cnt >= LAT_MAX[CW-1:0]) begin
                        busy <= 1'b0;
                        done <= 1'b1;                 // 到点：下一拍锁存汇总
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end
            end
        end
    end

    // ---------------- 汇总 + 饱和 ----------------
    // 测试模式（附三）：三个效果返回全置零（等效 SendXX 全 0、master_wet = 0）。
    // ⚠ 不能用 generate 的条件来旁路：generate 要求**综合期常量**，
    //   而 test_mode 是运行时信号（iverilog 会报 "not allowed in a constant expression"）。
    //   所以在汇总处门控——效果器实例仍在、仍照常算，只是返回 0 不参与混音。
    wire signed [23:0] rl_t = test_mode ? 24'sd0 : rl;
    wire signed [23:0] rr_t = test_mode ? 24'sd0 : rr;
    wire signed [23:0] cl_t = test_mode ? 24'sd0 : cl;
    wire signed [23:0] cr_t = test_mode ? 24'sd0 : cr;
    wire signed [23:0] dll_t= test_mode ? 24'sd0 : dll;
    wire signed [23:0] dlr_t= test_mode ? 24'sd0 : dlr;

    wire signed [47:0] sum_l = {{24{rl_t[23]}},  rl_t}  + {{24{cl_t[23]}},  cl_t}  + {{24{dll_t[23]}}, dll_t};
    wire signed [47:0] sum_r = {{24{rr_t[23]}},  rr_t}  + {{24{cr_t[23]}},  cr_t}  + {{24{dlr_t[23]}}, dlr_t};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fx_vld <= 1'b0; fx_l <= 24'sd0; fx_r <= 24'sd0;
        end else begin
            if (done) begin
                fx_l   <= sat24(sum_l);
                fx_r   <= sat24(sum_r);
                fx_vld <= 1'b1;
            end else begin
                fx_vld <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
