module led_heartbeat (
    input  wire clk,
    output wire led
);
    reg [24:0] cnt;
    always @(posedge clk)
        cnt <= cnt + 25'd1;
    assign led = cnt[24];
endmodule