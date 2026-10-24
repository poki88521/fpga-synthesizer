# baseline_C —— 20261024 14:21 位流（显示 + ROM 地址打拍 + 颤音深度×2 + 滤波器包络调制）

## 与 baseline_A 的差别

1. ch_lfo.v：颤音深度 vib_p >>> 6 → >>> 5（±0.5 → ±1.0 半音）
2. voice_mono.v：新增滤波器包络调制（filter_env_depth 的第一版）
   f_coeff_eff = f_coeff - ((32767 - env) >> 4)，打一拍后送 SVF
   → 起音亮、衰减后暗（只减不加，不会越过 SVF 稳定上限）

## 时序

- Setup/Hold 违例 0 / 0，TNS 全 0
- Fmax：音频 49.183 MHz（约束 49.152，**余量仅 +0.06%**）、像素 83.2 MHz、clk50 149.5、clk12288 371.1
- 最差路径：+0.013 ns，落在 soft_limiter 的 3 级流水内部
  （u_master/g_lim.u_lim/mant_d2_3_s0/Q → recip_d3_15_s0/D）
  ⚠ 这是新的"贴线"路径，下次加逻辑前应先修它
- P&R：布局 7m59s + 布线 7m47s = 16m16s（历次最快）

## 位流

full_system.fs 38.72 MB，10-24 14:21:11

## 上板验证要点（拿到板子后，与 baseline_A 对比）

1. 声音/音高 262 Hz（rom_addr 打拍没搞坏波表）
2. LCD 有波形
3. 效果器开着不炸
4. CC1 调制轮 → 颤音（±1 半音）
5. 音色明暗：起音亮、尾音暗（新的滤波器包络调制）
6. bend 命令 → 音高连续滑动（弯音链路已通，白捡验证）