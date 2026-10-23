//============================================================================
//  vis_standalone.sdc
//============================================================================
create_clock -name clk50 -period 20.000 -waveform {0 10.000} [get_ports {clk50}]

set_false_path -to [get_ports {lcd_r[*]}]
set_false_path -to [get_ports {lcd_g[*]}]
set_false_path -to [get_ports {lcd_b[*]}]
set_false_path -to [get_ports {lcd_en}]
set_false_path -to [get_ports {heartbeat}]

//  ⚠ 本工程内 vis_audio 的 clk_sys 就是 clk50，像素域是 PLL 出的 35 MHz，
//    两者异步；vis_audio 内部对翻转位做了 2 级同步，属异步安全结构。
