//============================================================================
//  tb_chan_layer —— 通道处理层验证
//
//  三个场景，每个跑 2 帧，把 16 条通道的 L/R 与参考模型**逐位**比对：
//      场景 0：32 个声部按 v%16 分散到 16 条通道，参数中等
//      场景 1：同上，但参数变成小音量 + 硬左声像（pan_gR = 0）
//      场景 2：32 个声部**全挂通道 0**（测大累加），并关掉 2 个声部的 vld
//
//  参考模型独立地按文档的定点规格重算一遍：
//      ChAcc[c] = Σ 有效声部(该通道) aud          （32-bit 有符号）
//      a24      = sat24(ChAcc[c])
//      vol_q    = volume << 8 ;  exp_q = expression << 8
//      g_ch     = sat16( (vol_q * exp_q) >>> 15 )
//      gL/gR    = sat16( (g_ch * pan_gX) >>> 15 )
//      ChL/ChR  = sat24( (a24 * gX + 2^14) >>> 15 )
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_chan_layer;

    localparam integer P = 8, G = 4, AW = 24, CW = 4, NCH = 16, N = 32, SW = 2;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;                       // 50 MHz

    // ---------------- 场景参数 ----------------
    reg [1:0] scen;

    function [6:0] p_vol; input [1:0] s; begin
        case (s) 0: p_vol = 7'd127; 1: p_vol = 7'd64; 2: p_vol = 7'd127; default: p_vol = 7'd127; endcase
    end endfunction
    function [6:0] p_exp; input [1:0] s; begin
        case (s) 0: p_exp = 7'd127; 1: p_exp = 7'd100; 2: p_exp = 7'd127; default: p_exp = 7'd127; endcase
    end endfunction
    function signed [15:0] p_pl; input [1:0] s; begin
        case (s) 0: p_pl = 16'sd23170; 1: p_pl = 16'sd32767; 2: p_pl = 16'sd16384; default: p_pl = 16'sd23170; endcase
    end endfunction
    function signed [15:0] p_pr; input [1:0] s; begin
        case (s) 0: p_pr = 16'sd23170; 1: p_pr = 16'sd0; 2: p_pr = 16'sd16384; default: p_pr = 16'sd23170; endcase
    end endfunction

    // ---------------- 声部数据模式 ----------------
    function signed [23:0] pat_aud; input integer v; input [1:0] s; begin
        case (s)
            0, 1: pat_aud = 100000 - v*1000;      // 注意：不能写 24'sd(表达式)
            2:    pat_aud = 24'sd250000;
            default: pat_aud = 24'sd0;
        endcase
    end endfunction
    function [3:0] pat_ch; input integer v; input [1:0] s; begin
        case (s) 0, 1: pat_ch = v % 16;
                 2:    pat_ch = 4'd0;
                 default: pat_ch = 4'd0; endcase
    end endfunction
    function pat_vld; input integer v; input [1:0] s; begin
        case (s) 0, 1: pat_vld = 1'b1;
                 2:    pat_vld = (v != 5) && (v != 17);
                 default: pat_vld = 1'b1; endcase
    end endfunction

    // ---------------- DUT 接口 ----------------
    reg                  slot_vld;
    reg  [SW-1:0]        slot;
    reg  [P-1:0]         vld;
    reg  [P*CW-1:0]      ch_in;
    reg  [P*AW-1:0]      aud_in;
    reg                  frame_stb;

    reg  [NCH*7-1:0]     volume, expression;
    reg signed [NCH*16-1:0] pan_gL, pan_gR;

    wire                 ch_vld, frame_done;
    wire [CW-1:0]        ch_addr;
    wire signed [AW-1:0] ch_l, ch_r;

    chan_layer #(.P(P), .G(G), .AW(AW), .CW(CW), .NCH(NCH), .SW(SW)) dut (
        .clk(clk), .rst_n(rst_n), .frame_stb(frame_stb),
        .slot_vld(slot_vld), .slot(slot), .vld(vld), .ch_in(ch_in), .aud_in(aud_in),
        .volume(volume), .expression(expression), .pan_gL(pan_gL), .pan_gR(pan_gR),
        .ch_vld(ch_vld), .ch_addr(ch_addr), .ch_l(ch_l), .ch_r(ch_r),
        .frame_done(frame_done)
    );

    // ---------------- 泳道数据（组合，随 seq 变化） ----------------
    genvar gi;
    generate
        for (gi = 0; gi < P; gi = gi + 1) begin : g_lane
            wire [4:0] vidx = {slot, 3'b000} + gi[4:0];   // 声部号 = slot*8 + lane
            assign vld[gi]             = pat_vld(vidx, scen);
            assign ch_in[gi*CW +: CW]  = pat_ch (vidx, scen);
            assign aud_in[gi*AW +: AW] = pat_aud(vidx, scen);
        end
    endgenerate

    // ---------------- 参数（每通道略不同，验证按通道独立存系数） ----------------
    integer k;
    always @(posedge clk) begin
        for (k = 0; k < NCH; k = k + 1) begin
            volume    [k*7  +: 7 ] <= (p_vol(scen) > k[6:0]) ? (p_vol(scen) - k[6:0]) : 7'd1;
            expression[k*7  +: 7 ] <= p_exp(scen);
            pan_gL    [k*16 +: 16] <= p_pl(scen);
            pan_gR    [k*16 +: 16] <= p_pr(scen);
        end
    end

    // ---------------- 参考模型 ----------------
    function automatic signed [15:0] tsat16;
        input signed [31:0] v;
        begin
            if      (v >  32'sd32767) tsat16 = 16'sh7FFF;
            else if (v < -32'sd32768) tsat16 = 16'sh8000;
            else                      tsat16 = v[15:0];
        end
    endfunction
    function automatic signed [23:0] tsat24;
        input signed [47:0] v;
        begin
            if      (v >  48'sd8388607) tsat24 = 24'sh7FFFFF;
            else if (v < -48'sd8388608) tsat24 = 24'sh800000;
            else                        tsat24 = v[23:0];
        end
    endfunction

    task ref_calc;
        input  integer  c;
        output signed [23:0] el;
        output signed [23:0] er;
        integer i;
        reg signed [31:0] acc;
        reg signed [23:0] a24;
        reg signed [23:0] atmp;
        reg signed [15:0] gch, gl, gr;
        reg signed [6:0]  vv, ee;
        begin
            acc = 32'sd0;
            for (i = 0; i < N; i = i + 1) begin
                if (pat_vld(i, scen) && (pat_ch(i, scen) == c[3:0])) begin
                    atmp = pat_aud(i, scen);        // 不能对函数返回值直接取位
                    acc  = acc + {{8{atmp[23]}}, atmp};
                end
            end
            a24 = tsat24(acc);
            vv  = (p_vol(scen) > c[6:0]) ? (p_vol(scen) - c[6:0]) : 7'd1;
            ee  = p_exp(scen);
            gch = tsat16(($signed({1'b0,vv}) <<< 8) * ($signed({1'b0,ee}) <<< 8) >>> 15);
            gl  = tsat16((gch * p_pl(scen)) >>> 15);
            gr  = tsat16((gch * p_pr(scen)) >>> 15);
            el  = tsat24((a24 * gl + 48'sd16384) >>> 15);
            er  = tsat24((a24 * gr + 48'sd16384) >>> 15);
        end
    endtask

    // ---------------- 输出捕获 ----------------
    reg signed [23:0] got_l [0:NCH-1];
    reg signed [23:0] got_r [0:NCH-1];

    always @(posedge clk) begin
        if (ch_vld) begin
            got_l[ch_addr] <= ch_l;
            got_r[ch_addr] <= ch_r;
        end
    end

    // ---------------- 主控 ----------------
    localparam [2:0] PH_LOAD = 0, PH_SETTLE = 1, PH_DRIVE = 2,
                     PH_WAIT = 3, PH_CHECK = 4, PH_NEXT = 5;

    reg [2:0]  ph;
    reg [7:0]  tick;
    reg [1:0]  seq;
    reg [1:0]  fcnt;

    integer errs     = 0;
    integer checked  = 0;

    // 看门狗
    initial begin
        #5_000_000;
        $display("FAIL  tb_chan_layer: 仿真超时");
        $finish;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ph <= PH_LOAD; tick <= 8'd0; seq <= 2'd0; fcnt <= 2'd0;
            scen <= 2'd0; slot <= 2'd0; slot_vld <= 1'b0; frame_stb <= 1'b0;
        end else begin
            slot_vld  <= 1'b0;
            frame_stb <= 1'b0;

            case (ph)
                PH_LOAD: begin
                    if (tick == 8'd0) $display("  --- 场景 %0d ---", scen);
                    tick <= tick + 8'd1;
                    if (tick == 8'd3) begin ph <= PH_SETTLE; tick <= 8'd0; end
                end

                PH_SETTLE: begin        // 等系数自由运行的流水线刷新一遍
                    tick <= tick + 8'd1;
                    if (tick == 8'd63) begin
                        ph <= PH_DRIVE; tick <= 8'd0; seq <= 2'd0;
                        slot <= 2'd0;
                        frame_stb <= 1'b1;      // 帧起始
                    end
                end

                PH_DRIVE: begin
                    // ⚠ slot 必须先稳定，再打 slot_vld。
                    //   两者同拍更新的话，DUT 采到的时隙号会整体偏一格
                    //   （slot 0 永远写不进去，最后一个 slot 被写两次）。
                    tick <= tick + 8'd1;
                    if (tick == 8'd1) slot <= seq;       // 提前 2 拍摆好时隙号
                    if (tick == 8'd3) begin
                        tick     <= 8'd0;
                        slot_vld <= 1'b1;                // 下一拍生效，此时 slot 已稳定
                        if (seq == G-1) begin ph <= PH_WAIT; end
                        else seq <= seq + 2'd1;
                    end
                end

                PH_WAIT: begin
                    if (frame_done) begin ph <= PH_CHECK; end
                end

                PH_CHECK: begin
                    for (k = 0; k < NCH; k = k + 1) begin
                        reg signed [23:0] el, er;
                        ref_calc(k, el, er);
                        checked = checked + 1;
                        if ((got_l[k] !== el) || (got_r[k] !== er)) begin
                            if (errs < 10)
                                $display("  FAIL ch%0d L got=%0d exp=%0d | R got=%0d exp=%0d",
                                         k, got_l[k], el, got_r[k], er);
                            errs = errs + 1;
                        end
                    end
                    if (fcnt == 2'd1) begin ph <= PH_NEXT; end
                    else begin fcnt <= fcnt + 2'd1; ph <= PH_DRIVE; tick <= 8'd0; seq <= 2'd0; slot <= 2'd0; end
                end

                PH_NEXT: begin
                    fcnt <= 2'd0; tick <= 8'd0;
                    if (scen == 2'd2) begin
                        if (errs == 0)
                            $display("PASS  tb_chan_layer: %0d 次通道比对全部一致（3 场景 x 2 帧 x 16 通道）", checked);
                        else
                            $display("FAIL  tb_chan_layer: %0d / %0d 不一致", errs, checked);
                        $finish;
                    end else begin
                        scen <= scen + 2'd1;
                        ph <= PH_LOAD;
                    end
                end

                default: ph <= PH_LOAD;
            endcase
        end
    end

    // 采样途中把结果打印出来（便于人工核对场景 1 的硬左声像）
    initial begin
        repeat (2) @(posedge clk);
        rst_n = 1;
    end

endmodule
`default_nettype wire
