// [2026-10-05 21:15]  本文件时间戳（用于校验是否被外部覆盖）
//=============================================================
//  i2c_mst —— 极简 I2C 主机（只写，单次：dev + reg + data）
//  用途：配置 MS5351（Si5351 兼容）
//  SCL 频率 = CLK_HZ / (I2C_HZ * 4)；默认 50 MHz / 100 kHz
//  时序：START -> dev(8)+ACK -> reg(8)+ACK -> data(8)+ACK -> STOP
//
//  ACK 检测：每收到一个字节后，在 SCL 高电平期间采样 SDA。
//            SDA 为高（未被从机拉低）= NACK -> 置 ack_err 并中止本次传输。
//    ack_err 是「本次传输」的结果标志：在 go 被接受时清零，检测到 NACK 时置 1；
//    由 done 之后读取。这样上层可以对每个 mux 档位分别判断成功/失败。
//=============================================================
module i2c_mst #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer I2C_HZ = 100_000
)(
    input  wire       clk,
    input  wire       rst,      // 高有效
    input  wire       go,       // 单拍启动（需在 IDLE）
    input  wire [7:0] dev_w,    // 从机写地址，MS5351 = 8'hC0
    input  wire [7:0] reg_a,
    input  wire [7:0] dat,
    output reg        done,     // 完成单拍（含 NACK 情况）
    output reg        ack_err,  // 本次传输是否出现 NACK（go 时清零）
    output reg        scl,
    inout             sda
);
    localparam integer QD = CLK_HZ/(I2C_HZ*4);   // 每相位拍数

    localparam S_IDLE = 3'd0,
               S_STRT = 3'd1,
               S_BYTE = 3'd2,
               S_ACK  = 3'd3,
               S_STOP = 3'd4,
               S_DONE = 3'd5;

    reg [2:0]  st;
    reg [15:0] pc;
    reg [2:0]  ph;
    reg [2:0]  bi;
    reg [1:0]  byi;
    reg [7:0]  shf;
    reg        sda_o;
    reg        sda_t;
    reg        ack_bit;    // 本次字节的 ACK 采样值

    assign sda = sda_t ? sda_o : 1'bz;

    wire tick = (pc == QD-1);

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; pc <= 0; ph <= 0; bi <= 0; byi <= 0;
            scl <= 1'b1; sda_o <= 1'b1; sda_t <= 1'b0;
            done <= 1'b0; ack_err <= 1'b0; ack_bit <= 1'b0;
        end else begin
            done <= 1'b0;
            case (st)
            S_IDLE: begin
                scl <= 1'b1; sda_o <= 1'b1; sda_t <= 1'b1;
                if (go) begin st <= S_STRT; pc <= 0; ph <= 0; ack_err <= 1'b0; end
            end
            S_STRT: begin
                if (tick) begin
                    pc <= 0;
                    if (ph == 0)      begin sda_o <= 1'b1; scl <= 1'b1; ph <= 1; end
                    else if (ph == 1) begin sda_o <= 1'b0; ph <= 2; end      // SDA 下降 = START
                    else if (ph == 2) begin scl <= 1'b0;  ph <= 3; end
                    else              begin st <= S_BYTE; ph <= 0; bi <= 0; byi <= 0; shf <= dev_w; end
                end else pc <= pc + 1'b1;
            end
            S_BYTE: begin
                if (tick) begin
                    pc <= 0;
                    if (ph == 0)      begin sda_t <= 1'b1; sda_o <= shf[7]; scl <= 1'b0; ph <= 1; end
                    else if (ph == 1) begin scl <= 1'b1; ph <= 2; end
                    else if (ph == 2) begin scl <= 1'b1; shf <= {shf[6:0],1'b0}; ph <= 3; end
                    else begin
                        scl <= 1'b0; ph <= 0;
                        if (bi == 3'd7) begin st <= S_ACK; bi <= 0; end
                        else bi <= bi + 1'b1;
                    end
                end else pc <= pc + 1'b1;
            end
            S_ACK: begin
                if (tick) begin
                    pc <= 0;
                    if (ph == 0)      begin sda_t <= 1'b0; scl <= 1'b0; ph <= 1; end   // 释放 SDA
                    else if (ph == 1) begin scl <= 1'b1; ph <= 2; end
                    else if (ph == 2) begin scl <= 1'b1; ph <= 3; ack_bit <= sda; end // SCL 高时采样 ACK
                    else begin
                        scl <= 1'b0; ph <= 0;
                        if (ack_bit) begin
                            // NACK：置本次错误标志并中止本次传输
                            ack_err <= 1'b1;
                            st <= S_STOP;
                        end else begin
                            case (byi)
                            2'd0:    begin shf <= reg_a; byi <= 2'd1; st <= S_BYTE; end
                            2'd1:    begin shf <= dat;   byi <= 2'd2; st <= S_BYTE; end
                            default: begin st <= S_STOP; end
                            endcase
                        end
                    end
                end else pc <= pc + 1'b1;
            end
            S_STOP: begin
                if (tick) begin
                    pc <= 0;
                    if (ph == 0)      begin scl <= 1'b0; sda_o <= 1'b0; sda_t <= 1'b1; ph <= 1; end
                    else if (ph == 1) begin scl <= 1'b1; ph <= 2; end
                    else if (ph == 2) begin sda_o <= 1'b1; ph <= 3; end       // SDA 上升 = STOP
                    else              begin st <= S_DONE; ph <= 0; end
                end else pc <= pc + 1'b1;
            end
            S_DONE: begin
                done <= 1'b1; sda_t <= 1'b0; scl <= 1'b1;
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
