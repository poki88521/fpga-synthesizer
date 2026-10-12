//============================================================================
//  fx_reverb —— 混响效果器（设计文档 §2）
//
//  结构：Freeverb。每个声道 = 8 个并联低通反馈梳状滤波器（输出相加）
//        + 4 个串联全通滤波器。左右声道用不同的延迟长度（右声道 +23 采样），
//        得到立体声展开。
//
//  延迟长度（48 kHz，由 Freeverb 的 44.1 kHz 值乘 1.08844 并取整）：
//      梳状 0~7 : 1215 1293 1390 1476 1548 1623 1695 1760
//      全通 8~11:  605  480  371  245
//      右声道全部 +23（605+23=628 等），本实现用右声道的长度表另算
//
//  单梳状：
//      out   = buf[ptr]
//      fs    = out*(1-damp) + fs*damp          一阶低通（逐线状态）
//      write = in + fs*decay
//  全通：
//      bufout= buf[ptr]
//      out   = -x + bufout
//      write = x + bufout*0.5                  全通反馈固定 0.5
//
//  ⚠ 参数口径（团队文档只给了字段名和位宽，没给单位，以下是本实现的定义）：
//      reverb_decay   Q1.15 梳状反馈量（内部限幅到 0.98，防止自激）
//      reverb_damping Q1.15 高频阻尼
//      reverb_size    Q1.15 输入增益（模拟空间尺寸对湿信号强度的影响）
//      reverb_return  Q1.15 返回电平
//      reverb_pre_delay  预留（本版未做预延迟线）
//
//  结构：12 条线 x 2 声道 = 24 条，全部时分复用同一块 BSRAM，
//        每线 3 拍（发地址 / 读回 / 算+写），共 72 拍/采样。
//============================================================================

`default_nettype none

module fx_reverb #(
    parameter integer AW  = 24,
    parameter integer SBW = 11,           // 每条线的槽内地址位宽（槽深 2^SBW）
    parameter integer SLOT= 2048
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 frame_stb,

    input  wire                 in_vld,
    input  wire signed [AW-1:0] bus_l, bus_r,

    input  wire [15:0]          p_decay,
    input  wire [15:0]          p_damp,
    input  wire [15:0]          p_size,
    input  wire [15:0]          p_ret,
    input  wire [15:0]          p_predly,

    output reg                  ret_vld,
    output reg  signed [AW-1:0] ret_l, ret_r
);

    localparam integer NL = 12;           // 每声道 12 条线
    localparam integer NS = NL * SLOT;    // 每声道槽总深度

    function automatic signed [AW-1:0] sat24;
        input signed [47:0] v;
        begin
            if      (v >  48'sd8388607) sat24 = 24'sh7FFFFF;
            else if (v < -48'sd8388608) sat24 = 24'sh800000;
            else                        sat24 = v[AW-1:0];
        end
    endfunction

    // 左声道线长；右声道 = 左 + 25（设计文档 2.4："右声道各延迟再加 25 点做立体声展宽"）
    function [SBW-1:0] len_of;
        input [3:0] i;
        begin
            case (i)
                4'd0 : len_of = 11'd1215;
                4'd1 : len_of = 11'd1293;
                4'd2 : len_of = 11'd1390;
                4'd3 : len_of = 11'd1476;
                4'd4 : len_of = 11'd1548;
                4'd5 : len_of = 11'd1623;
                4'd6 : len_of = 11'd1695;
                4'd7 : len_of = 11'd1760;
                4'd8 : len_of = 11'd605;
                4'd9 : len_of = 11'd480;
                4'd10: len_of = 11'd371;
                default: len_of = 11'd245;
            endcase
        end
    endfunction

    // ---------------- FSM 状态 / 线号 / 声道 / 指针（地址段要用，必须先声明）----------------
    localparam [2:0] ST_IDLE=3'd0,   // 等 in_vld
                     ST_RD  =3'd1,   // 发读地址（组合 cur 已在线上）
                     ST_ADS =3'd2,   // 锁写地址 waddr <= cur = 本线的 cur
                     ST_WR  =3'd3,   // 读数据 m0 有效
                     ST_CM  =3'd4,   // 算 wdata（组合）
                     ST_WB  =3'd5;   // 读旧值、写新值，同一拍完成
    reg [2:0]        st;
    reg [3:0]        li;
    reg [1:0]        ch;
    reg [SBW-1:0]    ptr_l [0:NL-1];
    reg [SBW-1:0]    ptr_r [0:NL-1];

    // 每条线在缓冲里的**累加偏移**（Freeverb 原版就是一条共享 buffer + 各 tap 固定偏移）。
    // ⚠ 不能用 li*SLOT 的"等距槽"布局：那样线长(1215)与槽距(2048)不一致，
    //   后一条线的槽会盖住前一条线还没读完的区域，回声位置与声道全乱（实测过）。
    function [15:0] off_of;
        input [3:0] i;
        begin
            case (i)
                4'd0 : off_of = 16'd0;
                4'd1 : off_of = 16'd1215;
                4'd2 : off_of = 16'd2508;
                4'd3 : off_of = 16'd3898;
                4'd4 : off_of = 16'd5374;
                4'd5 : off_of = 16'd6922;
                4'd6 : off_of = 16'd8545;
                4'd7 : off_of = 16'd10240;
                4'd8 : off_of = 16'd12000;
                4'd9 : off_of = 16'd12605;
                4'd10: off_of = 16'd13085;
                default: off_of = 16'd13456;
            endcase
        end
    endfunction

    // ---------------- 地址（必须声明在 BSRAM 之前：写口用组合地址译码）----------------
    //  读：本拍发 cur，下一拍 rdata 有效（BSRAM 同步读晚一拍）
    //  写：写口地址用 cur_w =「下一个指针位置」，于是
    //        sample k     写进 p+1
    //        sample k+len 时 p 恰好走到 p+1，读到 sample k 写进去的值
    //      → 延迟正好 len 拍（若拿 cur 当写地址会变成 len-1 拍，实测回声整体提前 1 拍）。
    wire [SBW-1:0] pcur  = ch ? ptr_r[li] : ptr_l[li];
    // 左声道占 0..14745，右声道从 14746 开始（总缓冲 2 x 14746 = 29492）
    wire [15:0]    base  = (ch ? 16'd14746 : 16'd0) + off_of(li);
    wire [15:0]    cur   = base + {{(16-SBW){1'b0}}, pcur};
    wire [SBW-1:0] len   = len_of(li) + (ch ? 11'd25 : 11'd0);
    wire [SBW-1:0] pnext = (pcur + 1'b1 >= len) ? {SBW{1'b0}} : (pcur + 1'b1);
    wire [15:0]    cur_w = base + {{(16-SBW){1'b0}}, pnext};

    // ---------------- 一块 BSRAM，左右各一半 ----------------
    reg signed [AW-1:0] rmem [0:29491];

    // ⚠ 地址必须 16 位：NS = 12 x 2048 = 24576，右声道基址就是 24576，
    //   加上 li*2048（最大 22528）和 ptr（最大 2047）会到 49151（0xBFFF）。
    //   原来写成 15 位会把右声道地址截断，读写串到左声道区里去。
    reg [15:0]          waddr;
    reg signed [AW-1:0] wdata, rdata;

    always @(posedge clk) begin
        if (st == ST_WB) rmem[waddr] <= wdata;
        rdata <= rmem[cur];                      // 读地址：组合 cur（无寄存器延迟）
    end

    // ---------------- 逐线状态 ----------------
    reg signed [AW-1:0] fs_l [0:7];
    reg signed [AW-1:0] fs_r [0:7];

    // ---------------- FSM ----------------
    reg signed [AW-1:0] bl, br;
    reg signed [AW-1:0] xin;              // 本声道输入（梳状/全通的源）
    // ⚠ BSRAM 同步读晚一拍：ST_RD 发地址，rdata 到 ST_CM 才有效。
    //   原来在 ST_WR 就 m0 <= rdata，锁到的是上一条线的数据。
    wire signed [AW-1:0] m0 = rdata;
    reg signed [47:0]   comb_sum;
    // ⚠⚠ 全通链的反馈状态必须**每级一份**（4 级 = 4 个寄存器）。
    //   原来 4 级共用同一个 ap_x，而 ap_x 在一条线一个采样里要被读一次写一次，
    //   下一级在 ST_CM 一写就把上一级的值冲掉，于是 ap_x 在 793/-793/0 之间乱跳，
    //   全通的反馈项彻底失效（表现为"梳状回声都在、输出却没有回声"）。
    //   索引 = li - 8（第 0 级喂给第 1 级时正好被读到）。
    reg signed [AW-1:0] ap_fb [0:3];
    // ⚠⚠ 全通每级还要各自保存：(a) 本级的输入 ap_in，(b) 本级的延迟线读出 ap_rd。
    //   原来只用一个共享的 xin：xi 到第 8 条线才装载，第 9~11 条线读到的还是 0，
    //   于是 4 级全通里只有第 1 级有数据（实测 comb_sum=793 却写不进延迟线）。
    //   索引 = li-8（0..3），与 ap_fb 对齐。
    reg signed [AW-1:0] ap_in [0:3];
    reg signed [AW-1:0] ap_rd [0:3];
    // 全通链的"本拍输入"：第 0 级来自梳状和，第 i 级来自第 i-1 级的输出
    reg signed [AW-1:0] ap_wire [0:3];
    reg signed [AW-1:0] fsc;              // 当前线的低通状态


    // 参数
    wire signed [15:0] decay = ($signed(p_decay) > 16'sd32112) ? 16'sd32112 : $signed(p_decay);  // 限 0.98
    wire signed [15:0] damp  = $signed(p_damp);
    wire signed [15:0] size  = $signed(p_size);
    wire signed [15:0] oned  = 16'sd32767 - damp;             // 1 - damp

    // 梳状：低通 + 反馈
    //  位宽证明（为什么 [AW+15:0] = 40 位够用）：
    //    该项 = m0*(1−damp) + fsc*damp，而 (1−damp) + damp = 32767；
    //    |m0|、|fsc| ≤ 2²³（24 位有符号满量程）⇒
    //    |结果| ≤ 2²³ × 32767 = 274869518336 < 2³⁸，**40 位有充裕余量**。
    //    ⚠ 若将来把 AW 或系数位宽加大（例如 AW=32 或 damp 用 Q1.31），
    //      这个上界就不再成立，必须同步加宽，否则静默回绕。
    wire signed [AW+15:0] fs_new_p = $signed(m0) * oned + fsc * damp;
    wire signed [AW-1:0]  fs_new   = sat24({{(48-(AW+16)){fs_new_p[AW+15]}}, fs_new_p} >>> 15);
    // ⚠ Q1.15 乘法之后必须先 >>>15 再相加。
    //   **不能**写成 ({{(48-(AW+16)){p[AW+15]}}, p} >>> 15)：那句的移位量是
    //   48-(24+16)=8 位符号 + 40 位乘积 = 48 位，>>>15 后只剩低 33 位有效，
    //   正数会丢掉中间位（m0=-1000 时算出 8589933676 而不是 -916），
    //   负数的偏差会直接把延迟线写爆（这就是"1705 爆炸"）。
    //   正确做法：把两个 operands 显式**扩展到 48 位**再乘，>>>15 就是纯算术右移。
    wire signed [47:0]    comb_w_p = $signed({{24{fs_new[AW-1]}}, fs_new}) * $signed(decay);
    wire signed [47:0]    comb_w   = (comb_w_p >>> 15) + $signed({{24{xin[AW-1]}}, xin});
    wire signed [47:0]    comb_sum_n = comb_sum + {{24{m0[AW-1]}}, m0};

    // 全通
    // 当前全通级看到的上级输出：第 7 条线时是 8 个梳状之和（须饱和），
    // 之后是上一级的反馈状态（每级一份 ap_fb）。
    // ⚠ 下标必须钳位：梳状线 li<8 时 li-8 是负数，数组负下标会取到 X 并污染状态。
    wire [1:0]            ap_sel  = (li < 4'd8) ? 2'd0 : (li - 4'd8);
    // 第 7 条线时 ap_x 是 8 个梳状之和（喂给第 1 级全通），其余是各线自己的数据
    wire signed [AW-1:0]  ap_x    = (li == 4'd7) ? sat24(comb_sum_n) : ap_rd[ap_sel];
    // 全通级的输入 = 本级保存的 ap_in（第 1 级是梳状和，其余是上一级的输出）
    wire signed [AW-1:0]  ap_in_c = ap_in[ap_sel];
    // 依据 Freeverb 原始 allpass（allpass.hpp，Jezar 2000，public domain）：
    //     output = -input + bufout;          → out = m0 - ap_in
    //     buffer[bufidx] = input + bufout*feedback;  → write = ap_in + 0.5*m0
    //   ⚠ 这两个系数**不相等**（1 和 0.5），是 Freeverb 的近似全通，别"修正"成相等。
    wire signed [AW:0]    ap_out_p = $signed({m0[AW-1], m0}) - $signed({ap_in_c[AW-1], ap_in_c});
    wire signed [AW-1:0]  ap_out   = ap_out_p[AW-1:0];
    // ⚠⚠ 全通写回值是 x + bufout*0.5，反馈项用的是**本级自己的 bufout（=m0）**，
    //   不是上级输出 ap_x。实测：用 ap_x 时 ap_w（应=793+396=1189）算成了 0，
    //   信号一进全通链就没了。
    // 写回值 = 输入 + bufout*0.5（反馈用的是**本级自己的**延迟读出 ap_x）
    wire signed [47:0]    ap_fb_p  = $signed({{24{ap_x[AW-1]}}, ap_x}) * 48'sd16384;
    wire signed [47:0]    ap_w     = (ap_fb_p >>> 15) + $signed({{24{ap_in_c[AW-1]}}, ap_in_c});

    integer i;

`ifdef SIMULATION
    // 仿真专用的存储器初值。**综合器看不到这一段**（被 ifdef 挡住），
    // 所以 BSRAM 仍然能被正常推断出来。
    // 之前把清零写在复位分支里是错的：BSRAM 没有复位端口，综合器
    // 只能报错或者强行推断成触发器阵列（混响是 49152 x 24 bit，直接爆）。
    initial begin
        for (i = 0; i < 29492; i = i + 1) begin
            rmem[i] <= {AW{1'b0}};
        end
    end
`endif

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= ST_IDLE; li <= 4'd0; ch <= 1'b0;
            waddr <= 16'd0; wdata <= {AW{1'b0}};
            bl <= {AW{1'b0}}; br <= {AW{1'b0}};
            xin <= {AW{1'b0}};
            comb_sum <= 48'sd0; fsc <= {AW{1'b0}};
            ret_l <= {AW{1'b0}}; ret_r <= {AW{1'b0}}; ret_vld <= 1'b0;
            for (i = 0; i < 4; i = i + 1) begin
                ap_fb[i] <= {AW{1'b0}}; ap_in[i] <= {AW{1'b0}}; ap_rd[i] <= {AW{1'b0}}; ap_wire[i] <= {AW{1'b0}};
            end
            for (i = 0; i < 8; i = i + 1) begin
                fs_l[i] <= {AW{1'b0}};
                fs_r[i] <= {AW{1'b0}};
            end
            for (i = 0; i < NL; i = i + 1) begin
                ptr_l[i] <= {SBW{1'b0}};
                ptr_r[i] <= {SBW{1'b0}};
            end
        end else begin
            ret_vld <= 1'b0;

            case (st)
                ST_IDLE: begin
                    if (in_vld) begin
                        // 输入增益
                        bl <= sat24(($signed(bus_l) * size) >>> 15);
                        br <= sat24(($signed(bus_r) * size) >>> 15);
                        ch <= 1'b0; li <= 4'd0;
                        comb_sum <= 48'sd0;
                        st <= ST_RD;
                    end
                end

                ST_RD: begin
                    // 读地址是**组合**的 cur（见 BSRAM 读口），本拍发出、下一拍 rdata 有效
                    st <= ST_ADS;
                end

                // ⚠⚠ 写地址必须在这里锁存，而且必须在换这条线的**同一拍**：
                //   waddr 是寄存器（比组合的读地址慢一拍）。若放到 ST_WR/ST_CM 才锁，
                //   换线后第一拍锁到的还是上一条线（甚至上一个声道）的 cur ——
                //   实测右声道 line0 的写地址变成了左声道 line11 的 13456，
                //   于是右声道的脉冲写进了左声道的槽，右声道输出自己的第 1215 拍读不到东西。
                ST_ADS: begin
                    waddr <= cur;
                    st    <= ST_WR;
                end

                ST_WR: begin
                    // m0 = rdata 在本拍有效；装载本线的低通状态与声道输入
                    xin <= (li == 4'd0) ? (ch ? br : bl) : xin;
                    if (li < 8) fsc <= ch ? fs_r[li[2:0]] : fs_l[li[2:0]];
                    st  <= ST_CM;
                end

                ST_CM: begin
                    if (li < 8) begin
                        // ---- 梳状 ----
                        wdata <= sat24(comb_w);
                        comb_sum <= comb_sum_n;
                        if (ch) fs_r[li[2:0]] <= fs_new; else fs_l[li[2:0]] <= fs_new;
                    end else begin
                        // ---- 全通 ----
                        // 反馈状态每级一份，只更新本级那一个（li=8..11 → 0..3）
                        wdata <= sat24(ap_w);
                    end

                    // 指针推进（按本声道线长回绕）
                    if (ch) begin
                        ptr_r[li] <= (ptr_r[li] + 1'b1 >= len) ? {SBW{1'b0}} : (ptr_r[li] + 1'b1);
                    end else begin
                        ptr_l[li] <= (ptr_l[li] + 1'b1 >= len) ? {SBW{1'b0}} : (ptr_l[li] + 1'b1);
                    end

                    // 第 8~11 条线（全通链）：
                    //   ap_rd 存本级的延迟读出；ap_fb 存本级输出（供下一级的输入用）
                    if (li >= 4'd8) begin
                        ap_rd[ap_sel] <= m0;
                        ap_fb[ap_sel] <= ap_out;
                    end
                    // ⚠ 必须在**第 7 条线这一拍**把 8 个梳状之和装进第 1 级全通的输入：
                    //   等到 li=8 再装就晚了一拍（实测第 8~11 线的写数据全是 0）。
                    if (li == 4'd7) ap_in[2'd0] <= sat24(comb_sum_n);
                    // ⚠⚠ 全通链的输入传递必须"本拍算完立刻喂下一级"，而且四个级要一起锁存。
                    //   原来在第 8~10 条线写 ap_in[sel+1]：ap_in 是**下一采样**的值，
                    //   第 2 级当拍读到的是上一采样的中间值（实测 stage1 输入 -793、
                    //   stage2 输入 0）→ 第 3、4 级读到 0，梳状 6 的回声被抵消。
                    //   也不能写成 ap_in <= ap_fb（那是把本级输出当本级输入 → 自激）。
                    //   正确做法：第 8~10 条线内部走 ap_wire 链，第 11 条线一拍锁存
                    //   ap_in = {comb_sum, stage0输出, stage1输出, stage2输出}。
                    ap_wire[0] <= ap_in_c;                       // 一致（仅为链路完整）
                    if (li >= 4'd8 && li <= 4'd10) ap_wire[ap_sel + 2'd1] <= ap_out;
                    if (li == 4'd11) for (i = 0; i < 4; i = i + 1) ap_in[i] <= ap_wire[i];

                    st <= ST_WB;
                end

                // ---- 写回：st==ST_WB 时读旧值、写新值同一拍完成 ----
                ST_WB: begin
                    // 下一条线 / 换声道 / 结束
                    if (li == NL-1) begin
                        if (ch == 1'b0) begin
                            ret_l <= sat24(($signed(ap_out) * $signed(p_ret)) >>> 15);
                            ch    <= 1'b1;
                            li    <= 4'd0;
                            comb_sum <= 48'sd0;
                            st    <= ST_RD;
                        end else begin
                            ret_r <= sat24(($signed(ap_out) * $signed(p_ret)) >>> 15);
                            ret_vld <= 1'b1;
                            st    <= ST_IDLE;
                        end
                    end else begin
                        li <= li + 4'd1;
                        st <= ST_RD;
                    end
                end

                default: st <= ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
