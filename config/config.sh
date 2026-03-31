#!/bin/bash
# ==============================================================================
# 基因组组装 Pipeline 核心配置文件
# ==============================================================================

# 1. 项目基础设置
export PROJECT_NAME="Dpil_Genome"
# 自动定位项目根目录 (无论在哪个文件夹下调用脚本)
export PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export THREADS=2
export CONDA_ENV_NAME="genome_assembly_env"

# 2. 输入数据路径 (请确保文件名与 sequence_files 目录下一致)
export DATA_DIR="${PROJECT_ROOT}/sequence_files"
export WGS_R1="${DATA_DIR}/WGS_R1.fastq.gz"
export WGS_R2="${DATA_DIR}/WGS_R2.fastq.gz"
export HIFI_READS="${DATA_DIR}/HiFi.fastq.gz"
export HIC_R1="${DATA_DIR}/Hi-C_R1.fastq.gz"
export HIC_R2="${DATA_DIR}/Hi-C_R2.fastq.gz"

# 3. 数据库与工具配置
export KRAKEN_DB="${PROJECT_ROOT}/database/kraken_db"
export BUSCO_DB="${PROJECT_ROOT}/database/busco_db"
export BUSCO_LINEAGE="auto" 
export JUICER_JAR="${PROJECT_ROOT}/tools/juicer_tools1.jar"
export JUICER_JVM_MEM="500G"
export HIC_ENZYME="GATC"

# 4. Pipeline 流程控制开关 (yes/no)
export RUN_FASTP="yes"
export RUN_KRAKEN="no"
export RUN_SURVEY="yes"
export RUN_HIFIASM="yes"
export RUN_BUSCO="yes"
export RUN_CHROMAP="yes"
export RUN_YAHS="yes"
export RUN_JUICER="yes"

# 5. 输出目录设置
export OUT_BASE="${PROJECT_ROOT}/results"
export FASTP_DIR="${OUT_BASE}/01_fastp"
export SURVEY_DIR="${OUT_BASE}/02_survey"
export HIFIASM_DIR="${OUT_BASE}/04_assembly"
export BUSCO_DIR="${OUT_BASE}/05_busco"
export CHROMAP_DIR="${OUT_BASE}/06_chromap"
export YAHS_DIR="${OUT_BASE}/07_yahs"
export JUICER_DIR="${OUT_BASE}/08_juicer"
export LOG_DIR="${PROJECT_ROOT}/logs"

# 6. 特定参数
export KMER_SIZE=21
export GENOME_SIZE_EST="1G"
export FASTP_MIN_LEN=145
