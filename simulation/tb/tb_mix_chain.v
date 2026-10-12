//============================================================================
//  tb_mix_chain —— 效果发送总线 + 主混音求和 联合验证
//
//  驱动一条已知的 16 通道串行流，同时喂给 send_bus 和 main_mix，
//  再与参考模型逐位比对：
//      3 条发送总线 x 2 声道 = 6 个值
//      主混音 L/R             = 2 个值
//
//  参考模型：
//      bus_b_X = sat24( ( Σ_c ch_X(c) * (send_b(c) << 8) + 2^14 ) >>> 15 )
//      main_X  = sat24( Σ_c ch_X(c) + fx_X )
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_mix_chain;

    localparam integer NCH = 16, AW = 24;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;                    // 50 MHz

    // ---------------- 通道数据模式 ----------------
    function signed [AW-1:0] cv_l; input [3:0] c; begin cv_l = 100000 + c*1000; end endfunction
    function signed [AW-1:0] cv_r; input [3:0] c; begin cv_r = -(100000 + c*1000); end endfunction
    function [6:0] s_rev; input [3:0] c; begin s_rev = 100 - c*5; end endfunction
    function [6:0] s_cho; input [3:0] c; begin s_cho = c*8;       end endfunction
    function [6:0] s_del; input [3:0] c; begin s_del = 7'd64;     end endfunction

    localparam signed [AW-1:0] FX_L = 24'sd500000;
    localparam signed [AW-1:0] FX_R = -24'sd500000;

    // ---------------- 激励：32 拍一帧，前 16 拍发通道流 ----------------
    reg [5:0]        drv;
    reg              ch_vld;
    reg  [3:0]       ch_addr;
    reg signed [AW-1:0] ch_l, ch_r;
    reg              fx_vld;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            drv <= 6'd31; ch_vld <= 1'b0; ch_addr <= 4'd0;
            ch_l <= 24'sd0; ch_r <= 24'sd0; fx_vld <= 1'b0;
        end else begin
            drv <= drv + 6'd1;
            ch_vld <= (drv < 16);
            ch_addr<= drv[3:0];
            ch_l   <= cv_l(drv[3:0]);
            ch_r   <= cv_r(drv[3:0]);
            fx_vld <= (drv == 6'd20);
        end
    end

    // ---------------- 通道状态表的发送量（打包） ----------------
    reg [NCH*7-1:0] send_rev, send_cho, send_del;
    integer k;
    always @(posedge clk) begin
        for (k = 0; k < NCH; k = k + 1) begin
            send_rev[k*7 +: 7] <= s_rev(k[3:0]);
            send_cho[k*7 +: 7] <= s_cho(k[3:0]);
            send_del[k*7 +: 7] <= s_del(k[3:0]);
        end
    end

    // ---------------- DUT ----------------
    wire                  bus_vld;
    wire signed [AW-1:0]  bus_rev_l, bus_rev_r, bus_cho_l, bus_cho_r, bus_del_l, bus_del_r;

    send_bus #(.NCH(NCH), .AW(AW)) u_send (
        .clk(clk), .rst_n(rst_n), .frame_stb(1'b0),
        .ch_vld(ch_vld), .ch_addr(ch_addr), .ch_l(ch_l), .ch_r(ch_r),
        .send_rev(send_rev), .send_cho(send_cho), .send_del(send_del),
        .bus_vld(bus_vld),
        .bus_rev_l(bus_rev_l), .bus_rev_r(bus_rev_r),
        .bus_cho_l(bus_cho_l), .bus_cho_r(bus_cho_r),
        .bus_del_l(bus_del_l), .bus_del_r(bus_del_r)
    );

    wire                  mix_vld;
    wire signed [AW-1:0]  main_l, main_r;

    main_mix #(.NCH(NCH), .AW(AW)) u_mix (
        .clk(clk), .rst_n(rst_n), .frame_stb(1'b0),
        .ch_vld(ch_vld), .ch_addr(ch_addr), .ch_l(ch_l), .ch_r(ch_r),
        .fx_l(FX_L), .fx_r(FX_R), .fx_vld(fx_vld),
        .mix_vld(mix_vld), .main_l(main_l), .main_r(main_r)
    );

    // ---------------- 参考模型 ----------------
    function automatic signed [AW-1:0] tsat24;
        input signed [47:0] v;
        begin
            if      (v >  48'sd8388607) tsat24 = 24'sh7FFFFF;
            else if (v < -48'sd8388608) tsat24 = 24'sh800000;
            else                        tsat24 = v[AW-1:0];
        end
    endfunction

    task ref_bus;
        input  integer which;         // 0=rev 1=cho 2=del
        input  integer side;          // 0=L 1=R
        output signed [AW-1:0] e;
        integer i;
        reg signed [47:0] acc;
        reg signed [39:0] prod;
        reg signed [AW-1:0] x;
        reg signed [15:0]   sq;
        reg [6:0] s7;
        begin
            acc = 48'sd0;
            for (i = 0; i < NCH; i = i + 1) begin
                x  = (side == 0) ? cv_l(i[3:0]) : cv_r(i[3:0]);
                s7 = (which == 0) ? s_rev(i[3:0]) :
                     (which == 1) ? s_cho(i[3:0]) : s_del(i[3:0]);
                sq = $signed({1'b0, s7}) <<< 8;
                prod = x * sq;
                acc  = acc + {{8{prod[39]}}, prod};
            end
            e = tsat24((acc + 48'sd16384) >>> 15);
        end
    endtask

    task ref_main;
        input  integer side;
        output signed [AW-1:0] e;
        integer i;
        reg signed [47:0] acc;
        reg signed [AW-1:0] x;          // 不能对条件表达式直接取位，先存下来
        begin
            acc = 48'sd0;
            for (i = 0; i < NCH; i = i + 1) begin
                x   = (side == 0) ? cv_l(i[3:0]) : cv_r(i[3:0]);
                acc = acc + {{24{x[AW-1]}}, x};
            end
            x   = (side == 0) ? FX_L : FX_R;
            acc = acc + {{24{x[AW-1]}}, x};
            e = tsat24(acc);
        end
    endtask

    // ---------------- 检查 ----------------
    integer errs = 0, nchk = 0, nbus = 0, nmix = 0;

    reg signed [AW-1:0] e0,e1,e2,e3,e4,e5,em0,em1;

    initial begin
        #2_000_000;
        $display("FAIL  tb_mix_chain: 仿真超时");
        $finish;
    end

    always @(posedge clk) begin
        if (bus_vld) begin
            ref_bus(0,0,e0); ref_bus(0,1,e1);
            ref_bus(1,0,e2); ref_bus(1,1,e3);
            ref_bus(2,0,e4); ref_bus(2,1,e5);
            nchk = nchk + 6; nbus = nbus + 1;
            if (bus_rev_l !== e0) begin $display("  FAIL rev_l got=%0d exp=%0d",bus_rev_l,e0); errs=errs+1; end
            if (bus_rev_r !== e1) begin $display("  FAIL rev_r got=%0d exp=%0d",bus_rev_r,e1); errs=errs+1; end
            if (bus_cho_l !== e2) begin $display("  FAIL cho_l got=%0d exp=%0d",bus_cho_l,e2); errs=errs+1; end
            if (bus_cho_r !== e3) begin $display("  FAIL cho_r got=%0d exp=%0d",bus_cho_r,e3); errs=errs+1; end
            if (bus_del_l !== e4) begin $display("  FAIL del_l got=%0d exp=%0d",bus_del_l,e4); errs=errs+1; end
            if (bus_del_r !== e5) begin $display("  FAIL del_r got=%0d exp=%0d",bus_del_r,e5); errs=errs+1; end
        end
        if (mix_vld) begin
            ref_main(0,em0); ref_main(1,em1);
            nchk = nchk + 2; nmix = nmix + 1;
            if (main_l !== em0) begin $display("  FAIL main_l got=%0d exp=%0d",main_l,em0); errs=errs+1; end
            if (main_r !== em1) begin $display("  FAIL main_r got=%0d exp=%0d",main_r,em1); errs=errs+1; end
        end
        if ((nbus >= 3) && (nmix >= 3) && !errs) begin
            $display("  send_bus : %0d 帧 x 6 个总线值", nbus);
            $display("  main_mix : %0d 帧 x 2 个主输出值", nmix);
            $display("PASS  tb_mix_chain: %0d 次比对全部一致", nchk);
            $finish;
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
    end

endmodule
`default_nettype wire
