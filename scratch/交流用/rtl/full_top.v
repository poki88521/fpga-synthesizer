//============================================================================
//  full_top —— 模块三**完整链路**顶层（可上板）
//
//  与 `mix_top` 的区别：`mix_top` 是"最小闭环"（测试音 → 主输出链 → I2S），
//  只用来验证 DAC 通路；**本模块把模块三的完整链路全部接起来**：
//
//      voice_slot_seq ──┐
//      test_voice_gen ──┴→ chan_layer → send_bus → fx_top → main_mix
//                                                              │
//                                            master_chain ←────┘
//                                                  │
//                                            pt8211_tx → DAC
//
//  时钟（与 mix_top 相同，两种配置）：
//      USE_PLL = 0  用 clk50（P16 的 50 MHz 直连）→ f_s = 48.828 kHz
//      USE_PLL = 1  用 clk12288（N22 的 24.576 MHz 经 PLL）→ f_s = 48.000 kHz
//                  ⚠ N22 上是 **24.576 MHz**（MS5351 CLK2），不是 12.288
//
//  复位：**只用内部上电复位**（不依赖任何外部引脚，理由见 mix_top.v 的长注释）
//
//  ⚠ 声部来源现状：本模块暂时用 `test_voice_gen`（32 个对数均匀振荡器）作为声部源，
//    因为单声部处理层（DDS/SVF/VCA）由队友负责、尚未完成。
//    接入真实声部时，把 `u_voices` 换成单声部阵列即可 ——
//    它对外只暴露 `aud`（P 路并行 × 24 bit，按 slot 切换），接口不变。
//============================================================================

`default_nettype none

module full_top #(
    parameter integer USE_PLL  = 0,          // 0 = clk50 直连；1 = clk12288 + PLL
    parameter integer P        = 8,          // 并行泳道数
    parameter integer G        = 4,          // 串行组数
    parameter integer NCH      = 16,         // 通道数
    parameter integer STRIDE   = 8,          // 时隙间隔（拍）
    parameter integer PA_DELAY = 22,         // PA_EN 延时 = 2^PA_DELAY 拍
    parameter integer POR_BITS = 22,         // 内部 POR 计数位宽（仿真可改小）
    parameter integer TEST_MODE_DEFAULT = 1, // 1 = 上电即进测试模式（32 谱线，便于现场验证）

    // ===== 集成扩展点（2026-10-08 加；默认 0 = 保持"自检模式"的既有行为）=====
    //  VOICE_SRC   : 0 = 内置 test_voice_gen；1 = 由外部单声部层驱动 ext_aud_in/ext_ch_in/ext_vld
    //  EXT_TABLE   : 0 = 内置示例通道参数；1 = 由外部调度层驱动 ext_volume…ext_send_del
    //  EXT_FXPARAM : 0 = 内置示例效果器/主输出参数；1 = 由外部调度层驱动 ext_reverb_* … ext_master_vol
    parameter integer VOICE_SRC   = 0,
    parameter integer EXT_TABLE   = 0,
    parameter integer EXT_FXPARAM = 0
)(
    input  wire clk50,      // P16：板载 50 MHz
    input  wire clk12288,   // N22：MS5351 CLK2 输出 **24.576 MHz**（USE_PLL=1 时用）
    output wire HP_BCK,     // E22 → PT8211 BCK
    output wire HP_WS,      // F24 → PT8211 WS
    output wire HP_DIN,     // G24 → PT8211 DIN
    output wire PA_EN,      // H17：功放使能（Pro 板高电平有效）

    // ===== 以下端口仅在对应 EXT_*/VOICE_SRC 参数为 1 时使用（否则可悬空）=====

    // ---- 单声部层 → 通道层（VOICE_SRC=1 时用；位宽与 P 相关）----
    input  wire [P*24-1:0]  ext_aud_in,   // P 路并行干信号（Q1.23），与 slot 同拍有效
    input  wire [P*4-1:0]   ext_ch_in,    // 每路声部所属 MIDI 通道号（0~15 = midi_channel−1）
    input  wire [P-1:0]     ext_vld,      // 每路声部有效

    // ---- 调度层 → 通道状态表（EXT_TABLE=1 时用）----
    input  wire [NCH*7-1:0]  ext_volume,      // 通道音量（7 bit）
    input  wire [NCH*7-1:0]  ext_expression,  // 表情（7 bit）
    input  wire signed [NCH*16-1:0] ext_pan_gL,  // 左增益（Q1.15）
    input  wire signed [NCH*16-1:0] ext_pan_gR,  // 右增益（Q1.15）
    input  wire [NCH*7-1:0]  ext_send_rev,    // 混响发送（7 bit）
    input  wire [NCH*7-1:0]  ext_send_cho,    // 合唱发送（7 bit）
    input  wire [NCH*7-1:0]  ext_send_del,    // 延迟发送（7 bit）

    // ---- 调度层 → 效果参数（EXT_FXPARAM=1 时用；Q1.15 等见 硬件实现.md §六.3）----
    input  wire signed [15:0] ext_reverb_size,  input  wire signed [15:0] ext_reverb_decay,
    input  wire signed [15:0] ext_reverb_damping, input  wire [15:0] ext_reverb_pre_delay,
    input  wire signed [15:0] ext_reverb_return,
    input  wire [15:0] ext_chorus_rate,  input  wire signed [15:0] ext_chorus_depth,
    input  wire signed [15:0] ext_chorus_mix, input  wire signed [15:0] ext_chorus_return,
    input  wire [15:0] ext_delay_time,   input  wire signed [15:0] ext_delay_feedback,
    input  wire signed [15:0] ext_delay_mix, input  wire signed [15:0] ext_delay_return,

    // ---- 调度层 → 主输出（EXT_FXPARAM=1 时用）----
    input  wire [13:0]      ext_master_vol,   // SysEx 主音量 0~16383
    input  wire             ext_mute,         // 1 = 静音
    input  wire             ext_test_mode     // 运行时测试模式（替代上电常量）
);

    // ============================================================
    // 1. 时钟
    // ============================================================
    wire clk_sys;
    wire pll_lock;

    generate
        if (USE_PLL != 0) begin : g_pll
            //  PLL 内部自带"上电等待再释放 RESET"，防止锁到 MS5351 的默认 16 MHz
            pll_49m u_pll (
                .clkin    (clk12288),
                .reset_in (1'b0),
                .clkout0  (clk_sys),
                .lock     (pll_lock)
            );
        end else begin : g_nopll
            assign clk_sys  = clk50;
            assign pll_lock = 1'b1;
        end
    endgenerate

    //  ⚠ `generate` 的**嵌套作用域里绑定不到参数**（iverilog 报 Unable to bind wire/reg
    //     `VOICE_SRC` in `genblk2[0]`），所以判据必须在**模块级**算成 localparam 再用。
    //     这是本项目第二次踩这个坑（第一次是 mix_top 的 USE_PLL）。
    localparam integer USE_EXT_VOICE  = (VOICE_SRC   != 0) ? 1 : 0;
    localparam integer USE_EXT_CH     = USE_EXT_VOICE;
    localparam integer USE_EXT_TABLE  = (EXT_TABLE   != 0) ? 1 : 0;
    localparam integer USE_EXT_FXPAR  = (EXT_FXPARAM != 0) ? 1 : 0;

    // ============================================================
    // 2. 内部上电复位（不用外部引脚，X 安全）
    // ============================================================
    reg [POR_BITS-1:0] por_cnt;
    initial por_cnt = {POR_BITS{1'b0}};

    always @(posedge clk_sys) begin
        if (por_cnt != {POR_BITS{1'b0}}) begin
            if (por_cnt == {{(POR_BITS-1){1'b0}}, 1'b1})
                por_cnt <= {POR_BITS{1'b0}};         // 递减到 1 → 落到 0
            else
                por_cnt <= por_cnt - 1'b1;
        end else begin
            por_cnt <= {POR_BITS{1'b0}};             // 到 0 或不确定态 → 钉在 0
        end
    end

    wire por_rst_n = (por_cnt == {POR_BITS{1'b0}});

    // 三级同步器（显式判等，X 安全；判据用 && 连接各自比较）
    reg [2:0] rst_sync;
    initial rst_sync = 3'b000;
    wire rst_all_hi = (por_rst_n == 1'b1) && (pll_lock == 1'b1);

    always @(posedge clk_sys) begin
        if (rst_all_hi) rst_sync <= {rst_sync[1:0], 1'b1};
        else            rst_sync <= 3'b000;
    end
    wire sys_rst_n = (rst_sync == 3'b111);

    // ============================================================
    // 2.5 测试模式寄存器（附三「现场验证必需」）
    //  置 1 时：三个效果返回全置零 + 限幅固定增益 + 32 个对数均匀振荡器
    //  上电默认取 TEST_MODE_DEFAULT（便于直接烧板数谱峰）；
    //  真实系统里由调度层（上位机 / SysEx）写这个寄存器。
    //  ⚠ 必须声明在 fx_top / master_chain 实例之前（Verilog 要求先声明后使用）
    // ============================================================
    reg  test_mode_r;
    initial test_mode_r = (TEST_MODE_DEFAULT != 0) ? 1'b1 : 1'b0;
    wire test_mode = test_mode_r;

    // ============================================================
    // 3. 采样节拍 + I2S 发送
    // ============================================================
    wire        sample_stb;          // 每采样一拍的节拍（同时是 I2S 帧边界）
    wire [15:0] sample_l, sample_r;

    pt8211_tx #(
        .DIV_BIT   (32),
        .WS_INVERT (1)               // 手册：WS 高 = 左声道（已上板实测确认）
    ) u_tx (
        .clk        (clk_sys),
        .rst_n      (sys_rst_n),
        .sample_l   (sample_l),
        .sample_r   (sample_r),
        .sample_stb (sample_stb),
        .bclk       (HP_BCK),
        .ws         (HP_WS),
        .din        (HP_DIN)
    );

    // ============================================================
    // 4. 声部时隙时序器（产生 slot / slot_vld）
    // ============================================================
    wire [1:0] slot;
    wire       slot_vld;
    wire [1:0] phase;
    wire       frame_done;

    voice_slot_seq #(
        .G(G), .N_CYC(1024), .STRIDE(STRIDE), .SW(2)
    ) u_seq (
        .clk(clk_sys), .rst_n(sys_rst_n), .frame_stb(sample_stb),
        .slot(slot), .slot_vld(slot_vld), .phase(phase), .frame_done(frame_done)
    );

    // ============================================================
    // 5. 声部源（暂用测试模式声源；接真实声部时替换本例化）
    // ============================================================
    wire [P*24-1:0] voice_aud;

    wire [P*24-1:0] test_aud;
    test_voice_gen #(.P(P), .N(P*G), .AW(24),
                     .FS_HZ((USE_PLL != 0) ? 48000 : 48828)) u_voices (
        .clk(clk_sys), .rst_n(sys_rst_n), .en(sample_stb),
        .slot(slot), .aud(test_aud)
    );
    //  集成模式下把声部源让给外部单声部层
    assign voice_aud = USE_EXT_VOICE ? ext_aud_in : test_aud;

    // 声部固定挂在通道 0..P-1（8 条泳道 → 通道 0~7），全部有效
    wire [P-1:0]    lane_vld;
    wire [P*4-1:0]  lane_ch;
    assign lane_vld = USE_EXT_VOICE ? ext_vld : {P{1'b1}};
    genvar gi;
    generate
        for (gi = 0; gi < P; gi = gi + 1)
            assign lane_ch[gi*4 +: 4] = USE_EXT_CH ? ext_ch_in[gi*4 +: 4] : gi[3:0];
    endgenerate

    // ============================================================
    // 6. 通道状态表（示例值；真实系统由调度层写入）
    //    测试模式下把声像设成**硬左右交替** → 频谱仪上左右各半谱峰
    // ============================================================
    reg [6:0]               volume     [0:NCH-1];
    reg [6:0]               expression [0:NCH-1];
    reg signed [15:0]       pan_gL     [0:NCH-1];
    reg signed [15:0]       pan_gR     [0:NCH-1];
    reg [6:0]               send_rev   [0:NCH-1];
    reg [6:0]               send_cho   [0:NCH-1];
    reg [6:0]               send_del   [0:NCH-1];

    integer ci;
    initial begin
        for (ci = 0; ci < NCH; ci = ci + 1) begin
            volume    [ci] = 7'd110;
            expression[ci] = 7'd127;
            //  硬左右交替：偶数通道全左，奇数通道全右（Q1.15：32767 = 1.0）
            pan_gL    [ci] = (ci[0] == 1'b0) ? 16'sd32767 : 16'sd0;
            pan_gR    [ci] = (ci[0] == 1'b1) ? 16'sd32767 : 16'sd0;
            send_rev  [ci] = 7'd100;
            send_cho  [ci] = 7'd60;
            send_del  [ci] = 7'd70;
        end
    end

    // 打包成扁平端口
    wire [NCH*7-1:0]        volume_f, expr_f, srev_f, scho_f, sdel_f;
    wire signed [NCH*16-1:0] panL_f, panR_f;

    //  ⚠ 这里的"内置示例值"是**自检用**（测试模式下声像硬左右交替，便于数谱峰）。
    //     真实系统由调度层经 `ext_*` 驱动（`EXT_TABLE=1`），见 §三.十二 接口汇总。
    generate
        for (gi = 0; gi < NCH; gi = gi + 1) begin : g_tbl
            assign volume_f[gi*7  +: 7]  = USE_EXT_TABLE ? ext_volume    [gi*7  +: 7]  : volume    [gi];
            assign expr_f  [gi*7  +: 7]  = USE_EXT_TABLE ? ext_expression[gi*7  +: 7]  : expression[gi];
            assign srev_f  [gi*7  +: 7]  = USE_EXT_TABLE ? ext_send_rev  [gi*7  +: 7]  : send_rev  [gi];
            assign scho_f  [gi*7  +: 7]  = USE_EXT_TABLE ? ext_send_cho  [gi*7  +: 7]  : send_cho  [gi];
            assign sdel_f  [gi*7  +: 7]  = USE_EXT_TABLE ? ext_send_del  [gi*7  +: 7]  : send_del  [gi];
            assign panL_f  [gi*16 +: 16] = USE_EXT_TABLE ? ext_pan_gL    [gi*16 +: 16] : pan_gL    [gi];
            assign panR_f  [gi*16 +: 16] = USE_EXT_TABLE ? ext_pan_gR    [gi*16 +: 16] : pan_gR    [gi];
        end
    endgenerate

    // ============================================================
    // 7. 通道处理层
    // ============================================================
    wire        ch_vld;
    wire [3:0]  ch_addr;
    wire signed [23:0] ch_l, ch_r;
    wire        ch_frame_done;

    chan_layer #(.P(P), .G(G), .AW(24), .CW(4), .NCH(NCH), .SW(2)) u_chan (
        .clk(clk_sys), .rst_n(sys_rst_n), .frame_stb(sample_stb),
        .slot_vld(slot_vld), .slot(slot), .vld(lane_vld),
        .ch_in(lane_ch), .aud_in(voice_aud),
        .volume(volume_f), .expression(expr_f),
        .pan_gL(panL_f), .pan_gR(panR_f),
        .ch_vld(ch_vld), .ch_addr(ch_addr), .ch_l(ch_l), .ch_r(ch_r),
        .frame_done(ch_frame_done)
    );

    // ============================================================
    // 8. 效果发送总线
    // ============================================================
    wire        bus_vld;
    wire signed [23:0] brl, brr, bcl, bcr, bdl, bdr;

    send_bus #(.NCH(NCH), .AW(24)) u_send (
        .clk(clk_sys), .rst_n(sys_rst_n), .frame_stb(sample_stb),
        .ch_vld(ch_vld), .ch_addr(ch_addr), .ch_l(ch_l), .ch_r(ch_r),
        .send_rev(srev_f), .send_cho(scho_f), .send_del(sdel_f),
        .bus_vld(bus_vld),
        .bus_rev_l(brl), .bus_rev_r(brr),
        .bus_cho_l(bcl), .bus_cho_r(bcr),
        .bus_del_l(bdl), .bus_del_r(bdr)
    );

    // ============================================================
    // 9. 效果器运算（三条并行湿路）
    // ============================================================
    wire        fx_vld;
    wire signed [23:0] fx_l, fx_r;

    fx_top #(.REV_EN(1), .CHO_EN(1), .DEL_EN(1), .LAT_MAX(128)) u_fx (
        .clk(clk_sys), .rst_n(sys_rst_n), .frame_stb(sample_stb),
        .test_mode(test_mode),
        .bus_vld(bus_vld),
        .bus_rev_l(brl), .bus_rev_r(brr),
        .bus_cho_l(bcl), .bus_cho_r(bcr),
        .bus_del_l(bdl), .bus_del_r(bdr),
        //  自检模式下用内置示例值；集成模式（EXT_FXPARAM=1）由调度层驱动
        .reverb_size   (USE_EXT_FXPAR ? ext_reverb_size    : 16'sd26000),
        .reverb_decay  (USE_EXT_FXPAR ? ext_reverb_decay   : 16'sd31000),
        .reverb_damping(USE_EXT_FXPAR ? ext_reverb_damping : 16'sd9000),
        .reverb_pre_delay(USE_EXT_FXPAR ? ext_reverb_pre_delay : 16'd0),
        .reverb_return (USE_EXT_FXPAR ? ext_reverb_return  : 16'sd16000),
        .chorus_rate   (USE_EXT_FXPAR ? ext_chorus_rate    : 16'd300),
        .chorus_depth  (USE_EXT_FXPAR ? ext_chorus_depth   : 16'sd20000),
        .chorus_mix    (USE_EXT_FXPAR ? ext_chorus_mix     : 16'sd23000),
        .chorus_return (USE_EXT_FXPAR ? ext_chorus_return  : 16'sd12000),
        .delay_time    (USE_EXT_FXPAR ? ext_delay_time     : 16'd14000),
        .delay_feedback(USE_EXT_FXPAR ? ext_delay_feedback : 16'sd22000),
        .delay_mix     (USE_EXT_FXPAR ? ext_delay_mix      : 16'sd24000),
        .delay_return  (USE_EXT_FXPAR ? ext_delay_return   : 16'sd12000),
        .fx_vld(fx_vld), .fx_l(fx_l), .fx_r(fx_r)
    );

    // ============================================================
    // 10. 主混音求和
    // ============================================================
    wire        mix_vld;
    wire signed [23:0] mx_l, mx_r;

    main_mix #(.NCH(NCH), .AW(24)) u_mix (
        .clk(clk_sys), .rst_n(sys_rst_n), .frame_stb(sample_stb),
        .ch_vld(ch_vld), .ch_addr(ch_addr), .ch_l(ch_l), .ch_r(ch_r),
        .fx_l(fx_l), .fx_r(fx_r), .fx_vld(fx_vld),
        .mix_vld(mix_vld), .main_l(mx_l), .main_r(mx_r)
    );

    // ============================================================
    // 11. 主输出处理
    // ============================================================
    master_chain #(.DC_ENABLE(1), .LIM_ENABLE(1)) u_master (
        .clk(clk_sys), .rst_n(sys_rst_n), .en(sample_stb),
        .l_in(mx_l), .r_in(mx_r),
        .vol      (USE_EXT_FXPAR ? ext_master_vol : 14'd16383),
        .mute     (USE_EXT_FXPAR ? ext_mute       : 1'b0),
        .test_mode(USE_EXT_FXPAR ? ext_test_mode  : test_mode),
        .sample_l(sample_l), .sample_r(sample_r)
    );

    // ============================================================
    // 12. PA_EN 上电时序（计满后**锁存**为 1，不再回 0）
    // ============================================================
    reg [PA_DELAY-1:0] pa_cnt;
    reg                pa_en_r;
    reg [PA_DELAY-1:0] rst_cnt;
    initial rst_cnt = {PA_DELAY{1'b0}};

    always @(posedge clk_sys) begin
        if (sys_rst_n == 1'b0) begin
            rst_cnt <= {PA_DELAY{1'b0}};
            pa_cnt  <= {PA_DELAY{1'b0}};
            pa_en_r <= 1'b0;
        end else if (!pa_en_r) begin
            if (rst_cnt != {PA_DELAY{1'b1}}) rst_cnt <= rst_cnt + 1'b1;
            if (&rst_cnt) begin
                if (&pa_cnt) pa_en_r <= 1'b1;        // 计满 → 锁存为 1
                else         pa_cnt <= pa_cnt + 1'b1;
            end
        end
    end

    assign PA_EN = pa_en_r;

endmodule

`default_nettype wire
