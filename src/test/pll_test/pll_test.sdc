create_clock -name clk    -period 20     -waveform {0 10}     [get_ports {clk}]
create_clock -name clk_in -period 40.690 -waveform {0 20.345} [get_ports {clk_in}]
