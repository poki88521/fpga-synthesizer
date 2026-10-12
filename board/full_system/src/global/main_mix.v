//============================================================================
//  main_mix —— 主混音求和（设计文档 §3）
//
//  按《模块速查表》§五：「主混音求和：**16 条通道 + 效果返回** → 汇总为立体声主输出」。
//  也就是一个纯求和 —— 声像与通道音量已经在通道处理层施加完了。
//
//  数据流：
//      chan_layer 的串行通道流（16 拍）     → dry 累加（边收边加，不需要缓存）
//      效果器运算的 FxRet_L / FxRet_R       → fx_vld 有效时加上
//          |
//          v
//      MainL / MainR（24-bit Q1.23）
//
//  定点：**这里没有乘法，所以没有归一化左移**。
//      24-bit 通道值直接相加，48-bit 累加器装 16 路绰绰有余
//      （|Σ| <= 16 x 2^23 = 2^27）。最后与效果返回一起只饱和一次，
//      中间不做饱和，避免"先削一层再相加"造成的额外失真。
//
//  周期预算：16 拍累加 + 1 拍求和 = 17 拍 = 1.7%
//============================================================================

`default_nettype none

module main_mix #(
    parameter integer NCH = 16,
    parameter integer AW  = 24
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    frame_stb,

    // ---- 来自通道处理层的串行通道流 ----
    input  wire                    ch_vld,
    input  wire [3:0]              ch_addr,
    input  wire signed [AW-1:0]    ch_l,
    input  wire signed [AW-1:0]    ch_r,

    // ---- 来自效果器运算的效果返回 ----
    input  wire signed [AW-1:0]    fx_l,
    input  wire signed [AW-1:0]    fx_r,
    input  wire                    fx_vld,

    // ---- 主混音输出 ----
    output reg                     mix_vld,
    output reg signed [AW-1:0]     main_l,
    output reg signed [AW-1:0]     main_r
);

    localparam integer AWX = 48;

    function automatic signed [AW-1:0] sat24;
        input signed [AWX-1:0] v;
        begin
            if      (v >  48'sd8388607) sat24 = 24'sh7FFFFF;
            else if (v < -48'sd8388608) sat24 = 24'sh800000;
            else                        sat24 = v[AW-1:0];
        end
    endfunction

    reg signed [AWX-1:0] acc_l, acc_r;
    reg signed [AWX-1:0] dry_l, dry_r;
    reg [1:0] st;
    // ST_WAIT 超时兜底：等不到 fx_vld 也要继续出结果（默认等 1024 拍）
    localparam integer WCW = 11;
    localparam integer WAIT_MAX = 1024;
    reg [WCW-1:0] wcnt;
    localparam [1:0] ST_ACC = 2'd0, ST_WAIT = 2'd1;

    wire signed [AWX-1:0] chl_x = {{(AWX-AW){ch_l[AW-1]}}, ch_l};
    wire signed [AWX-1:0] chr_x = {{(AWX-AW){ch_r[AW-1]}}, ch_r};
    wire signed [AWX-1:0] acc_l_n = acc_l + chl_x;
    wire signed [AWX-1:0] acc_r_n = acc_r + chr_x;

    wire signed [AWX-1:0] dry_l_x = dry_l;
    wire signed [AWX-1:0] fxl_x   = {{(AWX-AW){fx_l[AW-1]}}, fx_l};
    wire signed [AWX-1:0] fxr_x   = {{(AWX-AW){fx_r[AW-1]}}, fx_r};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st      <= ST_ACC;
            acc_l   <= 48'sd0;
            acc_r   <= 48'sd0;
            dry_l   <= 48'sd0;
            dry_r   <= 48'sd0;
            wcnt    <= {WCW{1'b0}};
            mix_vld <= 1'b0;
            main_l  <= 24'sd0;
            main_r  <= 24'sd0;
        end else begin
            mix_vld <= 1'b0;

            case (st)
                // ---- 边收边加（16 拍）。ch_addr == 0 视为新一轮开始 ----
                ST_ACC: begin
                    if (ch_vld) begin
                        if (ch_addr == 4'd0) begin
                            acc_l <= chl_x;
                            acc_r <= chr_x;
                        end else begin
                            acc_l <= acc_l_n;
                            acc_r <= acc_r_n;
                        end
                        if (ch_addr == NCH-1) begin
                            dry_l <= acc_l_n;      // 含最后一条通道
                            dry_r <= acc_r_n;
                            wcnt  <= {WCW{1'b0}};  // 超时计数从 0 开始
                            st    <= ST_WAIT;
                        end
                    end
                end

                // ---- 等效果返回，加完饱和输出 ----
                // ⚠⚠ 必须有超时兜底：原来 fx_vld 只要丢一次（上游握手抖动、
                //   fx_top 的 frame_stb 打断计数…），这里就**永久卡住**，
                //   主混音输出被冻结成常数（实测 demo 里 main_l 201 拍只变 4 次）。
                //   超时后按"没有效果返回"输出干声，保证链路永不僵死。
                ST_WAIT: begin
                    if (fx_vld) begin
                        main_l  <= sat24(dry_l_x + fxl_x);
                        main_r  <= sat24(dry_r +  fxr_x);
                        mix_vld <= 1'b1;
                        st      <= ST_ACC;
                        acc_l   <= 48'sd0;
                        acc_r   <= 48'sd0;
                        wcnt    <= {WCW{1'b0}};
                    end else if (wcnt >= WAIT_MAX[WCW-1:0]) begin
                        // 超时：按干声输出，标记有效，继续下一轮
                        main_l  <= sat24(dry_l_x);
                        main_r  <= sat24(dry_r);
                        mix_vld <= 1'b1;
                        st      <= ST_ACC;
                        acc_l   <= 48'sd0;
                        acc_r   <= 48'sd0;
                        wcnt    <= {WCW{1'b0}};
                    end else begin
                        wcnt <= wcnt + 1'b1;
                    end
                end

                default: st <= ST_ACC;
            endcase
        end
    end

endmodule

`default_nettype wire
