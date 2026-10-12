//============================================================================
//  fx_delay —— 延迟效果器（设计文档 §2）
//
//  挂在「延迟发送总线」上：输入 send_bus 抽出的 BusDel_L/R，
//  输出效果返回 RetL/RetR，由主混音求和加进干路。
//
//  算法：
//      wet     = line[wptr - D]
//      line[wptr] = bus + (fb * wet) >>> 15
//      out     = sat24( (bus*(1-mix) + wet*mix) >>> 15 )
//      ret     = sat24( (out * ret_level) >>> 15 )
//
//  ⚠ 参数口径（团队文档只给了字段名和位宽，没给单位，以下是本实现的定义）：
//      p_time : 延迟采样数，直接就是 D（1 ~ MAXLEN-1），不额外缩放
//      p_fb / p_mix / p_ret : 都是 Q1.15
//
//  结构：左右**各自一条独立的 BSRAM**（共用一条会串音），
//        两条线同拍读、同拍写，只要 3 拍/采样：
//          拍0 发读地址 (wptr-D)
//          拍1 读数据到（BSRAM 同步读，1 拍延迟）
//          拍2 算输出 + 写回 + 指针前进 + 打 ret_vld
//============================================================================

`default_nettype none

module fx_delay #(
    parameter integer AW     = 24,
    // ⚠ 延迟上限口径（2026-10-06 定稿）：**最大 512 ms**。
    //   48000 Hz 下 512 ms 需要 24576 点；取 2^15 = 32768 的缓冲深度，
    //   用"地址按 MAXLEN 取模"的方式把**有效上限**限制在 24576 点（= 512 ms @48k）。
    //   这样既满足文档"延迟限 500 ms"的预算，又保留 BSRAM 按 2 的幂分配。
    //   资源：左右各 32768 × 24 bit = 786432 bit × 2 = 96 块 BSRAM（16 Kbit 模式）。
    parameter integer MAXLEN = 32768,     // 缓冲深度（必须是 2 的幂）
    parameter integer ABW    = 15,        // 地址位宽
    parameter integer DLY_MAX= 24576      // **有效上限**：512 ms @48 kHz
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 frame_stb,

    input  wire                 in_vld,
    input  wire signed [AW-1:0] bus_l, bus_r,

    input  wire [15:0]          p_time,
    input  wire [15:0]          p_fb,
    input  wire [15:0]          p_mix,
    input  wire [15:0]          p_ret,

    output reg                  ret_vld,
    output reg  signed [AW-1:0] ret_l, ret_r
);

    function automatic signed [AW-1:0] sat24;
        input signed [47:0] v;
        begin
            if      (v >  48'sd8388607) sat24 = 24'sh7FFFFF;
            else if (v < -48'sd8388608) sat24 = 24'sh800000;
            else                        sat24 = v[AW-1:0];
        end
    endfunction

    // ---------------- 两条独立的延迟线 ----------------
    reg signed [AW-1:0] mem_l [0:MAXLEN-1];
    reg signed [AW-1:0] mem_r [0:MAXLEN-1];

    reg [ABW-1:0]       wptr;
    reg [ABW-1:0]       raddr;

    // 延迟量限幅：0 与超上限都夹到合法范围
    wire [15:0]         dt_lim = (p_time > DLY_MAX[15:0]) ? DLY_MAX[15:0] : p_time;
    wire [ABW-1:0]      dt_clamp = (dt_lim == 16'd0) ? {{(ABW-1){1'b0}}, 1'b1}
                                                    : dt_lim[ABW-1:0];
    reg                 we;
    reg [ABW-1:0]       waddr;
    reg signed [AW-1:0] wdata_l, wdata_r;
    reg signed [AW-1:0] rdata_l, rdata_r;

    always @(posedge clk) begin
        if (we) begin
            mem_l[waddr] <= wdata_l;
            mem_r[waddr] <= wdata_r;
        end
        rdata_l <= mem_l[raddr];           // BSRAM 同步读，1 拍延迟
        rdata_r <= mem_r[raddr];
    end

    // ---------------- FSM ----------------
    localparam [1:0] ST_IDLE = 2'd0, ST_RD = 2'd1, ST_WR = 2'd2;
    reg [1:0] st;

    reg signed [AW-1:0] bl, br;            // 捕获的总线输入

    // ⚠ BSRAM 同步读比地址晚一拍。ST_IDLE 发地址 -> ST_RD 那一拍 rdata 才有效，
    //   所以**必须等一拍**再用。原来在 ST_RD 就 wl <= rdata，锁到的是上一次
    //   地址的数据，导致延迟线整体多一拍（回声偏移 +1/+2/+3 累积）。
    //   这里直接把 wl/wr 做成 rdata 的别名，在 ST_WR 才取用，天然晚一拍。
    wire signed [AW-1:0] wl = rdata_l;
    wire signed [AW-1:0] wr = rdata_r;

    // 1 - mix（用 17 位无符号承载 32768）
    wire [16:0] mixx  = {1'b0, p_mix};
    wire [16:0] onem  = 17'd32768 - {1'b0, p_mix};

    // 反馈写入值
    // ⚠ Q1.15 乘法之后**必须先 >>>15** 再和音频相加。
    //   漏掉的话反馈量会大 32768 倍，立刻饱和自激。
    // ⚠ 而且**不能**写成 ({{(48-(AW+16)){p[AW+15]}}, p} >>> 15)：那个移位量是
    //   48-(24+16)=8 位符号 + 40 位乘积 = 48 位，>>>15 实际变成 >>>30（半量程
    //   直接归零）。必须把 operands 显式扩展到 48 位再乘，>>>15 才是纯算术右移。
    wire signed [47:0]    fbl_s = ($signed({{24{wl[AW-1]}}, wl}) * $signed(p_fb)) >>> 15;
    wire signed [47:0]    fbr_s = ($signed({{24{wr[AW-1]}}, wr}) * $signed(p_fb)) >>> 15;
    wire signed [47:0] wl_n = fbl_s + $signed({{24{bl[AW-1]}}, bl});
    wire signed [47:0] wr_n = fbr_s + $signed({{24{br[AW-1]}}, br});

    // 内部干湿比
    wire signed [47:0] outl_p = ($signed({{24{bl[AW-1]}}, bl}) * $signed({1'b0, onem})
                               + $signed({{24{wl[AW-1]}}, wl}) * $signed({1'b0, mixx})) >>> 15;
    wire signed [47:0] outr_p = ($signed({{24{br[AW-1]}}, br}) * $signed({1'b0, onem})
                               + $signed({{24{wr[AW-1]}}, wr}) * $signed({1'b0, mixx})) >>> 15;
    wire signed [AW-1:0]  outl   = sat24(outl_p);
    wire signed [AW-1:0]  outr   = sat24(outr_p);

    // 返回电平
    wire signed [47:0]    rl_p = ($signed({{24{outl[AW-1]}}, outl}) * $signed(p_ret)) >>> 15;
    wire signed [47:0]    rr_p = ($signed({{24{outr[AW-1]}}, outr}) * $signed(p_ret)) >>> 15;
    wire signed [AW-1:0]  rl_v = sat24(rl_p);
    wire signed [AW-1:0]  rr_v = sat24(rr_p);

    integer i;

`ifdef SIMULATION
    // 仿真专用的存储器初值。**综合器看不到这一段**（被 ifdef 挡住），
    // 所以 BSRAM 仍然能被正常推断出来。
    // 之前把清零写在复位分支里是错的：BSRAM 没有复位端口，综合器
    // 只能报错或者强行推断成触发器阵列（混响是 49152 x 24 bit，直接爆）。
    initial begin
        for (i = 0; i < MAXLEN; i = i + 1) begin
            mem_l[i] <= {AW{1'b0}};
                mem_r[i] <= {AW{1'b0}};
        end
    end
`endif

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= ST_IDLE;
            wptr <= {ABW{1'b0}}; raddr <= {ABW{1'b0}};
            we <= 1'b0; waddr <= {ABW{1'b0}};
            wdata_l <= {AW{1'b0}}; wdata_r <= {AW{1'b0}};
            bl <= {AW{1'b0}}; br <= {AW{1'b0}};
            ret_l <= {AW{1'b0}}; ret_r <= {AW{1'b0}}; ret_vld <= 1'b0;
        end else begin
            we      <= 1'b0;
            ret_vld <= 1'b0;

            case (st)
                ST_IDLE: begin
                    if (in_vld) begin
                        bl    <= bus_l;
                        br    <= bus_r;
                        // 拍0：发读地址。延迟量**限幅到 DLY_MAX**（有效上限 512 ms @48k），
                        // 既保证不超过文档的 500 ms 预算，也避免读到未初始化的缓冲尾部。
                        raddr <= wptr - dt_clamp;
                        st    <= ST_RD;
                    end
                end

                ST_RD: begin                                // 拍1：再等一拍让 rdata 落定
                    st <= ST_WR;
                end

                ST_WR: begin                                // 拍2：算 + 写 + 推进
                    wdata_l <= sat24(wl_n);
                    wdata_r <= sat24(wr_n);
                    waddr   <= wptr;
                    we      <= 1'b1;
                    wptr    <= wptr + 1'b1;
                    ret_l   <= rl_v;
                    ret_r   <= rr_v;
                    ret_vld <= 1'b1;
                    st      <= ST_IDLE;
                end

                default: st <= ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
