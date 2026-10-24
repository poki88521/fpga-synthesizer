//============================================================================
//  tb_reverb_probe —— 混响独立探针：复现"内部削顶的炸"，并验证修复
//
//  激励：262 Hz 正弦、0.5 FS，前 ~205 ms 有声 + 之后静音（看尾巴衰减）
//  参数：与 full_system 里一致（size 26000 / decay 31000 / damp 9000 / ret 16000 / predly 4700）
//
//  判据（修复前后对比）：
//     修复前：ret 峰值接近/超过 1 FS、内部饱和、频谱出现大量非谐波  ≈ "炸"
//     修复后：ret 峰值明显下降、无饱和、频谱干净、尾巴单调衰减
//============================================================================
`timescale 1ns/1ps

module tb_reverb_probe;

    localparam integer N_CYC = 1024;       // 48.828 kHz 帧率（50 MHz / 1024）
    localparam integer NSAMP = 20000;      // 20000 帧 ≈ 410 ms
    localparam real    FS    = 48828.125;   // 实际帧率
    localparam real    FREQ  = 262.0;       // 激励频率
    localparam real    AMPV  = 8388608.0;   // 1.0 FS —— 最坏情况（发送 127 + 满量程音）   // 0.5 FS

    reg clk = 0;
    always #10 clk = ~clk;                 // 50 MHz

    reg rst_n = 0;
    initial begin
        //  ⚠ 混响的延迟线是 BSRAM（rmem），仿真里未初始化 → 读出来是 X。
        //     硬件上 BSRAM 初值由 bitstream 承担（为 0），仿真必须手动清零。
        for (i_init = 0; i_init < 29492; i_init = i_init + 1)
            u_rv.rmem[i_init] = 24'sd0;
        repeat (30) @(posedge clk);
        rst_n = 1;
    end
    integer i_init;

    //------------------------------------------ 帧节拍
    reg [10:0] cyc = 0;
    reg        frame_stb = 0;
    always @(posedge clk) begin
        cyc       <= (cyc == N_CYC - 1) ? 11'd0 : (cyc + 11'd1);
        frame_stb <= (cyc == N_CYC - 1);
    end

    //------------------------------------------ 激励（262 Hz 正弦，0.5 FS）
    reg signed [23:0] sine = 24'sd0;
    integer nframe = 0;
    real    ang;

    always @(posedge clk) begin
        if (frame_stb) begin
            ang    = 2.0 * 3.14159265358979 * FREQ * $itor(nframe) / FS;
            sine   <= $rtoi($sin(ang) * AMPV);
            nframe <= nframe + 1;
        end
    end

    wire in_valid = (nframe < 10000);      // 前 10000 帧（≈205 ms）有声

    //------------------------------------------ DUT
    wire               ret_vld;
    wire signed [23:0] ret_l, ret_r;

    fx_reverb #(.AW(24)) u_rv (
        .clk(clk), .rst_n(rst_n), .frame_stb(frame_stb),
        .in_vld(in_valid),
        .bus_l(sine), .bus_r(sine),
        .p_decay(16'd31000), .p_damp(16'd9000), .p_size(16'd26000),
        .p_ret(16'd32767), .p_predly(16'd4700),
        .ret_vld(ret_vld), .ret_l(ret_l), .ret_r(ret_r)
    );

    //------------------------------------------ 采样与统计（每帧只取一次）
    //  ret_vld 每帧触发多次（12 条线 / 2 声道的流水），不能直接当 48 kHz 流用。
    //  做法：帧内锁存最后一次 ret_l；同时统计**内部节点 comb_sum_n 是否会被 sat24 削顶**
    //        —— 只看输出峰值会被全通网络掩盖，必须看内部节点。
    integer fd;
    initial fd = $fopen("D:/code/fpga-synthesizer/develop/scratch/agent/probe_reverb.txt", "w");

    reg signed [23:0] last_ret = 24'sd0;
    integer nr = 0, nsat = 0, pmax = 0, v;
    integer cmax = 0, ap_hit = 0, ap_hit_tot = 0;
    integer csum;
    integer nfr = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (ret_vld) begin
                last_ret <= ret_l;
                nr = nr + 1;
                v  = $signed(ret_l);
                if ((v >= 8388600) || (v <= -8388600)) nsat = nsat + 1;
                if (v > pmax)  pmax = v;
                if (-v > pmax) pmax = -v;
            end
            //  内部节点：梳状 8 条之和（会在 ap_x 处被 sat24 钳位）
            csum = $signed(u_rv.comb_sum_n);
            if (csum > cmax)  cmax = csum;
            if (-csum > cmax) cmax = -csum;
            if ((csum > 8388607) || (csum < -8388608)) ap_hit = ap_hit + 1;
        end
    end

    always @(posedge clk) begin
        if (rst_n && frame_stb) begin
            $fwrite(fd, "%0d %0d %0d\n", $signed(last_ret), cmax, ap_hit);
            ap_hit_tot = ap_hit_tot + ap_hit;
            nfr = nfr + 1;
            cmax   = 0;
            ap_hit = 0;
        end
    end

    initial begin
        wait (rst_n);
        repeat (NSAMP) @(posedge frame_stb);
        $display("帧数 = %0d   ret_vld 总次数 = %0d", nfr, nr);
        $display("ret 峰值          = %0d  (%0.1f %%FS)  撞满量程 %0d 次", pmax, 100.0 * pmax / 8388608.0, nsat);
        $display("comb_sum_n 被削顶 = %0d 拍/总帧（每帧平均 %0.1f 拍）", ap_hit_tot,
                 (nfr > 0) ? (1.0 * ap_hit_tot / nfr) : 0.0);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("FAIL 超时");
        $finish;
    end

endmodule
