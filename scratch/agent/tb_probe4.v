//============================================================================
//  tb_probe4 —— “和弦震荡感”四点探针（不改 RTL，只用层次引用）
//
//  目的：把 MIDI 激励（默认 C4 + E4）喂进 **full_system**，在 4 个点抓同一段音频：
//      ① voice_mono 输出   voice_aud[8 泳道 × 24 bit]（每个时隙 8 个声部）+ 该时隙 env
//      ② chan_layer 输出   ch_vld / ch_addr / ch_l / ch_r（16 通道串行）
//      ③ main_mix  输出    mix_vld / mx_l / mx_r
//      ④ master_chain 输出 sample_l / sample_r（16 bit，送 DAC）
//
//  ⚠ 抓取**不等 ADSR 进 sustain**：voice 文件同时记 env（该时隙的包络值），
//    分析脚本用 audio/env 做代数反演，把包络斜坡除掉 → 同样的仿真秒数全部用来
//    观察“震荡/拍频”，不浪费在等包络上。
//  ⚠ 时钟用 49.152 MHz（周期 20.345 ns）：这样 sample_stb = 1024 拍 → fs **正好 48 kHz**，
//    与上板（USE_PLL=1）完全一致，note_inc 表的音高也正好对上，不需要事后换算。
//
//  输出文件（+tag 前缀）：
//      <tag>_voice.txt : 每帧 4 行 = frame slot env l0 l1 ... l7
//      <tag>_chan.txt  : 每帧 16 行 = frame ch_addr ch_l ch_r
//      <tag>_mix.txt   : 每帧 1 行  = frame mx_l mx_r
//      <tag>_out.txt   : 每帧 1 行  = frame sample_l sample_r
//
//  跑法（必须在 board/full_system 目录，否则调度层 data/*.hex 找不到）：
//      iverilog -g2005 -DSIMULATION -o probe4.vvp -s tb_probe4 -I ..\..\rtl `
//          (gci ..\..\rtl -recurse -filter *.v).FullName `
//          ..\..\simulation\models\gowin_prim_stub.v tb_probe4.v
//      vvp probe4.vvp +tag=D:/.../A +n1=60 +n2=64 +skip=6 +dur=200
//
//  +n1/+n2 : 两个音的 MIDI 音高（n2<0 = 只发一个音）
//  +skip   : 第二个 NoteOn 之后先跳过多少 ms 再开始抓（默认 6）
//  +dur    : 抓取时长 ms（默认 200）
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_probe4;

    localparam integer P    = 8;
    localparam integer NCH  = 16;
    //  49.152 MHz：半周期 10.1725 ns ⇒ sample_stb 间隔 1024 拍 = 20.833 µs = 48.000 kHz
    localparam real    HALF = 10.17250;
    localparam integer BIT_TICK = 1573;    // 31250 baud @ 49.152 MHz

    reg clk50 = 0, clk12288 = 0;
    always #HALF clk50    = ~clk50;
    always #HALF clk12288 = ~clk12288;

    wire HP_BCK, HP_WS, HP_DIN, PA_EN;
    reg [3:0] midi_rx = 4'hF;

    full_system #(
        .USE_PLL(0), .P(P), .G(4), .NCH(NCH), .STRIDE(32),
        .PA_DELAY(8), .POR_BITS(8),
        .TEST_MODE_DEFAULT(0),
        //  ⚠ 绝对路径：本 TB 可能在别的目录跑（那边子目录写入被 ACL 挡）
        .WAVE_INIT_FILE("D:/code/fpga-synthesizer/develop/board/full_system/data/wave_table.hex")
    ) dut (
        .clk50(clk50), .clk12288(clk12288),
        .midi_rx(midi_rx),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN)
    );

    //---------------- MIDI 发送 ----------------
    task midi_byte;
        input [7:0] b;
        integer k;
        begin
            midi_rx[0] = 1'b0;
            #(BIT_TICK * 20.345);
            for (k = 0; k < 8; k = k + 1) begin
                midi_rx[0] = b[k];
                #(BIT_TICK * 20.345);
            end
            midi_rx[0] = 1'b1;
            #(BIT_TICK * 20.345);
        end
    endtask

    //---------------- 参数 ----------------
    integer n1 = 60, n2 = 64;
    integer skip_ms = 6, dur_ms = 200;
    reg [1023:0] tag;

    integer fd_v, fd_c, fd_m, fd_o;
    reg     cap = 1'b0;
    integer frame = 0;
    integer cap_start = -1, cap_end = -1;

    integer v_lines = 0, c_lines = 0, m_lines = 0, o_lines = 0;
    integer slot_hist [0:3];
    integer xmix = 0, xout = 0;

    //---------------- 四点抓取 ----------------
    integer li;
    always @(posedge clk50) begin
        if (dut.rst_n_sync && dut.voice_data_vld[0]) begin
            if (cap) begin
                $fwrite(fd_v, "%0d %0d", frame, dut.u_full_top.slot);
                //  每泳道自己的包络（rs_env_value 已按 slot 选好，是"本泳道本时隙"的值）
                for (li = 0; li < P; li = li + 1)
                    $fwrite(fd_v, " %0d", dut.rs_env_value[li*16 +: 16]);
                for (li = 0; li < P; li = li + 1)
                    $fwrite(fd_v, " %0d", $signed(dut.voice_aud[li*24 +: 24]));
                $fwrite(fd_v, "\n");
                v_lines = v_lines + 1;
                slot_hist[dut.u_full_top.slot] = slot_hist[dut.u_full_top.slot] + 1;
            end
        end
    end

    always @(posedge clk50) begin
        if (dut.rst_n_sync && dut.u_full_top.ch_vld) begin
            if (cap) begin
                $fwrite(fd_c, "%0d %0d %0d %0d\n", frame,
                        dut.u_full_top.ch_addr,
                        $signed(dut.u_full_top.ch_l),
                        $signed(dut.u_full_top.ch_r));
                c_lines = c_lines + 1;
            end
        end
    end

    always @(posedge clk50) begin
        if (dut.rst_n_sync && dut.u_full_top.mix_vld) begin
            if (cap) begin
                if ((dut.u_full_top.mx_l === 24'bx) || (dut.u_full_top.mx_r === 24'bx)) xmix = xmix + 1;
                $fwrite(fd_m, "%0d %0d %0d\n", frame,
                        $signed(dut.u_full_top.mx_l),
                        $signed(dut.u_full_top.mx_r));
                m_lines = m_lines + 1;
            end
        end
    end

    always @(posedge clk50) begin
        if (dut.rst_n_sync && dut.u_full_top.sample_stb) begin
            if (cap) begin
                if ((dut.u_full_top.sample_l === 16'bx) || (dut.u_full_top.sample_r === 16'bx)) xout = xout + 1;
                $fwrite(fd_o, "%0d %0d %0d\n", frame,
                        $signed(dut.u_full_top.sample_l),
                        $signed(dut.u_full_top.sample_r));
                o_lines = o_lines + 1;
                if (frame >= cap_end) cap <= 1'b0;
            end
            frame = frame + 1;
        end
    end

    integer i, void_ignore;
    initial begin
        for (i = 0; i < 4; i = i + 1) slot_hist[i] = 0;

        if (!$value$plusargs("tag=%s", tag))      tag      = "probe4";
        void_ignore = $value$plusargs("n1=%d", n1);
        void_ignore = $value$plusargs("n2=%d", n2);
        void_ignore = $value$plusargs("skip=%d", skip_ms);
        void_ignore = $value$plusargs("dur=%d", dur_ms);

        fd_v = $fopen({tag, "_voice.txt"}, "w");
        fd_c = $fopen({tag, "_chan.txt"},  "w");
        fd_m = $fopen({tag, "_mix.txt"},   "w");
        fd_o = $fopen({tag, "_out.txt"},   "w");

        $display("=== tb_probe4: note %0d + %0d, skip %0d ms, capture %0d ms ===",
                 n1, n2, skip_ms, dur_ms);

        wait (dut.rst_n_sync === 1'b1);
        #2000;
        wait (PA_EN === 1'b1);

        midi_byte(8'h90); midi_byte(n1[7:0]); midi_byte(8'h64);
        #200000;
        if (n2 >= 0) begin
            midi_byte(8'h90); midi_byte(n2[7:0]); midi_byte(8'h64);
            #200000;
        end
        $display("  pf_gate = %b  pf_ch = %h  pf_phase_inc = %h",
                 dut.pf_gate, dut.pf_ch, dut.pf_phase_inc[31:0]);

        #(skip_ms * 1000000);
        $display("  开始抓取 frame=%0d", frame);

        cap_start = frame;
        cap_end   = frame + (dur_ms * 48);     // 48 帧/ms
        cap = 1'b1;
        wait (cap == 1'b0);
        $display("  抓取结束 frame=%0d（%0d 帧 = %.1f ms）",
                 frame, frame - cap_start, (frame - cap_start) / 48.0);
        $display("  行数 voice=%0d chan=%0d mix=%0d out=%0d   X: mix=%0d out=%0d",
                 v_lines, c_lines, m_lines, o_lines, xmix, xout);
        $display("  时隙分布 %0d %0d %0d %0d",
                 slot_hist[0], slot_hist[1], slot_hist[2], slot_hist[3]);

        $fclose(fd_v); $fclose(fd_c); $fclose(fd_m); $fclose(fd_o);
        $display("DONE");
        $finish;
    end

    initial begin
        #2000_000_000;
        $display("FAIL: 仿真超时");
        $finish;
    end

endmodule
`default_nettype wire
