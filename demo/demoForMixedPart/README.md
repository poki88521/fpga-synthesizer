# 模块三 Demo（试听成品）

「通道处理层 + 全局处理层」全链仿真 demo 的**输出成品**，可以直接播放：

| 文件 | 说明 |
|---|---|
| `out/demo.wav` | 导出的音频（16-bit 立体声） |
| `out/demo.txt` | 中间产物，每行 `左 右` 两个 16-bit 有符号整数 |

仿真脚本、testbench 与当前状态（已知问题 / 下一步）都在 [`simulation/README.md`](../../simulation/README.md)。

重跑：`sh simulation/run_demo.sh` —— 新的生成物写到 `simulation/out/`，不会覆盖这里的成品。
