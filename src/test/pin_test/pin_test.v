// [2026-10-05 22:12]  本文件时间戳（用于校验是否被外部覆盖）
//=============================================================
//  pin_test —— 端口/示波器验证：在 PMOD2 的 8 个脚各输出「已知频率」方波
//  板卡：Tang Mega 138K Pro (GW5AST-LV138FPG676A / FCPBG676A)
//  时钟：P16 = 50 MHz
//
//  目的：给出确定已知的频率，用来
//    (1) 验证示波器/探头/接地是否正常
//    (2) 验证 PMOD2 各端口是否能正常输出
//    (3) 判断"不同端口是否有差异"
//
//  频率表（cnt[k] 翻转周期 = 2^(k+1) 拍 -> f = 50MHz / 2^(k+1)）：
//    C21  PMOD2_IO0 : cnt[11] -> 12207 Hz
//    B20  PMOD2_IO1 : cnt[12] ->  6104 Hz
//    B19  PMOD2_IO2 : cnt[13] ->  3052 Hz
//    A17  PMOD2_IO3 : cnt[14] ->  1526 Hz
//    B21  PMOD2_IO4 : cnt[15] ->   763 Hz
//    A20  PMOD2_IO5 : cnt[16] ->   381 Hz
//    A19  PMOD2_IO6 : cnt[17] ->   191 Hz
//    A18  PMOD2_IO7 : cnt[18] ->    95 Hz
//
//  LED (M25/LED3)：cnt[24] 慢闪（约 0.67 s 半周期），确认设计在跑
//  （板上 LED 低电平点亮，故 led 输出取反）
//=============================================================
module pin_test (
    input  wire clk,        // P16, 50 MHz
    output wire p0,         // C21  PMOD2_IO0  12207 Hz
    output wire p1,         // B20  PMOD2_IO1   6104 Hz
    output wire p2,         // B19  PMOD2_IO2   3052 Hz
    output wire p3,         // A17  PMOD2_IO3   1526 Hz
    output wire p4,         // B21  PMOD2_IO4    763 Hz
    output wire p5,         // A20  PMOD2_IO5    381 Hz
    output wire p6,         // A19  PMOD2_IO6    191 Hz
    output wire p7,         // A18  PMOD2_IO7     95 Hz
    output wire led         // M25
);

    reg [24:0] cnt;

    always @(posedge clk)
        cnt <= cnt + 25'd1;

    assign p0 = cnt[11];
    assign p1 = cnt[12];
    assign p2 = cnt[13];
    assign p3 = cnt[14];
    assign p4 = cnt[15];
    assign p5 = cnt[16];
    assign p6 = cnt[17];
    assign p7 = cnt[18];

    assign led = ~cnt[24];   // 低电平点亮

endmodule
