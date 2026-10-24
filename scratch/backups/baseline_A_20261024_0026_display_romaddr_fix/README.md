# baseline_A —— 20261024 00:26 位流（显示 + ROM 地址打拍，时序零违例）

## 这是什么

- 分支 develop，改动包含：800x480 LCD 可视化（rtl/vis/）+ wave_fetch 的 rom_addr 打拍
- 时序：**Setup/Hold 违例 0 / 0**，最差 slack **+0.857 ns**
- Fmax：音频域 **51.314 MHz**（约束 49.152）、像素域 105.6 MHz（约束 35）
- 位流：full_system.fs，38.46 MB，10-24 00:26:45
- P&R 耗时：布局 9m22s + 布线 30m12s = 40m03s

## ⚠ 尚未上板验证

这一版**没有在板子上跑过**。周日上板时按这个顺序验：
1. 声音正常、音高 262 Hz（确认 rom_addr 打拍没搞坏波表取数）
2. LCD 上有波形（确认显示集成）
3. 效果器开着不炸（延续 10-23 的混响修复）

## 文件说明

| 文件 | 用途 |
|---|---|
| full_system.fs | 位流，烧录用 |
| full_system.tr | 时序报告（违例/Fmax/最差路径） |
| full_system.rpt.txt | P&R 各阶段耗时与资源 |
| full_system.timing_paths | 最差路径明细 |
| full_system.cst / .sdc / .gprj | 当时的约束与工程文件（便于复现） |

## 烧录提醒

Gowin 每次综合都会**原地覆盖** impl/pnr/full_system.fs。
所以以后重新综合前，先把新位流另存到本目录，否则这一版会被覆盖掉。