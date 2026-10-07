//============================================================================
//  voice_fetch —— 声部取数器（调度层 · 周期类）
//
//  依据：documents/硬件实现.md §三.八 / §三.九
//
//  职责：
//    1) 声部状态表存储：225 bit × N（§三.九 的逐项相加）
//         phase_acc(32)+phase_inc(32)+env_value(16)+env_state(3)+filter_ic1(32)
//         +filter_ic2(32)+lfo_phase(24)+note(7)+velocity(7)+gate(1)+timbre_slot(3)
//         +velocity_gain(16)+channel(4)+vca_gain(16) = 225
//       另加一张独立的 age[N]（8 bit）：§三.六.3 把 age 列为分配类字段，
//       但 §三.九 的 225 bit 逐项相加里没有它（文档缺口，已在报告里提出）。
//    2) 预取：时隙 g 期间读第 g+1 时隙的参数字段 → P 组预取寄存器，
//       保证单声部层在下一个时隙边界采样时已稳定（§三.八.3，不需要握手）。
//    3) 写回：单声部层每算完一个声部就发 rs_wr/rs_id/rs_data，
//       本模块先存进写回缓冲，**在 frame_stb 帧边界统一落盘**（§三.八.2）。
//    4) 分配写入口：voice_alloc 的 awr_* 先进分配写队列，
//       同样在 frame_stb 才真正写表 —— 满足"分配器写入后等一个采样边界
//       才对该声部生效"（§三.九 的读写冲突表）。
//    5) 扫描口：scan_req/scan_addr → 打一拍返回 scan_env_state（给 voice_alloc）。
//
//  ⚠ 与文档的差异（已在报告说明，非静默偏离）：
//    · 运行状态回写用**单写口 + rs_id**，不是 P 路并行回写。寄存器数组做 P 个
//      变量索引写会生成 P 份译码器，面积代价大；而单声部层本来就知道自己在算
//      哪个 voice_id，串行回写不损失功能，也不违反"帧边界统一提交"。
//    · §三.八.1 把 f_coeff/q_coeff/filter_type/attack_step/… 也算进"预取 169 bit"，
//      但这些来自**音色参数表**（单声部层资源），不是声部表字段。本模块只预取
//      声部表能提供的量，音色参数由单声部层按 timbre_slot 自己查表。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module voice_fetch #(
    parameter P   = 8,
    parameter G   = 4,
    parameter N   = 32,
    parameter NCH = 16
)(
    input  wire        clk,
    input  wire        rst_n_sync,
    input  wire        frame_stb,

    // ——— 时隙接口（来自 voice_slot_seq）———
    input  wire [1:0]  slot,
    input  wire        slot_vld,

    // ——— 分配写请求（来自 voice_alloc，帧边界才生效）———
    input  wire        awr,
    input  wire [4:0]  awr_id,
    input  wire [6:0]  awr_note,
    input  wire [6:0]  awr_vel,
    input  wire [3:0]  awr_ch,
    input  wire [2:0]  awr_timbre,
    input  wire        awr_gate,
    input  wire [15:0] awr_vel_gain,
    input  wire [7:0]  awr_age,
    input  wire        awr_fast_rel,
    output wire        awr_ready,        // 队列未满

    // ——— 运行状态回写（来自单声部层，单写口）———
    input  wire        rs_wr,
    input  wire [4:0]  rs_id,
    input  wire [138:0] rs_data,         // 见下方位段定义

    // ——— 扫描口（给 voice_alloc）———
    input  wire [4:0]  scan_addr,
    input  wire        scan_req,
    output reg  [2:0]  scan_env_state,

    // ——— 通道表的 sustain_pedal（来自 chan_param_shadow；它已经在扫全部通道）———
    //     voice_mono 需要它：延音踏板保持由 ADSR 自己判定（§三.六.3）
    input  wire [NCH-1:0] ch_sust_pedal,

    // ——— 预取输出（给单声部层；P 组）———
    output reg  [P*32-1:0] pf_phase_inc,
    output reg  [P*3-1:0]  pf_timbre,
    output reg  [P*7-1:0]  pf_note,
    output reg  [P*16-1:0] pf_vel_gain,
    output reg  [P*16-1:0] pf_vca_gain,
    output reg  [P*4-1:0]  pf_ch,
    output reg  [P-1:0]    pf_gate,
    output reg  [P-1:0]    pf_fast_rel,
    output reg  [P-1:0]    pf_sust_pedal,  // 按声部的 channel 从通道表带出
    output reg             pf_vld
);
    //========================================================================
    // 声部状态表位段（225 bit）
    //========================================================================
    localparam [8:0] V_PHACC   = 9'd31,  V_PHACC_L   = 9'd0;
    localparam [8:0] V_PHINC   = 9'd63,  V_PHINC_L   = 9'd32;
    localparam [8:0] V_ENVVAL  = 9'd79,  V_ENVVAL_L  = 9'd64;
    localparam [8:0] V_ENVST   = 9'd82,  V_ENVST_L   = 9'd80;
    localparam [8:0] V_IC1     = 9'd114, V_IC1_L     = 9'd83;
    localparam [8:0] V_IC2     = 9'd146, V_IC2_L     = 9'd115;
    localparam [8:0] V_LFO     = 9'd170, V_LFO_L     = 9'd147;
    localparam [8:0] V_NOTE    = 9'd177, V_NOTE_L    = 9'd171;
    localparam [8:0] V_VEL     = 9'd184, V_VEL_L     = 9'd178;
    localparam [8:0] V_GATE    = 9'd185;
    localparam [8:0] V_TIMBRE  = 9'd188, V_TIMBRE_L  = 9'd186;
    localparam [8:0] V_VELGAIN = 9'd204, V_VELGAIN_L = 9'd189;
    localparam [8:0] V_CH      = 9'd208, V_CH_L      = 9'd205;
    localparam [8:0] V_VCAGAIN = 9'd224, V_VCAGAIN_L = 9'd209;

    // 运行状态回写缓冲的位段（139 bit）
    localparam [8:0] R_PHACC = 9'd31,  R_PHACC_L = 9'd0;
    localparam [8:0] R_ENVVAL= 9'd47,  R_ENVVAL_L= 9'd32;
    localparam [8:0] R_ENVST = 9'd50,  R_ENVST_L = 9'd48;
    localparam [8:0] R_IC1   = 9'd82,  R_IC1_L   = 9'd51;
    localparam [8:0] R_IC2   = 9'd114, R_IC2_L   = 9'd83;
    localparam [8:0] R_LFO   = 9'd138, R_LFO_L   = 9'd115;

    localparam [1:0] S_IDLE = 2'd0, S_WB = 2'd1, S_AW = 2'd2;

    //========================================================================
    // 存储
    //========================================================================
    reg [224:0] vtab  [0:N-1];           // 声部状态表
    reg [7:0]   v_age [0:N-1];           // age（文档 225 bit 里缺失，单独存）
    reg         v_fast[0:N-1];           // 快速释放标志（抢断/直断），同样不在 225 bit 里

    reg [138:0] wb_buf [0:N-1];          // 写回缓冲（139 bit × N）
    reg         wb_pend[0:N-1];

    // 分配写队列（深 32：够 CC123 一次关掉全部声部）
    //   条目 = {id, note, vel, ch, timbre, gate, vel_gain, age, fast} = 52 bit
    reg [51:0]  aw_q [0:N-1];
    reg [5:0]   aw_cnt;
    wire        aw_full = (aw_cnt >= N[5:0]);
    assign      awr_ready = ~aw_full;

    //========================================================================
    // 提交 FSM
    //========================================================================
    reg [1:0]  st;
    reg [4:0]  idx;

    integer k;
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            st      <= S_IDLE;
            idx     <= 5'd0;
            aw_cnt  <= 6'd0;
            for (k = 0; k < N; k = k + 1) begin
                vtab[k]   <= 225'd0;
                v_age[k]  <= 8'd0;
                v_fast[k] <= 1'b0;
                wb_buf[k] <= 139'd0;
                wb_pend[k]<= 1'b0;
                aw_q[k]   <= 52'd0;
            end
            scan_env_state <= 3'd0;
            pf_vld       <= 1'b0;
            pf_phase_inc <= {(P*32){1'b0}};
            pf_timbre    <= {(P*3){1'b0}};
            pf_note      <= {(P*7){1'b0}};
            pf_vel_gain  <= {(P*16){1'b0}};
            pf_vca_gain  <= {(P*16){1'b0}};
            pf_ch        <= {(P*4){1'b0}};
            pf_gate      <= {P{1'b0}};
            pf_fast_rel  <= {P{1'b0}};
            pf_sust_pedal<= {P{1'b0}};
        end else begin
            pf_vld <= 1'b0;

            //--------------------------------------------------------------
            // 1) 单声部层回写 → 写回缓冲（单写口，变量索引写）
            //--------------------------------------------------------------
            if (rs_wr) begin
                wb_buf[rs_id]  <= rs_data;
                wb_pend[rs_id] <= 1'b1;
            end

            //--------------------------------------------------------------
            // 2) 分配写请求 → 队列
            //--------------------------------------------------------------
            if (awr && !aw_full) begin
                aw_q[aw_cnt[4:0]] <= {awr_id, awr_note, awr_vel, awr_ch,
                                      awr_timbre, awr_gate, awr_vel_gain,
                                      awr_age, awr_fast_rel};
                aw_cnt <= aw_cnt + 6'd1;
            end

            //--------------------------------------------------------------
            // 3) 扫描口：打一拍返回 env_state
            //--------------------------------------------------------------
            if (scan_req) scan_env_state <= vtab[scan_addr][V_ENVST:V_ENVST_L];

            //--------------------------------------------------------------
            // 4) 预取：时隙 g 期间读时隙 g+1 的参数字段（P 路并行）
            //--------------------------------------------------------------
            if (slot_vld) begin
                // 下一时隙号（G-1 之后回到 0，相当于预取下一帧的首时隙）
                // 这里用组合在 generate 里算，见下方 g_pf
                pf_vld <= 1'b1;
            end

            //--------------------------------------------------------------
            // 5) 提交 FSM：frame_stb 起，先把写回落盘，再把分配写落盘
            //--------------------------------------------------------------
            case (st)
                S_IDLE: begin
                    if (frame_stb) begin
                        idx <= 5'd0;
                        st  <= S_WB;
                    end
                end
                S_WB: begin
                    if (wb_pend[idx]) begin
                        // 只覆盖运行状态组（分配类字段由 S_AW 负责）
                        vtab[idx][V_PHACC :V_PHACC_L ] <= wb_buf[idx][R_PHACC :R_PHACC_L ];
                        vtab[idx][V_ENVVAL:V_ENVVAL_L] <= wb_buf[idx][R_ENVVAL:R_ENVVAL_L];
                        vtab[idx][V_ENVST :V_ENVST_L ] <= wb_buf[idx][R_ENVST :R_ENVST_L ];
                        vtab[idx][V_IC1   :V_IC1_L   ] <= wb_buf[idx][R_IC1   :R_IC1_L   ];
                        vtab[idx][V_IC2   :V_IC2_L   ] <= wb_buf[idx][R_IC2   :R_IC2_L   ];
                        vtab[idx][V_LFO   :V_LFO_L   ] <= wb_buf[idx][R_LFO   :R_LFO_L   ];
                        wb_pend[idx] <= 1'b0;
                    end
                    if (idx == (N-1)) begin
                        idx <= 5'd0;
                        st  <= S_AW;
                    end else idx <= idx + 5'd1;
                end
                S_AW: begin
                    if (idx < aw_cnt) begin
                        vtab[idx2id(idx)] <= apply_alloc(vtab[idx2id(idx)], aw_q[idx]);
                        v_age[idx2id(idx)] <= aw_q[idx][8:1];
                        v_fast[idx2id(idx)] <= aw_q[idx][0];
                    end
                    if (idx == (N-1)) begin
                        aw_cnt <= 6'd0;
                        st     <= S_IDLE;
                    end else idx <= idx + 5'd1;
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    // aw_q 里存的 id 就是目标声部；提交时按队列顺序写（不是按 idx）
    function [4:0] idx2id;
        input [4:0] i;
        begin
            idx2id = aw_q[i][51:47];
        end
    endfunction

    // 把一条分配写应用到 225 bit 项上（只动分配类字段）
    function [224:0] apply_alloc;
        input [224:0] old;
        input [51:0]  e;
        reg   [224:0] t;
        begin
            t = old;
            t[V_NOTE   :V_NOTE_L   ] = e[46:40];
            t[V_VEL    :V_VEL_L    ] = e[39:33];
            t[V_CH     :V_CH_L     ] = e[32:29];
            t[V_TIMBRE :V_TIMBRE_L ] = e[28:26];
            t[V_GATE]                = e[25];
            t[V_VELGAIN:V_VELGAIN_L] = e[24:9];
            t[V_VCAGAIN:V_VCAGAIN_L] = e[24:9];   // 本期 vca_gain 跟随 velocity_gain
            apply_alloc = t;
        end
    endfunction

    // 按声部的 channel 从 16 位通道向量里选 sustain_pedal（16 选 1，用 case 展开）
    function sust_sel;
        input [3:0]     ch;
        input [NCH-1:0] v;
        begin
            case (ch)
                4'd0:    sust_sel = v[0];
                4'd1:    sust_sel = v[1];
                4'd2:    sust_sel = v[2];
                4'd3:    sust_sel = v[3];
                4'd4:    sust_sel = v[4];
                4'd5:    sust_sel = v[5];
                4'd6:    sust_sel = v[6];
                4'd7:    sust_sel = v[7];
                4'd8:    sust_sel = v[8];
                4'd9:    sust_sel = v[9];
                4'd10:   sust_sel = v[10];
                4'd11:   sust_sel = v[11];
                4'd12:   sust_sel = v[12];
                4'd13:   sust_sel = v[13];
                4'd14:   sust_sel = v[14];
                default: sust_sel = v[15];
            endcase
        end
    endfunction

    //========================================================================
    // 预取（P 路并行读 vtab）
    //========================================================================
    genvar gl;
    generate
        for (gl = 0; gl < P; gl = gl + 1) begin : g_pf
            // 下一时隙号
            wire [1:0] nslot = (slot == 2'd3) ? 2'd0 : (slot + 2'd1);
            wire [4:0] vid   = {nslot, gl[2:0]};
            wire [224:0] it  = vtab[vid];
            always @(posedge clk or negedge rst_n_sync) begin
                if (!rst_n_sync) begin
                    pf_phase_inc[gl*32 +: 32] <= 32'd0;
                    pf_timbre   [gl*3  +: 3 ] <= 3'd0;
                    pf_note     [gl*7  +: 7 ] <= 7'd0;
                    pf_vel_gain [gl*16 +: 16] <= 16'd0;
                    pf_vca_gain [gl*16 +: 16] <= 16'd0;
                    pf_ch       [gl*4  +: 4 ] <= 4'd0;
                    pf_gate     [gl]          <= 1'b0;
                    pf_fast_rel [gl]          <= 1'b0;
                end else if (slot_vld) begin
                    pf_phase_inc[gl*32 +: 32] <= it[V_PHINC   :V_PHINC_L   ];
                    pf_timbre   [gl*3  +: 3 ] <= it[V_TIMBRE  :V_TIMBRE_L  ];
                    pf_note     [gl*7  +: 7 ] <= it[V_NOTE    :V_NOTE_L    ];
                    pf_vel_gain [gl*16 +: 16] <= it[V_VELGAIN :V_VELGAIN_L ];
                    pf_vca_gain [gl*16 +: 16] <= it[V_VCAGAIN :V_VCAGAIN_L ];
                    pf_ch       [gl*4  +: 4 ] <= it[V_CH      :V_CH_L      ];
                    pf_gate     [gl]          <= it[V_GATE];
                    pf_fast_rel [gl]          <= v_fast[vid];
                    pf_sust_pedal[gl]         <= sust_sel(it[V_CH:V_CH_L], ch_sust_pedal);
                end
            end
        end
    endgenerate

endmodule
`default_nettype wire
