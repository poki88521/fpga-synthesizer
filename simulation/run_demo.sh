#!/bin/sh
# 模块三（通道处理层 + 全局处理层）全链 demo：编译 -> 仿真 -> 导出 WAV
#
# 用法：  sh simulation/run_demo.sh
# 依赖：  iverilog（PATH 或 IV=<dir> 指定）、python（python3 优先，退回 python）
#
# 目录约定：
#   rtl/            可综合代码，按层分子目录 —— 所以下面递归收集，不能用 rtl/*.v
#   simulation/models/  仿真模型（gowin_prim_stub.v 等，需从 Gowin 安装目录或工作机拷入）
#   simulation/tb/      testbench
#   simulation/out/     仿真产物（已忽略，不入库）
set -e
HERE=$(cd "$(dirname "$0")" && pwd)      # simulation/
ROOT=$(cd "$HERE/.." && pwd)             # 仓库根

# iverilog 定位顺序：环境变量 IV > PATH > 仓库近邻的 iverilog/bin
# （工作机装在 /work/.tools/iverilog/bin，可用 IV=... 覆盖，不必改脚本）
# 注：本机 iverilog 在仓库根的**上两级**（F:\...\FPGA_music\iverilog\bin）。
if [ -n "$IV" ] && [ -x "$IV/iverilog" ]; then
    :
elif command -v iverilog >/dev/null 2>&1; then
    IV=$(dirname "$(command -v iverilog)")
elif [ -x "$ROOT/../../iverilog/bin/iverilog" ]; then
    IV="$ROOT/../../iverilog/bin"
elif [ -x "$ROOT/../iverilog/bin/iverilog" ]; then
    IV="$ROOT/../iverilog/bin"
else
    echo "FAIL: 找不到 iverilog。请装好并加进 PATH，或用 IV=/path/to/iverilog/bin 指定。"
    exit 1
fi

# python 定位：优先 python3，不可用则退回 python
if command -v python3 >/dev/null 2>&1 && python3 -c '' >/dev/null 2>&1; then
    PY=python3
elif command -v python >/dev/null 2>&1; then
    PY=python
else
    echo "FAIL: 找不到可用的 python。"
    exit 1
fi
echo "iverilog: $IV    python: $PY"
mkdir -p "$HERE/out"

echo "== 1. 编译 =="
RTL=$(find "$ROOT/rtl" -name '*.v' | sort)
if [ -z "$RTL" ]; then
    echo "FAIL: rtl/ 下没有 .v 文件"
    exit 1
fi
"$IV/iverilog" -g2012 -DSIMULATION -s tb_full_chain \
    -o "$HERE/out/demo.vvp" \
    "$ROOT/simulation/models/gowin_prim_stub.v" $RTL "$HERE/tb/tb_full_chain.v"

echo "== 2. 仿真（比较慢，约 1 秒音频要跑几分钟）=="
cd "$HERE" && "$IV/vvp" out/demo.vvp

echo "== 3. 转 WAV =="
# 采样率沿用原先的 48828：TB 是自定时序（仿真时钟 50 MHz），与真机的
# 48 kHz / 49.152 MHz 口径不同，见 documents/技术文档.md §六。
"$PY" "$HERE/tools/wav.py" "$HERE/out/demo.txt" "$HERE/out/demo.wav" 48828
