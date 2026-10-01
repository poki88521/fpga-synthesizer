# 基于 FPGA 的实时多音色合成电子乐器引擎
项目具体内容详见[技术文档](documents\技术文档.md)
目录结构：
```
fpga-synthesizer/
├── documents/            设计文档
│   ├── 技术文档.md         总体设计（架构 / 状态表 / 调度与时序）
│   ├── MIDI协议.md         MIDI 协议说明
│   ├── 模块速查表.md       各模块的输入 / 输出 / 职责（开发协作用）
│   ├── 要求.md            赛题要求
│   └── 要求.docx          赛题要求（打印版）
├── drawio/               架构图
│   └── fpga内部架构.drawio
├── src/                  Verilog 源码
├── wave_table/           波表文件及有关python程序
├── material/             相关资料（开发板原理图等，不纳入版本管理）
└── scratch/              草稿（不纳入版本管理）
```
