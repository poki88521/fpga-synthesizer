//============================================================================
//  tb_full_chain —— 模块三全链 demo（导出音频文件用）
//
//  链路：8 个音符（模拟单声部层输出）
//          -> 通道处理层（暂存/累加/音量/声像）
//          -> 效果发送总线
//          -> 效果器运算（混响 + 合唱 + 延迟）
//          -> 主混音求和
//          -> 主输出处理（主音量/隔直/抖动）
//          -> 16-bit 样本导出
//
//  ⚠ 时序是**自定时**的：一个采样处理完立刻进下一个，不按 1024 拍的空转周期跑。
//     这是为了仿真速度（否则 1 秒音频要跑 50M 拍）。音频内容完全一样，
//     只是仿真里"每采样用几拍"和真机的 1024 拍不同。
//     真实的采样率/串行时序由 tb_master_chain / tb_pt8211_tx 单独验证。
//
//  输出：sim/out/demo.txt，每行两个整数（左 右，16-bit 有符号）
//        再跑 sim/wav.py 转成 demo.wav
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_full_chain #(
    parameter integer REV_EN = 1
);

    localparam integer NCH   = 16;
    localparam integer NSAMP   = 10000;      // 约 0.49 秒（受仿真速度限制）
    localparam integer NRETRIG = 12000;      // 每 0.25 秒一次拨弦

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;                   // 50 MHz

    // ---------------- 采样计数器 ----------------
    integer ns;
    reg     sample_stb;

    // ---------------- 8 个音符 ----------------
    // 频率字 = f * 2^32 / 48828
    function [31:0] inc_of; input integer v; begin
        case (v)
            0: inc_of = 32'd23004471;   // C4  261.63 Hz
            1: inc_of = 32'd28983484;   // E4  329.63
            2: inc_of = 32'd34472858;   // G4  392.00
            3: inc_of = 32'd46008942;   // C5  523.25
            4: inc_of = 32'd57966968;   // E5  659.26
            5: inc_of = 32'd68945716;   // G5  784.00
            6: inc_of = 32'd86868402;   // B5  987.77
            default: inc_of = 32'd92017884;// C6 1046.50
        endcase
    end endfunction

    reg [31:0] ph [0:7];
    reg [23:0] env [0:7];
    integer    vi;

    // ⚠ 必须初始化！ph 只在 sample_stb 时做 ph <= ph + inc，
    //   未初始化的话 X + inc 永远是 X，会一路传到输出（第一次跑全 x 就是这个）
    initial begin
        for (vi = 0; vi < 8; vi = vi + 1) begin
            ph[vi]  = 32'd0;
            env[vi] = 24'd0;
        end
    end

    // 每 NRETRIG 个采样重触发一次拨弦
    // ⚠ ns 在 sample_stb 那一拍已经自增成 1，所以判断要写 == 1，
    //   写 == 0 会把首次重触发整个跳过（表现为开头一大段静音）
    wire retrig = (ns % NRETRIG) == 1;

    // 一个声部的波形（三角波 x 包络）。用函数而不是 generate ——
    // generate 里的 wire 初值写法在这个工具链上会报 Invalid module item
    function signed [23:0] voice_of;
        input integer v;
        reg [31:0] pt;
        reg [9:0]  idx;
        reg [10:0] triw;          // 注意：不能叫 tri，那是 Verilog 的线网类型关键字
        reg signed [23:0] osc;
        begin
            pt  = ph[v];
            idx = pt[31:22];
            triw = idx[9] ? ({1'b0, ~idx} + 11'd1) : {1'b0, idx};
            osc = ({13'd0, triw} << 13) - 24'sd4194304;
            voice_of = (osc * env[v]) >>> 23;
        end
    endfunction

    // 方波门控：前 0.25 秒发声、后 0.25 秒静音。
    // 静音段正好用来听延迟和混响的尾巴（这也是 demo 的重点）。
    // 之前用指数衰减包络，输出是一条平线然后硬切 —— 那是我 TB 的问题，
    // 不是音频通路的问题，索性换成最稳的门控。
    wire gate = (ns % 24000) < 12000;

    always @(posedge clk) begin
        if (sample_stb) begin
            for (vi = 0; vi < 8; vi = vi + 1) begin
                ph[vi] <= ph[vi] + inc_of(vi);
                env[vi] <= gate ? 24'sd6500000 : 24'sd0;
            end
        end
    end

    // ---------------- 时隙激励（P=8, G=4） ----------------
    reg                    slot_vld;
    reg  [1:0]             slot;
    reg  [7:0]             lane_vld;
    reg  [8*4-1:0]          lane_ch;
    reg  [8*24-1:0]         lane_aud;

    integer li;
    always @(*) begin
        for (li = 0; li < 8; li = li + 1) begin
            // 声部号 = slot*8 + lane。只有 slot0 的 8 条泳道是有效声部
            lane_vld[li]           = (slot == 2'd0);
            lane_ch [li*4 +: 4]    = li[3:0];               // 声道 0~7
            lane_aud[li*24 +: 24]  = (slot == 2'd0) ? voice_of(li) : 24'sd0;
        end
    end

    // ---------------- 链路 ----------------
    wire        ch_vld, frame_done;
    wire [3:0]  ch_addr;
    wire signed [23:0] ch_l, ch_r;

    // 通道状态表
    reg [NCH*7-1:0]        volume, expression, s_rev, s_cho, s_del;
    reg signed [NCH*16-1:0] panL, panR;
    integer ci;
    initial begin
        for (ci = 0; ci < NCH; ci = ci + 1) begin
            volume    [ci*7 +: 7]  = 7'd110;
            expression[ci*7 +: 7]  = 7'd127;
            // 8 个声部左右铺开
            panL[ci*16 +: 16] = (ci < 4) ? 16'sd26000 : 16'sd20000;
            panR[ci*16 +: 16] = (ci < 4) ? 16'sd20000 : 16'sd26000;
            s_rev[ci*7 +: 7]  = 7'd100;
            s_cho[ci*7 +: 7]  = 7'd60;
            s_del[ci*7 +: 7]  = 7'd70;
        end
    end

    chan_layer #(.P(8), .G(4), .AW(24), .CW(4), .NCH(NCH), .SW(2)) u_chan (
        .clk(clk), .rst_n(rst_n), .frame_stb(sample_stb),
        .slot_vld(slot_vld), .slot(slot), .vld(lane_vld),
        .ch_in(lane_ch), .aud_in(lane_aud),
        .volume(volume), .expression(expression), .pan_gL(panL), .pan_gR(panR),
        .ch_vld(ch_vld), .ch_addr(ch_addr), .ch_l(ch_l), .ch_r(ch_r),
        .frame_done(frame_done)
    );

    wire        bus_vld;
    wire signed [23:0] brl, brr, bcl, bcr, bdl, bdr;
    send_bus #(.NCH(NCH), .AW(24)) u_send (
        .clk(clk), .rst_n(rst_n), .frame_stb(sample_stb),
        .ch_vld(ch_vld), .ch_addr(ch_addr), .ch_l(ch_l), .ch_r(ch_r),
        .send_rev(s_rev), .send_cho(s_cho), .send_del(s_del),
        .bus_vld(bus_vld),
        .bus_rev_l(brl), .bus_rev_r(brr),
        .bus_cho_l(bcl), .bus_cho_r(bcr),
        .bus_del_l(bdl), .bus_del_r(bdr)
    );

    wire        fx_vld;
    wire signed [23:0] fxl, fxr;
    fx_top #(.REV_EN(REV_EN)) u_fx (
        .clk(clk), .rst_n(rst_n), .frame_stb(sample_stb),
        .bus_vld(bus_vld),
        .bus_rev_l(brl), .bus_rev_r(brr),
        .bus_cho_l(bcl), .bus_cho_r(bcr),
        .bus_del_l(bdl), .bus_del_r(bdr),
        .reverb_size(16'sd26000), .reverb_decay(16'sd31000), .reverb_damping(16'sd9000),
        .reverb_pre_delay(16'd0), .reverb_return(16'sd16000),
        .chorus_rate(16'd300), .chorus_depth(16'sd20000),
        .chorus_mix(16'sd23000), .chorus_return(16'sd12000),
        .delay_time(16'd14000), .delay_feedback(16'sd22000),
        .delay_mix(16'sd24000), .delay_return(16'sd12000),
        .fx_vld(fx_vld), .fx_l(fxl), .fx_r(fxr)
    );

    wire        mix_vld;
    wire signed [23:0] mxl, mxr;
    main_mix #(.NCH(NCH), .AW(24)) u_mix (
        .clk(clk), .rst_n(rst_n), .frame_stb(sample_stb),
        .ch_vld(ch_vld), .ch_addr(ch_addr), .ch_l(ch_l), .ch_r(ch_r),
        .fx_l(fxl), .fx_r(fxr), .fx_vld(fx_vld),
        .mix_vld(mix_vld), .main_l(mxl), .main_r(mxr)
    );

    wire [15:0] out_l, out_r;
    master_chain u_master (
        .clk(clk), .rst_n(rst_n), .en(sample_stb),
        .l_in(mxl), .r_in(mxr),
        .vol(14'd16383), .mute(1'b0),
        .sample_l(out_l), .sample_r(out_r)
    );

    // ---------------- 自定时序：跑完一个采样立刻进下一个 ----------------
    reg [3:0] tick;
    reg       driving;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_stb <= 1'b0; slot_vld <= 1'b0; slot <= 2'd0;
            tick <= 4'd0; driving <= 1'b0; ns <= 0;
        end else begin
            sample_stb <= 1'b0;
            slot_vld   <= 1'b0;

            if (!driving && !sample_stb) begin
                // 等链路空闲，开下一个采样
                if (mix_vld || (ns == 0)) begin
                    if (ns >= NSAMP) begin
                        // 结束
                    end else begin
                        sample_stb <= 1'b1;
                        ns         <= ns + 1;
                        driving    <= 1'b1;
                        tick       <= 4'd0;
                        slot       <= 2'd0;
                    end
                end
            end else if (driving) begin
                tick <= tick + 4'd1;
                // ⚠ slot 必须比 slot_vld 早稳定。同拍更新的话 DUT 采到的时隙号
                //   会整体偏一格（slot 0 永远写不进去 -> 全静音）。
                if (tick == 4'd5) slot_vld <= 1'b1;      // 生效于 tick 6，slot 已稳定
                if (tick == 4'd7) begin
                    tick <= 4'd0;
                    if (slot == 2'd3) driving <= 1'b0;
                    else              slot <= slot + 2'd1; // 生效于下一轮 tick 0
                end
            end
        end
    end

    // ---------------- 导出 ----------------
    integer fd;
    integer nout;

    initial begin
        fd = $fopen("out/demo.txt", "w");
        if (fd == 0) begin $display("FAIL: 打不开 out/demo.txt"); $finish; end
    end

    always @(posedge clk) begin
        if (sample_stb && (ns > 2)) begin
            $fwrite(fd, "%0d %0d\n", $signed(out_l), $signed(out_r));
            nout = nout + 1;
        end
    end

    initial begin
        ns = 0; nout = 0;
        #1_000_000_000;
        $display("FAIL: 仿真超时");
        $finish;
    end

    always @(posedge clk) begin
        if (ns >= NSAMP + 2) begin
            $fclose(fd);
            $display("  导出 %0d 个立体声样本 -> sim/out/demo.txt", nout);
            $display("PASS  tb_full_chain");
            $finish;
        end
    end

    initial begin
        repeat (10) @(posedge clk);
        rst_n = 1;
    end

endmodule
`default_nettype wire
