//============================================================================
//  fx_reverb —— 混响效果器（Freeverb 结构）
//
//  结构：每个声道 = 16 个并联低通反馈梳状滤波器（输出相加）
//                 + 4 个串联全通滤波器。
//        左右声道用不同的延迟长度（右声道每条 +25 采样）得到立体声展开。
//
//  单条梳状（Freeverb）：
//      m0    = buf[ptr]                       延迟线读出
//      fs    = m0*(1-damp) + fs*damp          一阶低通（每线一份状态）
//      write = m0*(1-damp)*decay + fs*damp*decay + in     （两级 Q15 乘法合并，见下）
//  全通（Freeverb allpass.hpp）：
//      out   = m0 - in
//      write = in + 0.5*m0
//      ⚠ 这两个系数**不相等**（1 与 0.5），是 Freeverb 的近似全通，别"修正"成相等。
//
//  参数口径（团队文档只给了字段名和位宽，没给单位，以下是本实现的定义）：
//      reverb_decay   Q1.15 梳状反馈量（内部限到 0.98 防自激）
//      reverb_damping Q1.15 高频阻尼
//      reverb_size    Q1.15 输入增益（模拟空间尺寸对湿信号强度的影响）
//      reverb_return  Q1.15 返回电平
//      reverb_pre_delay  预留（本版未做预延迟线）
//
//  时分复用：20 条线 x 2 声道，每条线 5 拍（发地址/锁写址/读回/算/写回）
//            = 200 拍/采样。系统给的是 1024 拍，余量充足。
//
//============================================================================
//  ⚠⚠ 2026-10-28 重构（"有音+开混响→炸"的根因就在本文件）
//
//  ① 【根因】comb_w 的 >>> 作用在**位拼接**上：
//        wire signed [47:0] comb_w = ({{7{comb_w_x[40]}}, comb_w_x} >>> 15) + xin;
//     Verilog 里位拼接永远是无符号的 ⇒ 整个表达式变无符号 ⇒ `>>>` 退化成逻辑右移。
//     负的梳状反馈值被补 0 变成巨大正数，再被 sat24 钳到 +满量程：
//     反馈路径实际变成"半波整流 + 正反馈"，延迟线在两个来回内冲到满量程。
//     实测（0.60 FS 1 kHz、上板参数）：注入仅 0.0019 FS，却让单条梳状 62 ms 内
//     冲到 1.00 FS、16 条之和 10 FS、湿声峰值满量程且 23% 采样被削顶 —— 就是"炸"。
//     修法：先赋给 **signed wire** 做符号扩展，再移位（与本文件 fs_new_x 的写法一致）。
//
//  ② 全通输出 ap_out 原来是 25 位直接截断到 24 位（没有饱和）：
//     out = m0 - in 可以到 2 倍满量程，溢出时符号翻转（实测一次 20000 帧的仿真里
//     发生 110703 次）。改成 sat24。
//
//  ③ 右声道每条线是 len+25，但偏移表用的是左声道的 len 累加 ⇒ 右声道每条梳状的
//     环形区间末端会盖住下一条的开头 25 个采样 ⇒ 16 条梳状互相串扰
//     （实测右声道电平比左声道高 1.5 倍、染色也不对）。
//     修法：右声道单独一张"含 +25 间隙"的偏移表（off_r）。
//
//  ④ 全通反馈原来用 ap_x/ap_rd（上一采样的读出），与 Freeverb 的"当前读出 m0"不符，
//     等价于把反馈延迟从 N 改成 N+1（改掉全通特性、并在 4 级串联下形成额外谐振）。
//     现在直接用 m0，顺带删掉那个 48 位乘法器（×16384 已换成算术右移 1 位）。
//
//  ⑤ 全通链的第 1 级根本没接到"16 条梳状之和"：
//     ap_in/ap_wire 两套状态里 `ap_wire[0] <= ap_in_c;` 每条线都执行，
//     而 li=17/18/19 时 ap_in_c 分别是 ap_in[1]/[2]/[3]，最后 li==19 的
//     `ap_in[i] <= ap_wire[i]` 把第 1 级输入覆盖成"上一拍别的级的值"。
//     实测：comb_sum>>>1 = 155 的那一帧，下一帧 ap_in[0] = 0（应为 155）。
//     改成单套 ap_in：li==15 装梳状和，li==16/17/18 逐级往下传。
//
//  ⑥ 新增：梳状求和处与出口各加一级**软限幅**（0.75 FS 拐点、以上斜率 1/4，
//     只用比较/加/移位，无乘法器），杜绝硬削顶；仿真下按帧打印限幅次数与湿声峰值。
//
//------------------------------------------------------------------------------
//  增益预算（2026-10-28 重构后实测：0.60 FS 正弦、满发送、20000 帧建立，
//            size=26000 decay=31000 damp=24576 ret=26000）
//
//    节点                        1 kHz           60 Hz          设计口径
//    总线注入 bl                 0.0019 FS       0.0019 FS      = bus*size >> 23（÷256）
//    单条梳状读出 m0             0.0067 FS       0.0166 FS      1/(1-decay)=18.5 是 DC 上界
//    16 条之和 comb_sum          0.0133 FS       0.0200 FS      "16 条相干"上界 0.92 FS
//    comb_sum >>> SUM_SH(1)      0.0067 FS       0.0100 FS
//    全通 4 级 ap_out            0.0297 FS       0.0665 FS      单级峰值上限 1.667 ×4
//    ret（L / R）               0.094/0.204     0.211/0.206     RET_SH=13（×4）
//    内部饱和/削顶次数             0               0             软限幅拐点 0.75 FS
//
//  ⇒ 湿声约 −14 dBFS（相对 0.6 FS 干声约 −10~−13 dB），空载/满发送都不削顶。
//     ⚠ 1 kHz 时左右声道差 6.7 dB 是**模态差**（左右每条线长差 25），不是错误：
//       脉冲激励下 16 条梳状在两声道的首回声幅度完全相同（620 / 620）。
//     要改混响量：只改 RET_SH（1 档 6 dB），不要动 INJ_SH（它决定内部余量）。
//
//  复现/量测脚本：develop/scratch/agent/tb_reverb_diag2.v（逐级峰值 + 包络）
//                  simulation/tb/tb_fx_reverb.v（脉冲响应 7 项）
//                  simulation/tb/tb_reverb_level.v（湿声电平回归）
//==============================================================================

`default_nettype none

module fx_reverb #(
    parameter integer AW  = 24,           // 音频位宽
    parameter integer SBW = 12,           // 槽内地址位宽（最大线长 2^12 = 4096）
    parameter integer SLOT= 4096          // 槽深（仅文档用；实际布局见 off_l/off_r）
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 frame_stb,        // 48 kHz 帧节拍（仿真统计用）

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

    // ========================================================================
    //  缩放常数（全部集中在这里，改电平只改这几个）
    // ========================================================================
    localparam integer INJ_SH  = 23;      // 梳状注入 = (bus*size) >> 23  （÷256）
    localparam integer SUM_SH  = 1;       // 16 条梳状之和 >> 1
    localparam integer RET_SH  = 13;      // 出口 = (wet*p_ret) >> 13
                                          //   p_ret 是 Q1.15：>>15 = ×p_ret，
                                          //   >>13 = ×4·p_ret。
                                          //   为什么是 ×4：÷2 是补回 SUM_SH，再 ×2 是把
                                          //   湿声从 −20 dBFS 抬到 −14 dBFS
                                          //   （旧的 ÷256 + ×2 只有 −20 dB，用户反馈
                                          //     "混响开/关几乎听不出区别"）。
                                          //   实测（0.6 FS 单音、满发送）：
                                          //     1 kHz  L 0.094 / R 0.204 FS
                                          //     60 Hz  L 0.211 / R 0.206 FS
                                          //   仍在 `dry 0.6 + wet ≤0.35` 的预算内。
    // 软限幅拐点：0.75 FS。以上斜率 1/4 ⇒ 输出最大 0.75 + 0.25/4 = 0.8125 FS，永不硬削。
    localparam signed [47:0] LIM_K = 48'sd6291456;

    //  2026-10-27：两条 Q15 乘法合并成一条（关键路径优化）。
    //    原来 rdata → m0 →(×oned/×damp)→ fs_new →(×decay)→ comb_w → sat24 → wdata
    //    是两级级联乘法 + 两次饱和，P&R 实测 data delay 21.85 ns > 周期 20.345 ns。
    //    数学上：  comb_w = (m0·K1 + fs·K2) >> 15 + in
    //              K1 = (1-damp)·decay >> 15 ，K2 = damp·decay >> 15
    //    K1/K2 只跟准静态参数有关、不随线变化 ⇒ 每条线只剩一级乘法。

    //  线号：0..15 梳状，16..19 全通
    localparam integer NL = 20;

    // ========================================================================
    //  饱和 / 软限幅
    // ========================================================================
    function automatic signed [AW-1:0] sat24;
        input signed [47:0] v;
        begin
            if      (v >  48'sd8388607) sat24 = 24'sh7FFFFF;
            else if (v < -48'sd8388608) sat24 = 24'sh800000;
            else                        sat24 = v[AW-1:0];
        end
    endfunction

    //  软限幅：|v| <= LIM_K 直通；超过后 y = sign(v)*(LIM_K + (|v|-LIM_K)/4)。
    //  纯组合、无乘法器（约 20 LUT），只在 |v|>0.75 FS 时才产生一点谐波。
    function automatic signed [AW-1:0] soft24;
        input signed [47:0] v;
        reg signed [47:0] a, y;
        begin
            if (v > LIM_K) begin
                a = (v - LIM_K) >>> 2;
                y = LIM_K + a;
                soft24 = (y > 48'sd8388607) ? 24'sh7FFFFF : y[AW-1:0];
            end else if (v < -LIM_K) begin
                a = ((-v) - LIM_K) >>> 2;
                y = LIM_K + a;
                soft24 = (y > 48'sd8388607) ? 24'sh800000 : -y[AW-1:0];
            end else begin
                soft24 = v[AW-1:0];
            end
        end
    endfunction

    // ========================================================================
    //  延迟线长度表（48 kHz，Freeverb 44.1 kHz 值 ×1.08844 取整）
    //  2026-10-28：16 条梳状取 1215~1637（25~34 ms，互质）。
    //    原来最长 2879，20 线 + 64000 深时 P&R 两次在 Routing Phase 1 中止；
    //    密度靠"条数"而不是"长度"，收短只牺牲一点空间尺寸，BSRAM 49000 够用。
    // ========================================================================
    function [SBW-1:0] len_of;
        input [4:0] i;
        begin
            case (i)
                5'd0 : len_of = 12'd1215;
                5'd1 : len_of = 12'd1231;
                5'd2 : len_of = 12'd1249;
                5'd3 : len_of = 12'd1277;
                5'd4 : len_of = 12'd1293;
                5'd5 : len_of = 12'd1319;
                5'd6 : len_of = 12'd1346;
                5'd7 : len_of = 12'd1373;
                5'd8 : len_of = 12'd1390;
                5'd9 : len_of = 12'd1417;
                5'd10: len_of = 12'd1443;
                5'd11: len_of = 12'd1476;
                5'd12: len_of = 12'd1508;
                5'd13: len_of = 12'd1548;
                5'd14: len_of = 12'd1592;
                5'd15: len_of = 12'd1637;
                //  —— 全通 4 条：5~12 ms（v1 的短全通会在 3~8 kHz 形成稀疏染色，已退回）——
                5'd16: len_of = 12'd605;
                5'd17: len_of = 12'd480;
                5'd18: len_of = 12'd371;
                default: len_of = 12'd245;
            endcase
        end
    endfunction

    // ========================================================================
    //  左声道偏移（每条线紧挨着，无间隙：左声道长度就是 len_of）
    // ========================================================================
    function [15:0] off_l;
        input [4:0] i;
        begin
            case (i)
                5'd0 : off_l = 16'd0;
                5'd1 : off_l = 16'd1215;
                5'd2 : off_l = 16'd2446;
                5'd3 : off_l = 16'd3695;
                5'd4 : off_l = 16'd4972;
                5'd5 : off_l = 16'd6265;
                5'd6 : off_l = 16'd7584;
                5'd7 : off_l = 16'd8930;
                5'd8 : off_l = 16'd10303;
                5'd9 : off_l = 16'd11693;
                5'd10: off_l = 16'd13110;
                5'd11: off_l = 16'd14553;
                5'd12: off_l = 16'd16029;
                5'd13: off_l = 16'd17537;
                5'd14: off_l = 16'd19085;
                5'd15: off_l = 16'd20677;
                5'd16: off_l = 16'd22314;
                5'd17: off_l = 16'd22919;
                5'd18: off_l = 16'd23399;
                default: off_l = 16'd23770;
            endcase
        end
    endfunction

    // ========================================================================
    //  右声道偏移 = 左声道偏移 + 25*i（每条线比左声道长 25，必须留出间隙）
    //  ⚠ 2026-10-28：原来右声道直接复用 off_l，于是每条线的环尾盖住下一条的开头
    //     25 个采样（len+25 的环形区间 vs len 的间距）→ 16 条梳状互相串扰。
    //  右声道总长 = 24245 + (245+25) = 24515，基址 24015（左声道占 0..24014）
    //  最大地址 = 24015 + 24245 + 245 + 25 - 1 = 48529 < 49000 ✓
    // ========================================================================
    function [15:0] off_r;
        input [4:0] i;
        begin
            case (i)
                5'd0 : off_r = 16'd0;
                5'd1 : off_r = 16'd1240;
                5'd2 : off_r = 16'd2496;
                5'd3 : off_r = 16'd3770;
                5'd4 : off_r = 16'd5072;
                5'd5 : off_r = 16'd6390;
                5'd6 : off_r = 16'd7734;
                5'd7 : off_r = 16'd9105;
                5'd8 : off_r = 16'd10503;
                5'd9 : off_r = 16'd11918;
                5'd10: off_r = 16'd13360;
                5'd11: off_r = 16'd14828;
                5'd12: off_r = 16'd16329;
                5'd13: off_r = 16'd17862;
                5'd14: off_r = 16'd19435;
                5'd15: off_r = 16'd21052;
                5'd16: off_r = 16'd22714;
                5'd17: off_r = 16'd23344;
                5'd18: off_r = 16'd23849;
                default: off_r = 16'd24245;
            endcase
        end
    endfunction

    localparam [15:0] RIGHT_BASE = 16'd24015;      // 左声道 0..24014

    // ========================================================================
    //  FSM 状态 / 线号 / 声道 / 指针
    // ========================================================================
    localparam [2:0] ST_IDLE=3'd0,   // 等 in_vld
                     ST_RD  =3'd1,   // 发读地址（组合 cur 已在线上）
                     ST_ADS =3'd2,   // 锁写地址 waddr <= cur
                     ST_WR  =3'd3,   // 读数据 m0 有效
                     ST_CM  =3'd4,   // 算 wdata（组合）
                     ST_WB  =3'd5;   // 写回
    reg [2:0]        st;
    reg [4:0]        li;
    reg [1:0]        ch;
    reg [SBW-1:0]    ptr_l [0:NL-1];
    reg [SBW-1:0]    ptr_r [0:NL-1];

    // ========================================================================
    //  地址：读口用组合 cur；写口在 ST_ADS 锁存 cur
    //  ⚠ 写地址必须和读地址**同一个**（base+pcur）：sample k 写进 p，
    //    sample k+len 时指针回到 p 再读出来 → 延迟正好 len 拍。
    //    （若写 p+1，延迟会变成 1 拍；实测过。）
    // ========================================================================
    wire [SBW-1:0] pcur  = ch ? ptr_r[li] : ptr_l[li];
    wire [15:0]    base  = ch ? (RIGHT_BASE + off_r(li)) : off_l(li);
    wire [15:0]    cur   = base + {{(16-SBW){1'b0}}, pcur};
    wire [SBW-1:0] len   = len_of(li) + (ch ? 12'd25 : 12'd0);

    // ---------------- 一块 BSRAM，左右各一半 ----------------
    //  深度 49000：左 0..24014、右 24015..48529（含每条线 +25 的间隙）
    reg signed [AW-1:0] rmem [0:48999];

    reg [15:0]          waddr;
    reg signed [AW-1:0] wdata, rdata;

    always @(posedge clk) begin
        if (st == ST_WB) rmem[waddr] <= wdata;
        rdata <= rmem[cur];                      // 同步读，比地址晚一拍
    end

    // ---------------- 逐线低通状态（只有 16 条梳状需要）----------------
    reg signed [AW-1:0] fs_l [0:15];
    reg signed [AW-1:0] fs_r [0:15];

    // ---------------- FSM 数据寄存器 ----------------
    reg signed [AW-1:0] bl, br;              // 本采样的注入（已含 size 与 ÷256）
    reg signed [AW-1:0] xin;                 // 本声道注入（所有梳状共用一个输入）
    wire signed [AW-1:0] m0 = rdata;         // 本线延迟线读出（BSRAM 同步读）

    reg signed [47:0]   comb_sum;            // 16 条梳状之和（逐线累加）
    //  ⚠⚠ 全通每级各一份输入：ap_in[i] = 第 i 级的输入。
    //  2026-10-28：原来是 ap_in/ap_wire 两套 + li==19 一次锁存，其中
    //      `ap_wire[0] <= ap_in_c;` 在每条线都执行（li=17/18/19 时 ap_in_c 分别是
    //      ap_in[1]/[2]/[3]），于是 li==19 的 `ap_in[i] <= ap_wire[i]` 把
    //      **第 1 级拼好的"16 条梳状之和"覆盖成了上一拍别的级的值**。
    //      实测：comb_sum>>>1 = 155 的那一帧，下一帧 ap_in[0] = 0（应为 155），
    //      而 ap_in[1] = -155、ap_in[2] = +155 —— 梳状和根本没进全通链。
    //  现在只留一套 ap_in：li==15 装第 1 级输入、li==16/17/18 把本级输出装进
    //  下一级的输入（同一采样内按线号顺序逐级传递，读发生在写之后，天然正确）。
    reg signed [AW-1:0] ap_in [0:3];
    reg signed [AW-1:0] fsc;                 // 当前线的低通状态

    // ---------------- 参数 ----------------
    wire signed [15:0] decay = ($signed(p_decay) > 16'sd32112) ? 16'sd32112 : $signed(p_decay); // ≤0.98
    wire signed [15:0] damp  = $signed(p_damp);
    wire signed [15:0] size  = $signed(p_size);
    wire signed [15:0] oned  = 16'sd32767 - damp;            // 1 - damp

    // ========================================================================
    //  注入：bl = bus*size >> INJ_SH（四舍五入）
    //  位宽：24 位 × 16 位 = 40 位精确，+0.5 LSB 后 >>> 23
    // ========================================================================
    wire signed [39:0] inj_mul_l = $signed(bus_l) * size;
    wire signed [39:0] inj_mul_r = $signed(bus_r) * size;
    wire signed [47:0] inj_x_l   = $signed({{8{inj_mul_l[39]}}, inj_mul_l}) + 48'sd4194304;
    wire signed [47:0] inj_x_r   = $signed({{8{inj_mul_r[39]}}, inj_mul_r}) + 48'sd4194304;
    wire signed [47:0] inj_l     = inj_x_l >>> INJ_SH;
    wire signed [47:0] inj_r     = inj_x_r >>> INJ_SH;

    // ========================================================================
    //  梳状：合并两级 Q15 乘法
    //    K1 = (1-damp)*decay >> 15 ，K2 = damp*decay >> 15
    //    comb_w = (m0*K1 + fsc*K2) >> 15 + xin
    //  位宽：|m0| ≤ 2^23、|K1| ≤ 32112 ⇒ 乘积 ≤ 2^38 ⇒ 40 位精确
    // ========================================================================
    wire signed [31:0] k1_x = $signed(oned)  * $signed(decay);
    wire signed [31:0] k2_x = $signed(damp)  * $signed(decay);
    wire signed [15:0] k1   = k1_x >>> 15;                 // (1-damp)·decay，Q15
    wire signed [15:0] k2   = k2_x >>> 15;                 //  damp·decay，Q15
    wire signed [39:0] p_on  = $signed(m0)  * $signed(k1);  // 24×16 = 40 位
    wire signed [39:0] p_dmp = $signed(fsc) * $signed(k2);
    wire signed [40:0] comb_w_x = $signed({{1{p_on[39]}},  p_on})
                                + $signed({{1{p_dmp[39]}}, p_dmp});
    //  ⚠⚠ 2026-10-28 修"炸"的根因：**不能**把移位直接写在位拼接上
    //     （拼接是无符号的 → >>>15 变逻辑右移 → 负反馈变正反馈）。
    //     先复制到 signed wire 再移位，与本文件 fs_new_x 的写法一致。
    wire signed [47:0] comb_w_x48 = $signed({{7{comb_w_x[40]}}, comb_w_x});
    wire signed [47:0] comb_rep   = comb_w_x48 >>> 15;
    wire signed [47:0] xin_x      = $signed({{24{xin[AW-1]}}, xin});
    wire signed [47:0] comb_w     = comb_rep + xin_x;

    //  低通状态：fs_new = (m0*(1-damp) + fs*damp) >> 15
    wire signed [AW+15:0] fs_new_p = $signed(m0) * oned + fsc * damp;
    wire signed [47:0]    fs_new_x = $signed({{(48-(AW+16)){fs_new_p[AW+15]}}, fs_new_p});
    wire signed [AW-1:0]  fs_new   = sat24(fs_new_x >>> 15);

    //  16 条梳状之和
    wire signed [47:0] m0_x       = $signed({{24{m0[AW-1]}}, m0});
    wire signed [47:0] comb_sum_n = comb_sum + m0_x;
    wire signed [47:0] comb_sum_s = comb_sum_n >>> SUM_SH;      // 归一化后再进全通链
    wire signed [AW-1:0] comb_mix = soft24(comb_sum_s);         // 软限幅（正常不触发）

    // ========================================================================
    //  全通（Freeverb）：
    //      out   = m0 - in
    //      write = in + 0.5*m0          ← 用**当前**读出 m0
    // ========================================================================
    //  ⚠ 下标必须钳位：梳状线 li<16 时 li-16 是负数，数组负下标会取到 X 并污染状态。
    wire [1:0]           ap_sel   = (li < 5'd16) ? 2'd0 : (li - 5'd16);
    wire signed [AW-1:0] ap_in_c  = ap_in[ap_sel];
    wire signed [AW:0]   ap_out_p = $signed({m0[AW-1], m0}) - $signed({ap_in_c[AW-1], ap_in_c});
    wire signed [47:0]   ap_out_x = $signed({{(48-(AW+1)){ap_out_p[AW]}}, ap_out_p});
    wire signed [AW-1:0] ap_out   = sat24(ap_out_x);            // 原来是无饱和截断！
    wire signed [47:0]   ap_half  = m0_x >>> 1;                 // 0.5*bufout（算术右移）
    wire signed [47:0]   ap_wsum  = ap_half + $signed({{24{ap_in_c[AW-1]}}, ap_in_c});

    //  出口：wet = ap_out * p_ret >> RET_SH，再过软限幅
    wire signed [47:0]   wet_x    = ($signed({{24{ap_out[AW-1]}}, ap_out})
                                     * $signed({1'b0, p_ret})) >>> RET_SH;
    wire signed [AW-1:0] wet_c    = soft24(wet_x);

    integer i;

`ifdef SIMULATION
    //  仿真专用：BSRAM 没有复位端口，不初始化会读出 X（综合器看不到这一段）。
    //  ⚠ 循环上界必须跟着 rmem 深度走，写死旧值会让新加的段保持 X（整链变 X）。
    initial begin
        for (i = 0; i < 49000; i = i + 1) begin
            rmem[i] <= {AW{1'b0}};
        end
    end
`endif

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= ST_IDLE; li <= 5'd0; ch <= 1'b0;
            waddr <= 16'd0; wdata <= {AW{1'b0}};
            bl <= {AW{1'b0}}; br <= {AW{1'b0}};
            xin <= {AW{1'b0}};
            comb_sum <= 48'sd0; fsc <= {AW{1'b0}};
            ret_l <= {AW{1'b0}}; ret_r <= {AW{1'b0}}; ret_vld <= 1'b0;
            for (i = 0; i < 4; i = i + 1) begin
                ap_in[i] <= {AW{1'b0}};
            end
            for (i = 0; i < 16; i = i + 1) begin
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
                        //  2026-10-22 起：梳状注入 ÷256；2026-10-26 起：四舍五入。
                        //  为什么不是 ÷16/÷32：那时上面①的位宽 bug 还没发现，
                        //  用缩小注入去"躲"削顶，结果湿声只有 −20 dB（混响听不出来）。
                        bl <= sat24(inj_l);
                        br <= sat24(inj_r);
                        ch <= 1'b0; li <= 5'd0;
                        comb_sum <= 48'sd0;
                        st <= ST_RD;
                    end
                end

                ST_RD: begin
                    // 读地址是**组合**的 cur（见 BSRAM 读口），本拍发出、下一拍 rdata 有效
                    st <= ST_ADS;
                end

                // ⚠ 写地址必须在这里锁存，而且必须在换这条线的**同一拍**：
                //   waddr 是寄存器；若放到 ST_WR/ST_CM 才锁，换线后第一拍锁到的
                //   还是上一条线（甚至上一个声道）的 cur。
                ST_ADS: begin
                    waddr <= cur;
                    st    <= ST_WR;
                end

                ST_WR: begin
                    // m0 在本拍有效；装载本线的低通状态与声道注入
                    if (li == 5'd0) xin <= ch ? br : bl;
                    if (li < 5'd16) fsc <= ch ? fs_r[li[3:0]] : fs_l[li[3:0]];
                    st  <= ST_CM;
                end

                ST_CM: begin
                    if (li < 5'd16) begin
                        // ---- 梳状 ----
                        wdata <= sat24(comb_w);
                        comb_sum <= comb_sum_n;
                        if (ch) fs_r[li[3:0]] <= fs_new; else fs_l[li[3:0]] <= fs_new;
                    end else begin
                        // ---- 全通 ----
                        wdata <= sat24(ap_wsum);
                    end

                    // 指针推进（按本声道线长回绕）
                    if (ch) begin
                        ptr_r[li] <= (ptr_r[li] + 1'b1 >= len) ? {SBW{1'b0}} : (ptr_r[li] + 1'b1);
                    end else begin
                        ptr_l[li] <= (ptr_l[li] + 1'b1 >= len) ? {SBW{1'b0}} : (ptr_l[li] + 1'b1);
                    end

                    //  全通链输入传递（同一采样内逐级）：
                    //    li==15：16 条梳状之和 → 第 1 级输入
                    //    li==16/17/18：第 i 级的输出 → 第 i+1 级输入
                    //    li==19：本级输出直接进出口，不需要再存
                    if (li == 5'd15) ap_in[2'd0] <= comb_mix;
                    if (li >= 5'd16 && li <= 5'd18) ap_in[ap_sel + 2'd1] <= ap_out;

                    st <= ST_WB;
                end

                // ---- 写回：st==ST_WB 时写新值 ----
                ST_WB: begin
                    if (li == NL-1) begin
                        if (ch == 1'b0) begin
                            ret_l <= wet_c;
                            ch    <= 1'b1;
                            li    <= 5'd0;
                            comb_sum <= 48'sd0;
                            st    <= ST_RD;
                        end else begin
                            ret_r <= wet_c;
                            ret_vld <= 1'b1;
                            st    <= ST_IDLE;
                        end
                    end else begin
                        li <= li + 5'd1;
                        st <= ST_RD;
                    end
                end

                default: st <= ST_IDLE;
            endcase
        end
    end

`ifdef SIMULATION
    //  ------------------------------------------------------------------
    //  仿真专用统计（综合后不存在）：每帧打印限幅次数与湿声峰值。
    //  frame_stb 在这里只当"帧边界"用，不参与控制。
    //  ------------------------------------------------------------------
    reg [15:0] clip_sum, clip_wet;
    reg [23:0] wet_pk;
    integer    av;
    wire lim_sum_now = (comb_sum_s > LIM_K) || (comb_sum_s < -LIM_K);
    wire lim_wet_now = (wet_x > LIM_K) || (wet_x < -LIM_K);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clip_sum <= 16'd0; clip_wet <= 16'd0; wet_pk <= 24'd0;
        end else begin
            if (lim_sum_now) clip_sum <= clip_sum + 1'b1;
            if (lim_wet_now) clip_wet <= clip_wet + 1'b1;
            av = (ret_l < 0) ? -ret_l : ret_l;
            if (av[23:0] > wet_pk) wet_pk <= av[23:0];
            if (frame_stb) begin
                if (clip_sum != 16'd0 || clip_wet != 16'd0)
                    $display("[fx_reverb] 限幅: 求和 %0d 次 / 湿声 %0d 次, 湿声峰值 %0d (%0.1f dBFS)",
                             clip_sum, clip_wet, wet_pk,
                             (wet_pk > 0) ? (20.0*$log10(wet_pk/8388608.0)) : -999.0);
                clip_sum <= 16'd0; clip_wet <= 16'd0; wet_pk <= 24'd0;
            end
        end
    end
`endif

endmodule

`default_nettype wire
