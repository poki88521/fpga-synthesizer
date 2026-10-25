# baseline_D —— 20261024 18:14 位流（四合一）

## 相对 baseline_C 的改动

1. `soft_limiter.v`：3 级 → **4 级流水**（拆开 `mant_d2 → recip_d3` 这条 20.255 ns 路径）+ 新寄存器补复位
2. `voice_alloc.v`：力度线性 → **平方曲线**（vel=127 响度不变，轻按更柔）
3. `tb_limiter.v`：期望延迟 3→4 拍（跟随流水改动）

## 时序

- Setup/Hold 违例 **0 / 0**
- Fmax：音频 **49.251 MHz**（约束 49.152）、像素 75.0、clk50 166.5、clk12288 430.2
- 最差路径：**+0.041 ns**，`voice_fetch` 的 `it_r → apply_ratio 乘法器`（soft_limiter 已离开最差列表）
- P&R：布局 8m57s + 布线 22m07s = 31m39s

## 位流

`full_system.fs` 38.94 MB，10-24 18:14:35
