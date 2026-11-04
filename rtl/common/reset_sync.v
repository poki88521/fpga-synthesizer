//============================================================================
//  reset_sync —— 异步复位、同步释放
//
//  依据：documents/硬件实现.md §一.4「复位方案」
//        rst_n (异步) ──→ [触发器1] ──→ [触发器2] ──→ rst_sync_n
//  异步断言：复位到来立即生效，不依赖时钟
//  同步释放：释放沿与 f_clk 对齐，避免亚稳态
//
//  每个模块内部例化一份，把外部异步复位 rst_async_n 转成与 clk 同步的
//  rst_n_sync。所有时序逻辑使用 rst_n_sync 复位（不再直接用裸 rst_async_n）。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module reset_sync (
    input  wire clk,
    input  wire rst_async_n,
    output wire rst_n_sync
);

    // 复位值固定为 0：断言期间强制为 0，释放时经两级同步后拉高
    (* async_reg = "true" *) reg rst_meta;
    (* async_reg = "true" *) reg rst_sync_r;

    always @(posedge clk or negedge rst_async_n) begin
        if (!rst_async_n) begin
            rst_meta   <= 1'b0;
            rst_sync_r <= 1'b0;
        end else begin
            rst_meta   <= 1'b1;
            rst_sync_r <= rst_meta;
        end
    end

    assign rst_n_sync = rst_sync_r;

endmodule

`default_nettype wire
