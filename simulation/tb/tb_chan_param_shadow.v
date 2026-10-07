//============================================================================
//  tb_chan_param_shadow —— 通道参数影子寄存器单元测试
//
//  覆盖（scratch/交流用/集成接口说明_给poki.md §3.2 / §3.3 红线①）：
//    ① 扫描：rd_ch 自由运行，把 16 个通道的字段读进扫描缓冲
//    ② 提交：frame_stb 那一刻整体更新 ext_*，**帧内恒定**
//    ③ 红线①：帧中间改通道表内容，ext_* 不受影响；下一个 frame_stb 才生效
//    ④ ch_sust_pedal 顺手引出（给 voice_fetch）
//
//  TB 侧用一个组合读口模拟 chan_table：rd_ch → 该通道的字段。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_chan_param_shadow;
    parameter NCH = 16;

    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_n = 0;
    reg frame_stb = 0;

    wire [3:0]  rd_ch;
    wire [6:0]  rd_volume, rd_expression, rd_send_reverb, rd_send_chorus, rd_send_delay;
    wire [15:0] rd_pan_gL, rd_pan_gR;
    wire        rd_sustain_pedal;

    wire [NCH*7-1:0]  ext_volume, ext_expression, ext_send_rev, ext_send_cho, ext_send_del;
    wire [NCH*16-1:0] ext_pan_gL, ext_pan_gR;
    wire [NCH-1:0]    ch_sust_pedal;

    //--------------------------------------------- 模拟 chan_table 的组合读口
    reg [6:0]  t_vol  [0:NCH-1];
    reg [6:0]  t_exp  [0:NCH-1];
    reg [15:0] t_panl [0:NCH-1];
    reg [15:0] t_panr [0:NCH-1];
    reg [6:0]  t_srev [0:NCH-1];
    reg [6:0]  t_scho [0:NCH-1];
    reg [6:0]  t_sdel [0:NCH-1];
    reg        t_sust [0:NCH-1];

    assign rd_volume        = t_vol [rd_ch];
    assign rd_expression    = t_exp [rd_ch];
    assign rd_pan_gL        = t_panl[rd_ch];
    assign rd_pan_gR        = t_panr[rd_ch];
    assign rd_send_reverb   = t_srev[rd_ch];
    assign rd_send_chorus   = t_scho[rd_ch];
    assign rd_send_delay    = t_sdel[rd_ch];
    assign rd_sustain_pedal = t_sust[rd_ch];

    chan_param_shadow #(.NCH(NCH)) dut (
        .clk(clk), .rst_n_sync(rst_n), .frame_stb(frame_stb),
        .rd_ch(rd_ch), .rd_volume(rd_volume), .rd_expression(rd_expression),
        .rd_pan_gL(rd_pan_gL), .rd_pan_gR(rd_pan_gR),
        .rd_send_reverb(rd_send_reverb), .rd_send_chorus(rd_send_chorus),
        .rd_send_delay(rd_send_delay), .rd_sustain_pedal(rd_sustain_pedal),
        .ext_volume(ext_volume), .ext_expression(ext_expression),
        .ext_pan_gL(ext_pan_gL), .ext_pan_gR(ext_pan_gR),
        .ext_send_rev(ext_send_rev), .ext_send_cho(ext_send_cho), .ext_send_del(ext_send_del),
        .ch_sust_pedal(ch_sust_pedal)
    );

    integer errors = 0;
    integer i;

    task chk(input cond, input [255:0] name);
        begin
            if (!cond) begin errors = errors + 1; $display("FAIL  %0s", name); end
            else $display("  ok  %0s", name);
        end
    endtask

    // 产生一次 frame_stb 并等提交 + 扫描一整轮
    task do_frame;
        begin
            @(negedge clk); frame_stb = 1'b1;
            @(negedge clk); frame_stb = 1'b0;
            repeat (40) @(posedge clk);       // 扫描一轮 16 拍 + 余量
        end
    endtask

    // 便捷取值
    function [6:0] vol_of;  input integer c; begin vol_of  = ext_volume[c*7 +: 7]; end endfunction
    function [15:0] panl_of; input integer c; begin panl_of = ext_pan_gL[c*16 +: 16]; end endfunction

    initial begin
        $dumpfile("tb_chan_param_shadow.vcd");
        $dumpvars(0, tb_chan_param_shadow);

        // 给通道表填一组可辨识的值
        for (i = 0; i < NCH; i = i + 1) begin
            t_vol [i] = i + 10;
            t_exp [i] = 7'd100;
            t_panl[i] = 16'h1000 + i;
            t_panr[i] = 16'h2000 + i;
            t_srev[i] = 7'd40;
            t_scho[i] = 7'd41;
            t_sdel[i] = 7'd42;
            t_sust[i] = (i == 3);             // 只有通道 3 踩下踏板
        end

        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (5) @(posedge clk);

        //================================================ ① 复位后输出为 0
        $display("== 1. reset ==");
        chk(ext_volume[0*7 +: 7] === 7'd0, "ext_volume[0] = 0 after reset");

        // 先让扫描跑完一整轮（16 拍）。否则第一次 frame_stb 时，后面的通道
        // 还没被扫进缓冲 —— 这不是 RTL 问题，是激励给得太早。
        repeat (40) @(posedge clk);

        //================================================ ② 提交后各通道正确
        $display("== 2. after frame_stb: all 16 channels latched ==");
        do_frame;
        chk(vol_of(0)  === 7'd10, "ch0  volume = 10");
        chk(vol_of(5)  === 7'd15, "ch5  volume = 15");
        chk(vol_of(15) === 7'd25, "ch15 volume = 25");
        chk(panl_of(7) === 16'h1007, "ch7  pan_gL = 0x1007");
        chk(ext_pan_gR[7*16 +: 16] === 16'h2007, "ch7  pan_gR = 0x2007");
        chk(ext_send_rev[3*7 +: 7] === 7'd40, "ch3  send_rev = 40");
        chk(ext_send_cho[3*7 +: 7] === 7'd41, "ch3  send_cho = 41");
        chk(ext_send_del[3*7 +: 7] === 7'd42, "ch3  send_del = 42");
        chk(ext_expression[2*7 +: 7] === 7'd100, "ch2  expression = 100");

        //================================================ ④ sustain_pedal 引出
        $display("== 3. ch_sust_pedal ==");
        chk(ch_sust_pedal[3] === 1'b1, "ch_sust_pedal[3] = 1（只有 ch3 踩下）");
        chk(ch_sust_pedal[4] === 1'b0, "ch_sust_pedal[4] = 0");

        //================================================ ③ 红线①：帧内不变
        $display("== 4. redline 1: ext_* constant within a frame ==");
        t_vol[5] = 7'd99;                     // 帧中间改通道表
        repeat (60) @(posedge clk);           // 扫过好几轮，但没到 frame_stb
        chk(vol_of(5) === 7'd15, "mid-frame change must NOT reach ext_volume");
        $display("       ext_volume[5] 仍为 %0d（扫描缓冲已更新，但输出未提交）", vol_of(5));
        do_frame;                             // 下一个 frame_stb 才生效
        chk(vol_of(5) === 7'd99, "after next frame_stb: ext_volume[5] = 99");

        if (errors == 0) $display("PASS  tb_chan_param_shadow");
        else             $display("FAIL  tb_chan_param_shadow : %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
