//============================================================================
//  tb_dds_voice —— DDS + 波表线性插值 单元测试
//
//  验证点（对应 documents/技术文档.md §五.1.3 的"幅度 / 定点"提醒）：
//    1. 幅度口径：全量程 16 位正弦插值后应接近 Q1.23 满量程（≈ ±2^23）。
//       若多除了一次 256，幅度会只剩 1/256 —— 这个测试专门盯这一点
//    2. 频率：phase_inc = f × 2^32 / fs，实测过零率应与目标一致
//    3. 参考模型逐样本比对：TB 侧独立重算 tab[n] + (tab[n+1]-tab[n])*frac/256 并 <<8
//    4. 槽内回绕：槽 2 用「斜坡」表（末点 1023、首点 −1024），
//       索引到 2047 时相邻点必须回到**本槽首点**；若错跨到槽 3（全 0）会明显失配
//    5. 相位连续性：改 phase_inc 时相位不清零
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_dds_voice;

    localparam integer NSLOT = 8;
    localparam integer NPT   = 2048;                 // 每槽点数
    localparam integer DEPTH = NSLOT * NPT;          // 16384 点
    localparam integer NSAMP = 8000;                 // 每轮采集样本数
    localparam real    FS    = 48000.0;
    localparam integer INC1K = 89478485;             // 1000 × 2^32 / 48000

    integer errors = 0;

    //---------------- 波表（行为级 ROM，仅仿真用） ----------------
    reg signed [15:0] rom [0:DEPTH-1];

    integer i, k;
    real    ang;
    initial begin
        // 槽 0：2048 点满量程正弦
        for (i = 0; i < NPT; i = i + 1) begin
            ang   = 2.0 * 3.14159265358979 * i / NPT;
            rom[i] = $rtoi(32767.0 * $sin(ang));
        end
        // 槽 1：常量 12345
        for (i = NPT; i < 2*NPT; i = i + 1)
            rom[i] = 16'sd12345;
        // 槽 2：斜坡，首点 −1024、末点 +1023（用于回绕测试）
        for (i = 2*NPT; i < 3*NPT; i = i + 1)
            rom[i] = $signed(i - 2*NPT) - 16'sd1024;
        // 槽 3~7：全 0
        for (i = 3*NPT; i < DEPTH; i = i + 1)
            rom[i] = 16'sd0;
    end

    //---------------- DUT ----------------
    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_async_n = 0;
    wire rst_n_sync;
    reset_sync u_rst (.clk(clk), .rst_async_n(rst_async_n), .rst_n_sync(rst_n_sync));

    reg  [3:0] ph = 4'd0;
    always @(posedge clk) ph <= ph + 4'd1;

    wire sample_en   = (ph == 4'd0);      // 每 8 拍一个时隙节拍
    wire samples_rdy = (ph == 4'd2);      // 模拟取数器：2 拍后把两点交回

    reg  [31:0] phase_inc;
    reg  [2:0]  timbre_slot;

    wire [31:0]        phase_acc;
    wire signed [23:0] wave_out;
    wire [13:0]        rom_addr_n, rom_addr_n1;

    // TB 侧"取数器"：在 sample_en 那拍采走组合地址（此时 phase_acc 尚未更新）
    reg [13:0] lat_n, lat_n1;
    always @(posedge clk) if (sample_en) begin
        lat_n  <= rom_addr_n;
        lat_n1 <= rom_addr_n1;
    end

    wire signed [15:0] tab_n  = rom[lat_n];
    wire signed [15:0] tab_n1 = rom[lat_n1];

    dds_voice u_dds (
        .clk (clk), .rst_n_sync (rst_n_sync), .sample_en (sample_en),
        .slot (2'd0),
        .phase_inc (phase_inc), .wave_sel (2'd0), .timbre_slot (timbre_slot),
        .tab_n (tab_n), .tab_n1 (tab_n1), .samples_rdy (samples_rdy),
        .phase_acc (phase_acc), .wave_out (wave_out),
        .rom_addr_n (rom_addr_n), .rom_addr_n1 (rom_addr_n1)
    );

    //---------------- 采集：相位与输出按同一窗口对齐 ----------------
    integer cap     [0:NSAMP-1];      // wave_out
    reg [31:0] pcap [0:NSAMP-1];      // 该样本对应的"取地址时"的 phase_acc
    integer ncap;
    reg     capturing;

    always @(posedge clk) begin
        if (capturing && (ncap < NSAMP)) begin
            if (ph == 4'd0) pcap[ncap] = phase_acc;   // 更新前的相位
            if (ph == 4'd4) begin
                cap[ncap] = wave_out;                 // ph=2 更新，ph=3 起有效
                ncap = ncap + 1;
            end
        end
    end

    task align_and_start;
        begin
            while (ph != 4'd0) @(posedge clk);
            @(posedge clk);
            ncap = 0;
            capturing = 1'b1;
        end
    endtask

    task wait_capture;
        input integer n;
        begin
            while (ncap < n) @(posedge clk);
            capturing = 1'b0;
        end
    endtask

    //---------------- 参考模型：完全按规格独立重算 ----------------
    function signed [23:0] ref_wave;
        input [31:0] pa;
        input [2:0]  slot;
        reg   [13:0] a0, a1;
        reg   [10:0] ix;
        reg   [7:0]  fr;
        reg signed [15:0] t0, t1;
        reg signed [16:0] df;
        reg signed [24:0] pd;
        reg signed [16:0] it;
        reg signed [24:0] sc;
        begin
            ix = pa[31:21];
            fr = pa[20:13];
            a0 = {slot, ix};
            // 槽内回绕：索引到 2047 时相邻点取本槽首点
            a1 = (ix == 11'd2047) ? {slot, 11'd0} : {slot, ix + 11'd1};
            t0 = rom[a0];
            t1 = rom[a1];
            df = t1 - t0;
            pd = df * $signed({1'b0, fr});
            it = t0 + (pd >>> 8);
            sc = it * 25'sd256;
            if      (sc >  25'sd8388607) ref_wave = 24'sh7FFFFF;
            else if (sc < -25'sd8388608) ref_wave = 24'sh800000;
            else                         ref_wave = sc[23:0];
        end
    endfunction

    //---------------- 分析变量 ----------------
    integer peak, crossings, max_err, idx;
    real    f_est;

    initial begin
        rst_async_n = 1'b0;
        phase_inc   = 32'd0;
        timbre_slot = 3'd0;
        capturing   = 1'b0;
        ncap        = 0;

        repeat (20) @(posedge clk);
        rst_async_n = 1'b1;
        repeat (20) @(posedge clk);

        //================================================================
        // 测试 1：幅度口径 + 频率
        //================================================================
        phase_inc   = INC1K;
        timbre_slot = 3'd0;
        align_and_start();
        wait_capture(NSAMP);

        peak = 0;
        for (i = 0; i < NSAMP; i = i + 1) begin
            if (cap[i] > peak) peak = cap[i];
            if (-cap[i] > peak) peak = -cap[i];
        end
        if (peak > 8388608 || peak < (8388608 * 98 / 100)) begin
            $display("FAIL dds 幅度: 峰值 %0d，期望接近 Q1.23 满量程 8388608", peak);
            $display("     若约为 8388608/256 = 32768，说明多做了一次 >>>8");
            errors = errors + 1;
        end else
            $display("PASS dds 幅度: 峰值 %0d / 8388608 (%.2f%% 满量程)",
                     peak, 100.0 * peak / 8388608.0);

        crossings = 0;
        for (i = 1; i < NSAMP; i = i + 1)
            if ((cap[i-1] < 0 && cap[i] >= 0) || (cap[i-1] >= 0 && cap[i] < 0))
                crossings = crossings + 1;
        f_est = (crossings / 2.0) / (NSAMP / FS);
        if (f_est < 985.0 || f_est > 1015.0) begin
            $display("FAIL dds 频率: 实测 %.1f Hz，期望 1000 Hz", f_est);
            errors = errors + 1;
        end else
            $display("PASS dds 频率: 实测 %.1f Hz（期望 1000 Hz）", f_est);

        //================================================================
        // 测试 2：参考模型逐样本比对（槽 0 正弦）
        //================================================================
        max_err = 0;
        for (i = 0; i < NSAMP; i = i + 1) begin
            idx = ref_wave(pcap[i], 3'd0);
            k = (cap[i] > idx) ? (cap[i] - idx) : (idx - cap[i]);
            if (k > max_err) max_err = k;
        end
        if (max_err != 0) begin
            $display("FAIL dds 参考比对(槽0): 最大偏差 %0d LSB(Q1.23)", max_err);
            errors = errors + 1;
        end else
            $display("PASS dds 参考比对(槽0): %0d 个样本与参考模型逐位一致", NSAMP);

        //================================================================
        // 测试 3：槽内回绕（槽 2 斜坡表，末点 1023 / 首点 −1024）
        //================================================================
        phase_inc   = INC1K;
        timbre_slot = 3'd2;
        align_and_start();
        wait_capture(NSAMP);

        max_err = 0;
        k = 0;                                   // 统计真正落在回绕点（idx==2047）的样本数
        for (i = 0; i < NSAMP; i = i + 1) begin
            idx = ref_wave(pcap[i], 3'd2);
            if (pcap[i][31:21] == 11'd2047) k = k + 1;
            if ((cap[i] > idx ? cap[i] - idx : idx - cap[i]) > max_err)
                max_err = (cap[i] > idx ? cap[i] - idx : idx - cap[i]);
        end
        if (max_err != 0) begin
            $display("FAIL dds 槽内回绕: 最大偏差 %0d LSB（相邻点错跨到槽 3 了？）", max_err);
            errors = errors + 1;
        end else
            $display("PASS dds 槽内回绕: 逐位一致，其中 %0d 个样本来自索引 2047 的回绕点", k);

        //================================================================
        // 测试 4：相位连续性
        //   phase_acc 只在 sample_en 有效的周期末沿更新。
        //   ph 是 NBA 赋值，posedge 上读到的是更新前的值，
        //   所以要在 negedge 上按 ph==0 定位到「sample_en 正有效的那个周期」。
        //================================================================
        timbre_slot = 3'd0;
        phase_inc   = INC1K;
        @(negedge clk);
        while (ph !== 4'd0) @(negedge clk);      // 现在处于 ph==0 的周期内
        k = phase_acc;                           // 更新前的相位
        phase_inc = 32'd100000000;               // 突然改频率
        @(posedge clk);                          // 本沿 DDS 用新 phase_inc 累加
        #1;
        if ((phase_acc - k) !== 32'd100000000) begin
            $display("FAIL dds 相位连续: 改频后增量 %0d，期望 100000000（相位被清零了？）",
                     phase_acc - k);
            errors = errors + 1;
        end else
            $display("PASS dds 相位连续: 改频后相位未清零（%0d → %0d），增量即新 phase_inc",
                     k, phase_acc);

        //================================================================
        if (errors == 0) $display("PASS  tb_dds_voice");
        else             $display("FAIL  tb_dds_voice: %0d 项", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("FAIL tb_dds_voice: 仿真超时");
        $finish;
    end

endmodule

`default_nettype wire
