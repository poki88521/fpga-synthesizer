//  tb_render —— 把 wave_render 整屏渲染出来存成 PPM，用于肉眼验收
//  驱动 800×480 光栅，波形用 3 个周期的正弦，频谱柱用 Python 模型算出的
//  C4+E4+G4 和弦柱高（spec_fixed.py 的输出）
`timescale 1ns/1ps
module tb_render;
    reg clk = 0, rst_n = 0;
    always #14.28 clk = ~clk;          // ≈35 MHz

    reg [9:0] x = 0;
    reg [8:0] y = 0;
    reg       vld = 0;
    reg [10:0] y_wave = 11'd240;
    reg [255:0] bars = 256'd0;
    wire [17:0] rgb;

    wave_render #(.AXIS_Y(200)) dut (
        .clk(clk), .rst_n(rst_n),
        .x(x), .y(y), .vld(vld),
        .y_wave_q(y_wave),
        .color(18'b000000_111000_111000),
        .bars(bars),
        .rgb(rgb)
    );

    reg [17:0] fb [0:800*480-1];
    integer xx, yy, i, fd;
    real s;

    //  和弦柱高（来自 scratch/spec/spec_fixed.py 的 C4+E4+G4 输出）
    integer H [0:31];
    initial begin
        //  spec_band.v iverilog 实测输出（C4 261.6 Hz, amp20000, tb_spec_band）
        H[0]=28;  H[1]=17;  H[2]=31;  H[3]=37;  H[4]=13;  H[5]=48;  H[6]=55;  H[7]=82;
        H[8]=87;  H[9]=85;  H[10]=46; H[11]=32; H[12]=19; H[13]=20; H[14]=10; H[15]=41;
        H[16]=60; H[17]=6;  H[18]=17; H[19]=13; H[20]=3;  H[21]=11; H[22]=6;  H[23]=0;
        H[24]=3;  H[25]=0;  H[26]=0;  H[27]=0;  H[28]=20; H[29]=0;  H[30]=0;  H[31]=0;
    end

    //  把 32 个高度拼成 256 bit
    task load_bars;
        integer b;
        begin
            for (b = 0; b < 32; b = b + 1)
                bars[b*8 +: 8] = H[b][7:0];
        end
    endtask

    initial begin
        load_bars;
        repeat (10) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        for (yy = 0; yy < 480; yy = yy + 1) begin
            for (xx = 0; xx < 800; xx = xx + 1) begin
                //  波形：3 个周期，幅度 ±190（天地 40/440），加一点二次谐波
                s = 150.0*$sin(2.0*3.14159265*3.0*xx/800.0)
                  +  30.0*$sin(2.0*3.14159265*7.0*xx/800.0);
                y_wave = $rtoi(200.0 + s);
                x = xx[9:0];
                y = yy[8:0];
                vld = 1'b1;
                @(posedge clk);
                fb[yy*800 + xx] = rgb;
            end
        end
        vld = 0;

        //  写 PPM (P6)
        fd = $fopen("spec_c4.ppm", "wb");
        $fwrite(fd, "P6\n800 480\n255\n");
        for (i = 0; i < 800*480; i = i + 1) begin
            $fwrite(fd, "%c%c%c",
                    {2'b0, fb[i][17:12]} * 4,
                    {2'b0, fb[i][11:6]}  * 4,
                    {2'b0, fb[i][5:0]}   * 4);
        end
        $fclose(fd);
        $display("spec_c4.ppm 已写出");
        $finish;
    end
endmodule
