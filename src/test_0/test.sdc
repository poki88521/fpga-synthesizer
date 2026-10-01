// 定义主时钟：50 MHz，周期 20 ns
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

//如果工具仍报 TA1132（tck_pad_i 未创建），可取消下面两行注释
//create_clock -name tck_pad_i -period 100
//set_false_path -from [get_clocks tck_pad_i]