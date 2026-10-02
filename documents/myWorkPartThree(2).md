# 模块三 混合部分设计

## 设计前提

    板卡：Sipeed Tang Mega 138K Pro Dock，FPGA 为 GW5AST-LV138FPG676AC1/I0（Arora V，22nm）。

    一、可用资源
        LUT4 / FF ....... 138240 / 138240
        BSRAM ........... 6120 Kbit，340 块，单块 18 Kbit，最高时钟 380 MHz
        DSP ............. 298 个，每个含 27x18 乘法器 M0、12x12 乘法器 M1、前加器、48-bit 四输入 ALU
        PLL ............. 12 个

        24-bit 音频乘 16-bit 系数，用 M0 一次乘法即可；M0 的输出可直接送入同一个 DSP 的
        48-bit ALU 做累加（Accumulator 模式），所以本模块的多路求和全部走这条路，不搭加法树。

    二、音频链路与引脚
        FPGA ──BCK/WS/DIN── PT8211-S（16-bit R-2R DAC）── 低通 ── XPT4809 耳放 ── 耳机 / 扬声器

        HP_BCK = E22    位时钟， = 32 x f_s
        HP_WS  = F24    声道选择， = f_s
        HP_DIN = G24    串行数据
        PA_EN  = H17    耳放使能，高电平有效

        PT8211：16-bit，LSBJ（Japanese，低位对齐）格式，二进制补码，MSB 先出，
                BCK 上升沿被采样，每声道 16 个 BCK，所以 BCLK = 32 x f_s；
                BCK 最高 18.4 MHz，WS 最高 384 kHz；输入超过 16 bit 时只取前 16 位；不需要 MCLK。

        耳机与扬声器的切换由板上 BL1551 模拟开关按 HP_DETL 自动完成，FPGA 侧不需要控制信号。

    三、时钟
        MS5351M 输出 12.288 MHz ── USR_CLK_IN（引脚 N22）── FPGA PLL
        PLL：IDIV = 1，FBDIV = 2，MDIV = 64，ODIV0 = 32
             Fpfd = 12.288 MHz，Fvco = 1572.864 MHz，CLKOUT0 = 49.152 MHz = f_clk
        分频链：÷1024 → 48.000 kHz（采样节拍）；÷32 → 1.536 MHz（BCLK）；
                ÷1024 → 48.000 kHz（WS）；÷128 → 384 kHz（I2C 主控）
        T_s = 20.8333 us，每采样 1024 拍，单一主时钟域。

    四、定点格式
        音频样本 .... Q1.23，24-bit 有符号
        系数 ........ Q1.15，16-bit 有符号
        单个乘积 .... Q2.38，39-bit 有效（40-bit 容器）
        多路累加 .... Q6.38，44-bit 有效（用 DSP 的 48-bit ALU 装）
        约定 ........ Q1.15 乘法之后必须算术右移 15 位归一化，否则增益差 2^15

    五、通用归一化加饱和单元（全模块复用）
        目标：把 48-bit 累加结果安全压回 24-bit。
        输入：acc（48-bit 有符号）
        输出：y（24-bit Q1.23，已饱和）
        操作：1. 可选四舍五入：acc = acc + 2^14（在 48-bit 容器里加，不要先截断）。
              2. sh = acc >>> 15，取 v = sh[28:0]。
              3. 溢出判断：ovf = (v[28:24] != {5{v[23]}})。
              4. ovf 为 0 时 y = v[23:0]；为 1 时按 v[28] 判正负，
                 正溢出给 0x7FFFFF，负溢出给 0x800000。

    六、复位与初始化
        复位时把所有 BSRAM 写指针清零、滤波器状态寄存器清零、LFSR 置非零初值，
        包络与增益平滑器置于静音端；否则上电会有残留噪声与爆音。

## 该块总体分为四个部分

    1.效果发送总线（Summing Bus）
    2.效果器运算（差分方程）
    3.主混音求和（Main Mix）
    4.主输出处理（Master Output）

## 下面是四个部分的分步总览

### 1.效果发送总线

    该部分共分为五步，分别是：发送量归一化（准备系数），时分复用乘法（维度扩展），
    串行累加（卷积和），归一化与饱和（降维输出），TDM 时序控制（FPGA 架构核心）。

    第一步： 目标：把来自通道状态表的 7-bit 整数发送量，转换为可参与 DSP 乘法的 Q1.15 定点小数。
                输入：SendRev_i, SendCho_i, SendDel_i（7-bit，0 ~ 127）
                输出：SendRev_Q15, SendCho_Q15, SendDel_Q15（16-bit Q1.15）
            操作:1. 7-bit 无符号数扩展为 16-bit（高位补 0）。
                2. 左移 8 位，使范围落在 0x0000 ~ 0x7F00，即 0.0 ~ 0.9922。
                3. 打一拍寄存，与音频数据对齐。

    第二步： 目标：把 24-bit 音频乘以归一化后的发送系数。
                输入：ChL_i, ChR_i（24-bit Q1.23），SendXX_Q15（16-bit Q1.15）
                输出：乘积流（40-bit，Q2.38）
            操作:1. 用 DSP 的 M0。操作数 A 取声道数据符号扩展至 27 位，操作数 B 取发送系数扩展至 18 位。
                2. 每个采样周期内用同一个乘法器按 TDM 依次乘完 6 条总线 x N 个声部：
                   先 SendRev_L_0 … SendRev_L_N-1、SendRev_R_0 …，再切 SendCho_、SendDel_。
                3. 用 2 个 DSP 分左右声道并行累加，周期数减半。
            说明：N = 32 声部时 6 x 32 x 2 = 384 次乘法/采样，若并行需要 384 个乘法器，
                  已超过全片 298 个 DSP，所以必须用 TDM。

    第三步： 目标：把每条总线上 N 个声部的乘积加起来。
                输入：乘积流（40-bit，Q2.38）
                输出：bus_acc（48-bit）
            操作:1. 用 DSP 自带的 48-bit ALU 做累加（ALU 输出反馈到输入，即 Accumulator 模式）。
                   不搭加法树：TDM 累加本身就是串行累加，靠时钟拍数而非组合逻辑深度。
                2. 位宽：|Σ| ≤ 32 x 2^38 = 2^43，44-bit 有符号足够。
                3. 累加结束后走第五节统一单元：>>>15，判 v[28:24] 与 v[23]，饱和到 24-bit。
            周期预算（1024 拍/采样，2 个 DSP）：
                发送总线 6 x 32 = 192 拍/声道 ...... 18.8%
                主混音干路 32 拍/声道 .............. 3.1%
                主音量 1 拍 ........................ 0.1%
                合计 225 拍 ........................ 约 22%
                N = 16 时减半到约 11%。

    第四步： 目标：把累加结果压回 24-bit，送给效果器运算。
                输入：bus_acc（48-bit）
                输出：BusRev_L/R, BusCho_L/R, BusDel_L/R（24-bit Q1.23）
            操作:1. 可选四舍五入：bus_acc + 2^14。
                2. >>>15 归一化，得 v = sh[28:0]。
                3. 溢出判断 ovf = (v[28:24] != {5{v[23]}})，饱和到 24-bit。
                4. 在累加结束与饱和之间插一拍寄存器。

    第五步： 目标：在 1024 拍/采样内算完 6 条总线并产生同步节拍。
                输入：所有声部数据、发送量
                输出：控制信号、地址、写使能、sample_stb
            操作:1. 状态机：IDLE → SEND_REV → SEND_CHO → SEND_DEL → MIX_DRY → MIX_MASTER，
                   每条总线 32 拍，L/R 两个 DSP 同步推进。
                2. 全模块必须在 T_s = 20.8333 us 内写完并送入 BSRAM 或寄存器。
                3. 算完产生一拍的 sample_stb 脉冲，供整个音频域对齐。
                4. 声部数参数化：N_VOICE = 16 / 32，地址计数器用 clog2(N_VOICE) 位。

### 2.效果器运算

    该部分共分为六步，分别是：接口与数据流约定，混响，合唱，延迟，效果返回混合，参数平滑。

    总则：
        1. 三条效果器全部挂在并行湿路上，干信号不经过效果器，干路额外延迟为零。
        2. 每条效果器自己乘一次返回电平 xxx_return，第五步只求和、不再重复乘。
        3. 延时线用 BSRAM 的 Semi Dual Port 模式（一写一读、独立时钟），读模式用 Pipeline。

    第一步： 目标：定义效果器的输入输出边界与定点格式。
                输入：BusRev_L/R, BusCho_L/R, BusDel_L/R（24-bit Q1.23）
                输出：RevOut_L/R, ChoOut_L/R, DelOut_L/R（24-bit Q1.23）
                参数：reverb_size、reverb_decay、reverb_damping、reverb_pre_delay、
                      chorus_rate、chorus_depth、chorus_mix、delay_time、delay_feedback、delay_mix
            操作:1. 参数由控制模块（MIDI 或触摸）经寄存器写入，在控制率更新，
                   先经第六步平滑，再写成 Q1.15 供音频域使用。
                2. n 为当前采样点，z^-1 由 BSRAM 地址偏移或寄存器实现。
                3. 本部分所有乘法结果都要 >>>15 归一化。

    第二步： 目标：实现混响（Schroeder / Freeverb 结构），分四小步。
            2.1 预延迟：
                目标：模拟房间尺寸，在直达声后留一段空白。
                输入：x[n]        输出：x_pre[n]
                公式：x_pre[n] = x[n - D_pre]
                操作：D_pre 取 10 ~ 100 ms（100 ms @48 kHz = 4800 点），纯延迟，无乘法运算。
            2.2 并联梳状滤波器加环路阻尼：
                目标：产生密集回声，是混响的核心，也是 BSRAM 与乘法器消耗最多的地方。
                输入：x_pre[n]    输出：8 条梳状输出之和
                公式：y_comb[n] = x_pre[n] + g_decay * y_damp[n - D_comb]
                      y_damp[n] = (1 - d) * y_comb[n] + d * y_damp[n - 1]
                操作：1. 并联 8 条。D_comb 按 f_s = 48 kHz 从 Freeverb 的 44.1 kHz tuning 换算
                          （系数 1.08844），取 1215、1293、1390、1476、1548、1623、1695、1760 点。
                      2. g_decay 由 reverb_decay 映射，d 由 reverb_damping 映射，都限制在 0 ~ 0.98。
                      3. 阻尼是一阶低通，放在反馈环内，用于模拟高频衰减；含乘法，必须 >>>15。
                      4. 8 条输出求和，位宽扩到 27-bit（24 + ceil(log2 8)），再饱和回 24-bit。
            2.3 串联全通滤波器：
                目标：进一步扩散，让混响尾音平滑。
                公式：y_ap[n] = -g_ap * x_in[n] + x_in[n - D_ap] + g_ap * y_ap[n - D_ap]
                操作：串联 2 个，g_ap 取 0.5（Q1.15 = 16384），D_ap 取 605、480、371、245 点；
                      含乘法，必须 >>>15。
            2.4 混响输出：
                公式：RevOut_L = sat24( (y_apL * reverb_return) >>> 15 )
                操作：左右声道各一套，右声道各延迟再加 25 点做立体声展宽。

    第三步： 目标：实现合唱，分三小步。
            3.1 LFO 生成：
                公式：LFO[n] = sin( 2 * pi * (chorus_rate / f_s) * n )
                操作：用 1024 点正弦表加相位累加器，频率字 FTW = round(chorus_rate / f_s * 2^32)，
                      输出 Q1.15 正弦波；chorus_rate 取 0.1 ~ 5 Hz。
            3.2 调制延迟加线性插值：
                公式：D_mod[n] = D_base + chorus_depth * LFO[n]        （单位采样点，含小数 frac）
                      x_delayed[n] = (1 - frac) * x[n-k] + frac * x[n-k-1]，k = floor(D_mod)
                                   = x[n-k] + frac * ( x[n-k-1] - x[n-k] )
                操作：D_base 取 15 ~ 25 ms（20 ms @48 kHz = 960 点），chorus_depth 不超过 5 ms（240 点）；
                      按 a + frac*(b-a) 的写法只要 1 个乘法器和 2 个加法器；
                      立体声两声道用反相 LFO。
            3.3 干湿混合与输出：
                公式：y_mix[n] = sat24( ( (1 - chorus_mix) * x[n] + chorus_mix * x_delayed[n] ) >>> 15 )
                      ChoOut   = sat24( (y_mix * chorus_return) >>> 15 )

    第四步： 目标：实现延迟（回声），分三小步。
            4.1 延迟读取：
                公式：x_del[n] = x[n - D_delay]，D_delay = round(delay_time * f_s)
                操作：1 s 立体声 @48 kHz 需 48000 x 24 x 2 = 2304000 bit，按 16 Kbit 模式
                      折算 141 块 BSRAM，占 340 块的 41%；建议最大延时限到 500 ms（71 块，21%）。
                      地址 = 环形写指针 + 偏移。
            4.2 反馈运算：
                公式：y_fb[n] = x[n] + sat24( (delay_feedback * x_del[n]) >>> 15 )
                操作：反馈系数必须小于 1，Q1.15 建议不超过 32000（约 0.977），否则自激。
            4.3 干湿混合与输出：
                公式：y_mix[n] = ( (1 - delay_mix) * x[n] + delay_mix * y_fb[n] ) >>> 15
                      DelOut   = sat24( (y_mix * delay_return) >>> 15 )

    第五步： 目标：把三条湿信号汇总成一条立体声湿总线，送往主混音求和。
                输入：RevOut_L/R, ChoOut_L/R, DelOut_L/R（24-bit Q1.23）
                输出：FxRet_L, FxRet_R（24-bit Q1.23）
            操作:1. 相加：FxRet_L = RevOut_L + ChoOut_L + DelOut_L（右声道同理）。
                2. 中间取 26-bit（24 + ceil(log2 3) = 26），先符号扩展再相加，避免溢出。
                3. 饱和回 24-bit，加法后打一拍，与干信号对齐。
                4. TEST_MODE 有效时，本步输出强制为 0（测试模式不用效果）。

    第六步： 目标：消除参数突变造成的拉链噪声（zipper noise），并提供复位初值。
                输入：vol_i、pan_i、SendXX_i 及各效果参数的目标值
                输出：平滑后的 Q1.15 系数
            操作:1. 一阶低通：p[n] = p[n-1] + alpha * (p_target - p[n-1])，alpha 取 2^-8 ~ 2^-12。
                2. 每个采样周期只更新 1/N 个声部的参数（轮转），保证单周期工作量恒定。
                3. note on / note off 走各自的 ADSR 状态机，不走这条慢速平滑。
                4. 复位时所有平滑器置 0，所有延时线写指针清零，反馈寄存器清零。

### 3.主混音求和（Main Mix）

    该部分共分为四步，分别是：声像与通道音量（并行乘法），干信号串行累加，
    干湿比例混合（通道加效果返回），饱和输出。

    第一步： 目标：对每个声部的干信号应用通道音量与声像系数，生成左右分量。
                输入：ChL_i, ChR_i（24-bit Q1.23），vol_i, pan_i（16-bit Q1.15）
                输出：DryL_i, DryR_i（40-bit，Q2.38）
            操作:1. 等功率声像：
                       theta_i = (pan_i + 1) / 2 * pi/2
                       gL_i = vol_i * cos(theta_i)
                       gR_i = vol_i * sin(theta_i)
                   中心点（pan = 0）时 gL = gR = 0.7071，即 -3 dB。
                2. DryL_i = ChL_i * gL_i，DryR_i = ChR_i * gR_i，24 x 16 得 40-bit，保留全精度。
                3. cos / sin 用 1024 点正弦表加象限映射，按 pan 高 10 位查表；
                   gL / gR 在控制率预算好存寄存器，不占采样周期。

    第二步： 目标：把 N 个声部的干信号分量分别求和。
                输入：DryL_i, DryR_i（40-bit）
                输出：DryL_24, DryR_24（24-bit Q1.23）
            操作:1. 与第一部分第三步一致：用 2 个 DSP 在 48-bit ALU 里 TDM 累加 N 个乘积，不搭加法树。
                2. 累加后 >>>15 并饱和到 24-bit。

    第三步： 目标：把通道求和（干）与效果返回（湿）按干湿比例混合。
                输入：DryL_24, DryR_24, FxRet_L, FxRet_R（24-bit）
                输出：MixL, MixR（26-bit）
            操作:1. MixL = sat26( (DryL_24 * master_dry) >>> 15 ) + sat26( (FxRet_L * master_wet) >>> 15 )
                   右声道同理，两个乘法都要 >>>15。
                2. master_dry 与 master_wet 是互补系数，默认各 0.7071（-3 dB），保证干湿切换时不跳电平。
                3. 湿信号符号扩展到 26-bit 再相加。
                4. 结果保留 25 ~ 26 bit，送第四步。

    第四步： 目标：把混合结果压回 24-bit，送主输出处理。
                输入：MixL, MixR（26-bit）
                输出：MainL, MainR（24-bit Q1.23）
            操作:1. 此时是 25-bit 压到 24-bit，判据为 v[24] 是否等于 v[23]。
                2. 饱和：正溢出给 0x7FFFFF，负溢出给 0x800000。

### 4.主输出处理（Master Output）

    该部分共分为六步，分别是：主音量与静音，软限幅，直流去除（可选），
    抖动与位深转换，PT8211 串行化，输出寄存与功放使能时序。

    第一步： 目标：应用主音量并做静音控制。
                输入：MainL, MainR（24-bit Q1.23），G_master（16-bit Q1.15），mute（1-bit）
                输出：VolL, VolR（24-bit）
            操作:1. 24 x 16 乘法（1 个 M0）：VolL = sat24( (MainL * G_master) >>> 15 )，右声道同理。
                2. 主音量是 14-bit（0 ~ 16383），G = V / 16383，量化为 Q1.15 近似等于 V 左移 1 位，
                   即 G_Q15 = V << 1，最大 32766（0.99994），误差小于 0.006%。
                3. mute 有效时 VolL / VolR 置 0；静音切换要经慢速平滑（约 10 ms 淡出），
                   不要硬切，否则会有咔哒声。
                4. 打一拍寄存。

    第二步： 目标：软限幅，防止硬截断产生刺耳爆音。
                输入：VolL, VolR（24-bit）
                输出：LimL, LimR（24-bit）
            操作:1. 包络检测：Env[n] = max(|VolL|, |VolR|)。
                2. 目标增益：Env 不超过 Threshold 时 G_target = 1.0；否则 G_target = Threshold / Env。
                   Threshold 是 24-bit 幅度阈值，例如 0x600000 约等于 -2.5 dBFS。
                   Threshold / Env 用 256 项倒数 LUT 加线性插值，Env 取前 8 位做表索引。
                3. 增益平滑：G_target 小于 G_limit[n-1] 时立即响应（Attack 约等于 0）；
                   否则 G_limit[n] = G_limit[n-1] + Release * (G_target - G_limit[n-1])。
                   G_limit 的复位初值为 1.0。
                4. LimL = sat24( (VolL * G_limit) >>> 15 )，右声道同理。
                5. 打一拍寄存。

    第三步（可选）： 目标：去除直流偏置，避免后级功放偏置。
                输入：LimL, LimR（24-bit）
                输出：DcL, DcR（24-bit）
                公式：y[n] = x[n] - x[n-1] + a * y[n-1]，a = 0.995
            操作:1. Q1.15 表示为 round(0.995 * 32768) = 32604 = 0x7F5C。
                2. 截止频率约 (1 - a) * f_s / (2 * pi) = 38.2 Hz，合理。
                3. 每声道 1 个乘法器、2 个加法器、1 个延迟寄存器；乘法后 >>>15。

    第四步： 目标：在把 24-bit 截断成 16-bit 之前加抖动，改善量化失真。
                输入：DcL, DcR（24-bit）
                输出：y16L, y16R（16-bit）
            操作:1. 板载 DAC 是 16-bit，24-bit 到 16-bit 是有损截断，必须加抖动。
                2. 两个独立 32-bit 最大长度 LFSR（抽头 32、22、2、1），
                   初值必须非零且两个不同（LFSR 全零会锁死）。取低 16 位相减：
                       diff = signed({1'b0, lfsr1[15:0]}) - signed({1'b0, lfsr2[15:0]})
                       tpdf = diff >>> 8
                   diff 范围 -65535 ~ 65535，右移 8 位后落在 -256 ~ 255；
                   16-bit 的 1 LSB 相当于 24-bit 域的 2^8 = 256，即 ±1 LSB 的三角分布（TPDF）。
                3. y24 = sat24( DcL + tpdf )，然后 y16 = y24[23:8]。

    第五步： 目标：把 16-bit 样本装配成 PT8211 需要的 LSBJ 帧，输出到 DAC。
                输入：16-bit 样本
                输出：HP_BCK, HP_WS, HP_DIN
            操作:1. 位深 16-bit，格式 LSBJ（Japanese，低位对齐），二进制补码，MSB 先出。
                2. 时序：HP_BCK = BCLK = 32 * f_s = 1.536 MHz（由 f_clk ÷32 得到）
                        HP_WS  = LRCK = f_s = 48.000 kHz（由 f_clk ÷1024 得到）
                        HP_DIN 在 BCK 上升沿被采样，每声道 16 个 BCK。
                3. 用 5-bit 位计数器（0 ~ 31）分帧，0 ~ 15 一个声道、16 ~ 31 另一个声道；
                   数据请求 req 在每帧起始（第 0 拍和第 16 拍）产生，向前级取下一个 16-bit 字。
                4. 输出时钟用普通寄存器输出即可，可选加 IOB 约束让寄存器进 IOB。

    第六步： 目标：输出级寄存、功放使能时序与上电静音，保证上电 / 复位无爆音。
                输入：待输出样本、时钟使能、复位
                输出：HP_BCK / HP_WS / HP_DIN / PA_EN
            操作:1. 在移位寄存器与 IOB 之间插一级寄存器，满足建立 / 保持时间。
                2. 复位期间或时钟未稳定时：HP_DIN 保持 0（输出静音码），PA_EN 保持 0（功放关断）。
                3. 上电顺序：PLL 锁定 → 释放复位 → 输出从 0 缓慢升到正常电平（软启动约 10 ms）
                   → 最后拉高 PA_EN 开功放；复位 / 关机顺序相反。避免开关机爆音。
                4. 测试模式配合：TEST_MODE 有效时效果返回按 0 处理、限幅阈值设为 1.0（固定增益），
                   便于用频谱仪数谱峰；此时输出不经过任何动态增益。
                5. 本部分对干路只增加不超过 1 个 T_s = 20.833 us 的延迟（不含 PT8211 内部群延迟），
                   满足赛题 ≤5 ms 的总延迟要求。
                6. 目标时钟 49.152 MHz，收敛情况以 Gowin IDE 的静态时序报告为准。
