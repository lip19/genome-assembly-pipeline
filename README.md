# Genome Assembly Pipeline (HiFi + Hi-C)

本项目是一个高度自动化的基因组组装流程，专为 HiFi 测序技术 结合 Hi-C 挂载 设计。它集成了从原始数据质控、Contig 组装到染色体级 Scaffolding 的全过程。

## 🌟 核心特性

- **AI 谱系探测**：BUSCO 自动识别最合适的 odb10 数据集（不再硬编码 mammalia）。
- **高兼容性编译**：setup_tools.sh 自动从源码编译 hifiasm，解决 Illegal instruction 崩溃。
- **全流程自动化**：一键完成从 Fastp 质控到 Juicebox 可视化文件的生成。
- **高性能优化**：针对 JSUB 集群（64 线程/500G 内存）进行了并行化调优。

## 📂 目录结构

```
genome-assembly-pipeline/
├── config/                # 核心配置文件 (config.sh)
├── scripts/               # 自动化脚本 (安装、运行、验证)
├── tools/                 # 存放编译产物及 juicer_tools.jar
├── database/              # 存放 BUSCO/Kraken 数据库
├── sequence_files/        # 原始测序数据 (FASTQ)
├── logs/                  # 运行日志
└── results/               # 最终分析结果
```

## 🚀 快速开始

### 1. 初始化环境

一键安装依赖并自动编译 hifiasm：

```bash
bash scripts/setup_tools.sh
```

注：脚本会使用 mamba 加速安装，并利用 Conda 内部编译器确保二进制文件的稳定性。

### 2. 激活并验证

安装完成后，请重新加载配置并运行验证脚本：

```bash
source ~/.bashrc  # 或 source ~/.zshrc
conda activate genome_assembly_env
bash scripts/validate_environment.sh
```

### 3. 修改配置

编辑 config/config.sh，设置您的物种名称和数据路径：

```bash
vim config/config.sh
```

关键参数：将 BUSCO_LINEAGE 设为 "auto" 即可开启 AI 自动识别谱系功能。

### 4. 运行组装

建议使用后台运行或提交集群任务：

```bash
nohup bash scripts/run_assembly.sh > pipeline.log 2>&1 &
```

## 🛠️ 流程详解

1. **质控 (Fastp)**：过滤 WGS 和 Hi-C 原始数据的接头与低质量碱基。
2. **组装 (Hifiasm)**：使用 HiFi + Hi-C 混合模式生成高质量 Primary Contigs。
3. **评估 (BUSCO)**：使用 Auto-lineage 模式，AI 自动对比不同谱系（如真兽类 vs 脊椎动物），选择最匹配的数据库评估完整度。
4. **比对 (Chromap)**：快速将 Hi-C Read 比对至组装好的 Contigs。
5. **挂载 (YAHS)**：利用 Hi-C 信号进行 Scaffolding，构建染色体水平序列。
6. **可视化 (Juicer)**：生成 .hic 文件，可直接导入 Juicebox 进行人工纠错。

## 📊 结果查看

- **最终组装序列**：results/07_yahs/yahs.out_scaffolds_final.fa
- **可视化文件**：results/08_juicer/<PROJECT_NAME>.hic
- **评估报告**：results/05_busco/short_summary.txt
- **质控报告**：results/01_fastp/wgs_fastp.html

## ⚠️ 注意事项

- **内存预警**：Juicer 处理 2Gb+ 基因组时，JVM 内存建议设置为 100G 以上（已在 config 预设）。
- **网络要求**：若开启 BUSCO_LINEAGE="auto" 且服务器无法联网，请提前手动下载 odb10 ��至 database/busco_db。
- **CPU 指令集**：如果更换了计算节点，建议重新运行 setup_tools.sh 以确保 hifiasm 的二进制文件与当前 CPU 指令集（AVX/AVX512）最优适配。