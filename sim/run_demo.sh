#!/bin/sh
# 模块三全链 demo：编译 -> 仿真 -> 导出 WAV
#
# 用法：  sh demo/run_demo.sh [样本数]
# 依赖：  iverilog（装在 /work/.tools/iverilog/bin），python3
#
# 说明：  这个 demo 只用 rtl/ 和 sim/gowin_prim_stub.v，不改动任何源文件。
set -e
IV=/work/.tools/iverilog/bin
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
mkdir -p "$HERE/out"

echo "== 1. 编译 =="
"$IV/iverilog" -g2012 -DSIMULATION -s tb_full_chain \
    -o "$HERE/out/demo.vvp" \
    "$ROOT/sim/gowin_prim_stub.v" "$ROOT/rtl/"*.v "$HERE/tb_full_chain.v"

echo "== 2. 仿真（比较慢，约 1 秒音频要跑几分钟）=="
cd "$HERE" && "$IV/vvp" out/demo.vvp

echo "== 3. 转 WAV =="
python3 "$HERE/wav.py" "$HERE/out/demo.txt" "$HERE/out/demo.wav" 48828
