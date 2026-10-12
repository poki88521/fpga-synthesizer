//============================================================================
//  fx_chorus —— 合唱效果器（设计文档 §2）
//
//  挂在「合唱发送总线」上：输入 BusCho_L/R，输出 RetL/RetR。
//
//  算法（纯调制延迟，不做反馈）：
//      LFO      : 32 位相位累加 + 64 点四分之一正弦表 + 象限映射
//      调制延迟 : dly = BASE_Q8 + (DEPTH_Q8 * lfo) >>> 15       （Q8.8）
//      线性插值 : wet = m0 + ((m1 - m0) * frac) >>> 8
//      输出     : out = sat24( (bus*(1-mix) + wet*mix) >>> 15 )
//                 ret = sat24( (out * ret_level) >>> 15 )
//
//  左右两声道用**反相** LFO（相位差 180 度），得到立体声展开。
//
//  ⚠ 参数口径（团队文档只给了字段名和位宽，没给单位，以下是本实现的定义）：
//      p_rate : 16-bit 频率控制字，相位增量 = p_rate << RATE_SHIFT
//               RATE_SHIFT = 6 时，0 ~ 65535 对应 0 ~ 46.9 Hz
//      p_depth: Q1.15 调制深度，满量程对应 ±DEPTH_SAMP 个采样
//      p_mix / p_ret : Q1.15
//
//  结构：左右串行处理，每声道 4 拍（读两个抽头 + 算 + 写），共 8 拍/采样。
//============================================================================

`default_nettype none

module fx_chorus #(
    parameter integer AW         = 24,
    parameter integer MAXLEN     = 2048,     // 2 的幂
    parameter integer ABW        = 11,
    parameter integer BASE_SAMP  = 960,      // 基础延迟 960 采样 = 20 ms @48k
    parameter integer DEPTH_SAMP = 240,      // 满量程深度 ±240 采样 = ±5 ms
    parameter integer RATE_SHIFT = 6
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 frame_stb,

    input  wire                 in_vld,
    input  wire signed [AW-1:0] bus_l, bus_r,

    input  wire [15:0]          p_rate,
    input  wire [15:0]          p_depth,
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

    // ---------------- 64 点四分之一正弦表 ----------------
    function automatic signed [15:0] sin_q;
        input [5:0] i;
        begin
            case (i)
            6'd0  : sin_q = 16'sd402;
            6'd1  : sin_q = 16'sd1206;
            6'd2  : sin_q = 16'sd2009;
            6'd3  : sin_q = 16'sd2811;
            6'd4  : sin_q = 16'sd3612;
            6'd5  : sin_q = 16'sd4410;
            6'd6  : sin_q = 16'sd5205;
            6'd7  : sin_q = 16'sd5998;
            6'd8  : sin_q = 16'sd6786;
            6'd9  : sin_q = 16'sd7571;
            6'd10 : sin_q = 16'sd8351;
            6'd11 : sin_q = 16'sd9126;
            6'd12 : sin_q = 16'sd9896;
            6'd13 : sin_q = 16'sd10659;
            6'd14 : sin_q = 16'sd11417;
            6'd15 : sin_q = 16'sd12167;
            6'd16 : sin_q = 16'sd12910;
            6'd17 : sin_q = 16'sd13645;
            6'd18 : sin_q = 16'sd14372;
            6'd19 : sin_q = 16'sd15090;
            6'd20 : sin_q = 16'sd15800;
            6'd21 : sin_q = 16'sd16499;
            6'd22 : sin_q = 16'sd17189;
            6'd23 : sin_q = 16'sd17869;
            6'd24 : sin_q = 16'sd18537;
            6'd25 : sin_q = 16'sd19195;
            6'd26 : sin_q = 16'sd19841;
            6'd27 : sin_q = 16'sd20475;
            6'd28 : sin_q = 16'sd21096;
            6'd29 : sin_q = 16'sd21705;
            6'd30 : sin_q = 16'sd22301;
            6'd31 : sin_q = 16'sd22884;
            6'd32 : sin_q = 16'sd23452;
            6'd33 : sin_q = 16'sd24007;
            6'd34 : sin_q = 16'sd24547;
            6'd35 : sin_q = 16'sd25072;
            6'd36 : sin_q = 16'sd25582;
            6'd37 : sin_q = 16'sd26077;
            6'd38 : sin_q = 16'sd26556;
            6'd39 : sin_q = 16'sd27019;
            6'd40 : sin_q = 16'sd27466;
            6'd41 : sin_q = 16'sd27896;
            6'd42 : sin_q = 16'sd28310;
            6'd43 : sin_q = 16'sd28706;
            6'd44 : sin_q = 16'sd29085;
            6'd45 : sin_q = 16'sd29447;
            6'd46 : sin_q = 16'sd29791;
            6'd47 : sin_q = 16'sd30117;
            6'd48 : sin_q = 16'sd30424;
            6'd49 : sin_q = 16'sd30714;
            6'd50 : sin_q = 16'sd30985;
            6'd51 : sin_q = 16'sd31237;
            6'd52 : sin_q = 16'sd31470;
            6'd53 : sin_q = 16'sd31685;
            6'd54 : sin_q = 16'sd31880;
            6'd55 : sin_q = 16'sd32057;
            6'd56 : sin_q = 16'sd32213;
            6'd57 : sin_q = 16'sd32351;
            6'd58 : sin_q = 16'sd32469;
            6'd59 : sin_q = 16'sd32567;
            6'd60 : sin_q = 16'sd32646;
            6'd61 : sin_q = 16'sd32705;
            6'd62 : sin_q = 16'sd32745;
            6'd63 : sin_q = 16'sd32765;
                default: sin_q = 16'sd0;
            endcase
        end
    endfunction

    function automatic signed [15:0] sine_of;
        input [31:0] ph;
        reg   [1:0]  q;
        reg   [5:0]  idx;
        begin
            q   = ph[31:30];
            idx = ph[29:24];
            case (q)
                2'd0: sine_of =  sin_q(idx);
                2'd1: sine_of =  sin_q(6'd63 - idx);
                2'd2: sine_of = -sin_q(idx);
                default: sine_of = -sin_q(6'd63 - idx);
            endcase
        end
    endfunction

    // ---------------- LFO（左右反相） ----------------
    reg [31:0] lfo_ph;

    wire signed [15:0] lfo_l = sine_of(lfo_ph);
    wire signed [15:0] lfo_r = sine_of(lfo_ph + 32'h8000_0000);

    // ---------------- 两条延迟线 ----------------
    reg signed [AW-1:0] mem_l [0:MAXLEN-1];
    reg signed [AW-1:0] mem_r [0:MAXLEN-1];

    reg [ABW-1:0]       wptr;
    reg [ABW-1:0]       raddr;
    reg                 we;
    reg [ABW-1:0]       waddr;
    reg signed [AW-1:0] wdata;
    reg signed [AW-1:0] rdata_l, rdata_r;

    always @(posedge clk) begin
        if (we) begin
            mem_l[waddr] <= wdata;
            mem_r[waddr] <= wdata;
        end
        rdata_l <= mem_l[raddr];
        rdata_r <= mem_r[raddr];
    end

    // ---------------- 延迟量计算（Q8.8） ----------------
    localparam integer BASE_Q8  = BASE_SAMP  * 256;
    localparam integer DEPTH_Q8 = DEPTH_SAMP * 256;

    reg signed [15:0] lfo_c;               // 本声道使用的 LFO 值（已锁存）
    //  ⚠ 位宽约束：`DEPTH_Q8 × lfo_c` 在 **32 位**里算，必须不溢出。
    //    |DEPTH_Q8 × lfo_c|max = DEPTH_SAMP×256×32768 = DEPTH_SAMP × 2²³
    //    32 位有符号上限 2³¹ ⇒ **DEPTH_SAMP ≤ 256**（当前 240，安全；120 也安全）。
    //    若要加大调制深度，必须先把乘积扩到 48 位再移位，否则静默回绕。
    wire signed [31:0] mod_q8 = (DEPTH_Q8 * lfo_c) >>> 15;
    wire signed [31:0] dly_q8 = BASE_Q8 + mod_q8;

    wire [ABW-1:0] d_int = dly_q8[ABW+7:8];        // 整数部分
    wire [7:0]     d_frac= dly_q8[7:0];            // 小数部分
    wire [ABW-1:0] a0    = wptr - d_int;
    wire [ABW-1:0] a1    = a0 - 1'b1;

    // ---------------- FSM ----------------
    localparam [2:0] ST_IDLE=3'd0, ST_R0=3'd1, ST_R1=3'd2, ST_C0=3'd3, ST_C1=3'd4, ST_C2=3'd5;
    reg [2:0] st;
    reg [1:0] ch;

    reg signed [AW-1:0] bl, br;
    reg signed [AW-1:0] m0, m1;
    reg signed [AW-1:0] wet;
    reg signed [AW-1:0] out_r;
    reg [7:0] frac_r;

    // 线性插值
    wire signed [AW:0]   dlt  = m1 - m0;
    wire signed [AW+8:0] ipol = m0 + ((dlt * $signed({1'b0, frac_r})) >>> 8);
    wire signed [AW-1:0] wet_c = ipol[AW-1:0];

    wire [16:0] mixx = {1'b0, p_mix};
    wire [16:0] onem = 17'd32768 - {1'b0, p_mix};

    wire signed [AW-1:0] o_c  = sat24(( $signed(bl) * $signed({1'b0,onem})
                                      + $signed(wet)* $signed({1'b0,mixx}) ) >>> 15);
    wire signed [AW-1:0] r_c  = sat24(($signed(o_c) * $signed(p_ret)) >>> 15);

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
            st <= ST_IDLE; ch <= 2'd0;
            wptr <= {ABW{1'b0}}; raddr <= {ABW{1'b0}};
            we <= 1'b0; waddr <= {ABW{1'b0}}; wdata <= {AW{1'b0}};
            lfo_ph <= 32'd0; lfo_c <= 16'sd0;
            bl <= {AW{1'b0}}; br <= {AW{1'b0}};
            m0 <= {AW{1'b0}}; m1 <= {AW{1'b0}}; wet <= {AW{1'b0}};
            frac_r <= 8'd0; out_r <= {AW{1'b0}};
            ret_l <= {AW{1'b0}}; ret_r <= {AW{1'b0}}; ret_vld <= 1'b0;
        end else begin
            we      <= 1'b0;
            ret_vld <= 1'b0;

            case (st)
                ST_IDLE: begin
                    if (in_vld) begin
                        bl     <= bus_l;
                        br     <= bus_r;
                        lfo_ph <= lfo_ph + (p_rate << RATE_SHIFT);
                        lfo_c  <= lfo_l;          // 左声道先用左相
                        ch     <= 2'd0;
                        st     <= ST_R0;
                    end
                end

                ST_R0: begin
                    raddr   <= a0;
                    frac_r  <= d_frac;
                    st      <= ST_R1;
                end

                // ⚠ BSRAM 同步读晚一拍：ST_R0 发 a0 的地址，rdata 要到 ST_C0 才有效，
                //   所以 m0 在 ST_C0 锁存、m1 在 ST_C1 锁存（原来各早了一拍）。
                ST_R1: begin
                    raddr <= a1;
                    st    <= ST_C0;
                end

                ST_C0: begin
                    m0 <= (ch == 2'd0) ? rdata_l : rdata_r;
                    st <= ST_C1;
                end

                ST_C1: begin
                    m1 <= (ch == 2'd0) ? rdata_l : rdata_r;
                    // ⚠⚠ 插值结果必须锁存到 wet：原来只算了 wet_c 却没赋给 wet，
                    //   而输出公式用的是 wet → 湿声项恒为 0，合唱完全没有湿声
                    //   （实测 p_mix=32767 时输出只剩 bl>>15 的干声残渣）。
                    //   本拍 m1 刚锁存，m0 在上拍已锁存，wet_c 组合可用。
                    wet <= wet_c;
                    st  <= ST_C2;
                end

                ST_C2: begin
                    // 写当前输入进延迟线，同时算出本声道输出
                    waddr <= wptr;
                    wdata <= (ch == 2'd0) ? bl : br;
                    we    <= 1'b1;

                    if (ch == 2'd0) begin
                        ret_l  <= r_c;
                        ch     <= 2'd1;
                        lfo_c  <= lfo_r;          // 切右声道，用反相 LFO
                        st     <= ST_R0;
                    end else begin
                        ret_r  <= r_c;
                        wptr   <= wptr + 1'b1;
                        ret_vld<= 1'b1;
                        st     <= ST_IDLE;
                    end
                end

                default: st <= ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
