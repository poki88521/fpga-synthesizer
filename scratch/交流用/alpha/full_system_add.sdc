//============================================================================
//  追加到 full_system.sdc 末尾 —— 可视化相关
//============================================================================

//  ---- LCD 输出：像素数据在 35 MHz 下 ~28.6 ns 一拍，面板很宽容 ----
//       不设 output delay（官方例程也没有），只把到引脚的最后一跳放开，
//       避免工具为了收敛 IO 时序去做无意义的布局分散。
set_false_path -to [get_ports {lcd_r[*]}]
set_false_path -to [get_ports {lcd_g[*]}]
set_false_path -to [get_ports {lcd_b[*]}]
set_false_path -to [get_ports {lcd_en}]

//  ---- ⚠ 跨时钟域（音频 49.152 MHz ↔ 像素 35 MHz）----
//      vis_audio 内部对翻转位做了 2 级同步，属异步安全结构。
//      理论上应加：
//          set_clock_groups -asynchronous -group {<音频时钟>} -group {<像素时钟>}
//      但 **PLL 输出时钟的名字是工具自动生成的**，写错会被 SDC 解析器拒绝。
//      做法：先跑一次 P&R，在 impl/pnr/full_system.tr 里查两个 PLL 输出时钟的
//      实际名字，再填进去。**不加也能跑**（只会多几条 CDC 路径的违例报告，
//      不影响实际功能，因为已经是同步器结构）。
