#!/bin/sh
# 模块三（通道处理层 + 全局处理层）全链 demo：编译 -> 仿真 -> 导出 WAV
#
# 用法：  sh sim/run_demo.sh
# 依赖：  iverilog（工作机上装在 /work/.tools/iverilog/bin）、python3
#
# 目录约定：
#   rtl/            可综合代码，按层分子目录 —— 所以下面递归收集，不能用 rtl/*.v
#   sim/models/     仿真模型（gowin_prim_stub.v 等，需从 Gowin 安装目录或工作机拷入）
#   sim/tb/         testbench
#   sim/out/        仿真产物（已忽略，不入库）
set -e
IV=/work/.tools/iverilog/bin
HERE=$(cd "$(dirname "$0")" && pwd)      # sim/
ROOT=$(cd "$HERE/.." && pwd)             # 仓库根
mkdir -p "$HERE/out"

echo "== 1. 编译 =="
RTL=$(find "$ROOT/rtl" -name '*.v' | sort)
if [ -z "$RTL" ]; then
    echo "FAIL: rtl/ 下没有 .v 文件"
    exit 1
fi
"$IV/iverilog" -g2012 -DSIMULATION -s tb_full_chain \
    -o "$HERE/out/demo.vvp" \
    "$ROOT/sim/models/gowin_prim_stub.v" $RTL "$HERE/tb/tb_full_chain.v"

echo "== 2. 仿真（比较慢，约 1 秒音频要跑几分钟）=="
cd "$HERE" && "$IV/vvp" out/demo.vvp

echo "== 3. 转 WAV =="
# 采样率沿用原先的 48828：TB 是自定时序（仿真时钟 50 MHz），与真机的
# 48 kHz / 49.152 MHz 口径不同，见 docs/技术文档.md §六。
python3 "$HERE/tools/wav.py" "$HERE/out/demo.txt" "$HERE/out/demo.wav" 48828
