import numpy as np
import soundfile as sf
from scipy import signal
import os

# ---------- 你可以修改这里的参数 ----------
TARGET_LEN = 4096      # DDS 波表点数，你的是 4096
BIT_WIDTH = 12         # FPGA ROM 位宽，12 位
# 如果你的 FPGA 是 16 位，改成 16；8 位改成 8
#
# ⚠ 位宽口径待确认：documents/硬件实现.md §五 与 附录 A（技术文档）按
#   「8 张 × 4096 点 × 16 bit」规划波表，而本脚本当前是 12 位。
#   改动这个值会让所有已生成的 ROM 初始化文件全部变化，改之前先和文档口径对齐。

# 输入文件（与本脚本同目录）
# 如果下载的是立体声文件，脚本会自动取左声道
INPUT_FILES = {
    "piano": "S-Piano01-07.wav",   # 钢琴单周期 wav
    "guitar": "ElecSteelGtL-07.wav", # 吉他单周期 wav
}
# -----------------------------------------

# 路径都以本脚本所在目录为基准，这样在哪个工作目录下执行都一样
HERE    = os.path.dirname(os.path.abspath(__file__))
IN_DIR  = HERE                            # 输入 wav 与脚本同目录
OUT_DIR = os.path.join(HERE, "out")       # 生成物统一进 out/（该目录已被 .gitignore 忽略）

def process_wavetable(path, target_len, bit_width):
    """读取 wav，重采样，归一化，量化成有符号整数"""
    # 1. 读取 wav 文件
    data, sr = sf.read(path)
    # 如果是立体声（二维数组），只取左声道
    if len(data.shape) > 1:
        data = data[:, 0]
    print(f"  原始长度: {len(data)} 点，采样率: {sr} Hz")

    # 2. 归一化到 [-1, 1]
    data = data.astype(np.float64)
    data /= np.max(np.abs(data))

    # 3. 重采样到目标长度（4096 点）
    data = signal.resample(data, target_len)
    print(f"  重采样后长度: {len(data)} 点")

    # 4. 再次归一化，防止重采样后幅度变化
    data /= np.max(np.abs(data))

    # 5. 量化到指定位宽的有符号整数
    max_val = 2**(bit_width - 1) - 1   # 12 位: 2047
    min_val = -2**(bit_width - 1)      # 12 位: -2048
    data_int = np.round(data * max_val).astype(int)
    data_int = np.clip(data_int, min_val, max_val)
    return data_int

def write_coe(filename, data, bit_width):
    """生成 Xilinx Vivado 的 .coe 文件（十六进制补码）"""
    hex_digits = (bit_width + 3) // 4
    mask = (1 << bit_width) - 1
    with open(filename, 'w') as f:
        f.write('memory_initialization_radix = 16;\n')
        f.write('memory_initialization_vector =\n')
        vals = [f'{v & mask:0{hex_digits}X}' for v in data]
        f.write(',\n'.join(vals))
        f.write(';\n')
    print(f"  已生成: {filename}")

def write_mif(filename, data, bit_width):
    """生成 Intel/Altera Quartus 的 .mif 文件（十进制无符号补码）"""
    mask = (1 << bit_width) - 1
    depth = len(data)
    with open(filename, 'w') as f:
        f.write(f'WIDTH = {bit_width};\n')
        f.write(f'DEPTH = {depth};\n\n')
        f.write('ADDRESS_RADIX = DEC;\n')
        f.write('DATA_RADIX = DEC;\n\n')
        f.write('CONTENT BEGIN\n')
        for i, v in enumerate(data):
            f.write(f'    {i} : {v & mask};\n')
        f.write('END;\n')
    print(f"  已生成: {filename}")

def write_hex(filename, data, bit_width):
    """生成 .hex 文件，用于 Verilog $readmemh 初始化"""
    hex_digits = (bit_width + 3) // 4
    mask = (1 << bit_width) - 1
    with open(filename, 'w') as f:
        for v in data:
            f.write(f'{v & mask:0{hex_digits}X}\n')
    print(f"  已生成: {filename}")

# ========== 主程序 ==========
print("=" * 50)
print("波表转换工具 (WAV -> FPGA ROM 初始化文件)")
print("=" * 50)
print(f"输入目录: {IN_DIR}")
print(f"输出目录: {OUT_DIR}")
print("（生成物不入库，需要时重跑本脚本）")

os.makedirs(OUT_DIR, exist_ok=True)

all_data = {}

for name, filename in INPUT_FILES.items():
    in_path = os.path.join(IN_DIR, filename)
    if not os.path.exists(in_path):
        print(f"\n警告: 找不到文件 '{in_path}'，跳过。")
        print("请确保 wav 文件与本脚本放在同一目录，且文件名正确。")
        continue

    print(f"\n处理 [{name}] ...")
    data = process_wavetable(in_path, TARGET_LEN, BIT_WIDTH)
    all_data[name] = data

    # 为每个乐器单独生成文件
    write_coe(os.path.join(OUT_DIR, f"{name}.coe"), data, BIT_WIDTH)
    write_mif(os.path.join(OUT_DIR, f"{name}.mif"), data, BIT_WIDTH)
    write_hex(os.path.join(OUT_DIR, f"{name}.hex"), data, BIT_WIDTH)

# 可选：把所有波表拼接成一个大 ROM
if len(all_data) > 1:
    print("\n拼接所有波表到一个大 ROM...")
    combined = np.concatenate([all_data[k] for k in all_data.keys()])
    write_coe(os.path.join(OUT_DIR, "combined.coe"), combined, BIT_WIDTH)
    write_mif(os.path.join(OUT_DIR, "combined.mif"), combined, BIT_WIDTH)
    write_hex(os.path.join(OUT_DIR, "combined.hex"), combined, BIT_WIDTH)
    print(f"  合并后总深度: {len(combined)} 点")

print("\n完成！")
