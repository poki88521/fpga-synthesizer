# 基于 FPGA 的实时多音色合成电子乐器引擎

项目具体内容详见[技术文档](docs/技术文档.md)。

## 目录结构

```
fpga-synthesizer/
├── rtl/                  可综合 Verilog（按设计四层分子目录；rtl/ 下所有 *.v 一起综合）
│   ├── common/           通用模块（归一化/饱和、隔直、PT8211 串行发送、复位同步…）
│   ├── voice/            单声部处理层（DDS + 波表、SVF、ADSR、VCA）
│   ├── channel/          通道处理层（通道缓存/系数/累加、效果发送总线）
│   ├── global/           全局处理层（混响/合唱/延迟、主混音、主输出）
│   ├── sched/            调度层（MIDI 解析、状态表编辑、音色映射、声部分配/时序/取数）
│   └── top/              顶层与约束（synth_top、PLL/时钟配置、.cst/.sdc）
├── sim/                  仿真
│   ├── tb/               testbench（tb_full_chain.v 等）
│   ├── models/           厂商原语仿真模型（gowin_prim_stub.v 等，不入库）
│   ├── tools/            wav.py 等仿真辅助脚本
│   ├── run_demo.sh       一键：编译 → 仿真 → 转 WAV
│   └── out/              仿真产物（不入库）
├── board/                板级外设验证工程，每个 *_test/ 一个 Gowin 工程（.v + .cst + .sdc）
├── docs/                 设计文档
│   ├── 技术文档.md         总体设计（架构 / 状态表 / 调度与时序）
│   ├── 硬件实现.md         时钟复位 / 引脚 / 定点口径 / 波表 ROM
│   ├── MIDI协议.md         MIDI 协议说明
│   ├── 要求.md            赛题要求
│   └── 要求.docx          赛题要求（打印版）
├── drawio/               架构图
├── wave_table/           波表转换（convert.py + 输入 wav），生成物进 wave_table/out/（不入库）
├── demo/                 各模块 demo 的成品与说明（试听用）
│   └── demoForMixedPart/ 模块三（通道 + 全局处理层）试听成品
├── material/             厂商资料与本地素材（不纳入版本管理）
└── scratch/              组内草稿与交流文档
```

## 约定

- **生成物不入库**：波表生成文件（`.coe` / `.hex` / `.mif`）、仿真输出等统一放进对应层级的 `out/`，
  由 `.gitignore` 忽略，需要时按下面命令重新生成。
- **可综合代码与板级测试分开**：`rtl/` 只放设计代码，`board/` 放各外设验证工程，
  避免一键编译时把测试顶层一起吃进去。
- `scratch/` 下的文档（除 `agent/`）由人工维护，agent 只读。

## 常用命令

```sh
# 跑模块三全链仿真 demo（需要 iverilog 与 python3）
sh sim/run_demo.sh

# 重新生成波表 ROM 初始化文件（需要 numpy / soundfile / scipy）
cd wave_table && python3 convert.py
```
