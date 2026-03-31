#!/bin/bash
# ==============================================================================
# 脚本名称: run_assembly.sh
# 功能: 基因组组装全流程自动化脚本 (HiFi + Hi-C)
# 开发者: Gemini Senior Engineer
# ==============================================================================

set -eo pipefail

# ------------------------------------------------------------------------------
# 0. 环境初始化与配置加载
# ------------------------------------------------------------------------------
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PROJECT_ROOT}/config.sh"

# 加载配置
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo -e "\033[31m[ERROR]\033[0m 找不到配置文件: $CONFIG_FILE"
    exit 1
fi

# 自动激活 Conda 环境
CONDA_BASE=$(conda info --base)
if [ -f "${CONDA_BASE}/etc/profile.d/conda.sh" ]; then
    source "${CONDA_BASE}/etc/profile.d/conda.sh"
    conda activate "${CONDA_ENV_NAME}"
else
    echo -e "\033[33m[WARN]\033[0m 无法定位 conda.sh，请确保手动激活环境: ${CONDA_ENV_NAME}"
fi

# 初始化输出目录与日志
mkdir -p "${LOG_DIR}" "${OUT_BASE}"
LOG_FILE="${LOG_DIR}/pipeline_$(date '+%Y%m%d_%H%M%S').log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# 统一日志函数
log() {
    local color="\033[34m" # Blue
    [[ "$1" == *"Step"* ]] && color="\033[32m" # Green for Steps
    echo -e "${color}[$(date '+%Y-%m-%d %H:%M:%S')] $1\033[0m"
}

log "========================================================"
log "开始运行 Dpil 基因组组装 Pipeline"
log "项目名称: ${PROJECT_NAME}"
log "根目录: ${PROJECT_ROOT}"
log "线程数: ${THREADS} | 内存分配: ${JUICER_JVM_MEM}"
log "========================================================"

# ------------------------------------------------------------------------------
# 1. 数据质控 (Fastp)
# ------------------------------------------------------------------------------
run_fastp() {
    if [ "$RUN_FASTP" != "yes" ]; then log "跳过 Step 1: Fastp 质控"; return; fi
    log "Step 1: 运行 Fastp 数据质控..."
    mkdir -p "${FASTP_DIR}"
    
    # WGS 质控
    log "  正在处理 WGS 数据..."
    fastp -i "${WGS_R1}" -I "${WGS_R2}" \
          -o "${FASTP_DIR}/wgs_clean_R1.fq.gz" -O "${FASTP_DIR}/wgs_clean_R2.fq.gz" \
          -l "${FASTP_MIN_LEN}" -t "${THREADS}" \
          -h "${FASTP_DIR}/wgs_fastp.html" -j "${FASTP_DIR}/wgs_fastp.json"
    
    # Hi-C 质控
    log "  正在处理 Hi-C 数据..."
    fastp -i "${HIC_R1}" -I "${HIC_R2}" \
          -o "${FASTP_DIR}/hic_clean_R1.fq.gz" -O "${FASTP_DIR}/hic_clean_R2.fq.gz" \
          -l "${FASTP_MIN_LEN}" -t "${THREADS}" \
          -h "${FASTP_DIR}/hic_fastp.html" -j "${FASTP_DIR}/hic_fastp.json"
    
    log "Step 1 完成。"
}

# ------------------------------------------------------------------------------
# 2. 基因组调查 (Jellyfish)
# ------------------------------------------------------------------------------
run_survey() {
    if [ "$RUN_SURVEY" != "yes" ]; then log "跳过 Step 2: 基因组调查"; return; fi
    log "Step 2: 运行 Jellyfish 基因组调查..."
    mkdir -p "${SURVEY_DIR}"
    
    log "  生成 K-mer 频数分布 (K=${KMER_SIZE})..."
    jellyfish count -C -m "${KMER_SIZE}" -s "${GENOME_SIZE_EST}" -t "${THREADS}" \
        -o "${SURVEY_DIR}/mer_counts.jf" <(pigz -dc "${FASTP_DIR}/wgs_clean_R1.fq.gz" "${FASTP_DIR}/wgs_clean_R2.fq.gz")
    
    jellyfish histo -t "${THREADS}" "${SURVEY_DIR}/mer_counts.jf" > "${SURVEY_DIR}/mer_counts.histo"
    log "  Jellyfish 统计完成，结果见: ${SURVEY_DIR}/mer_counts.histo"
    log "Step 2 完成。"
}

# ------------------------------------------------------------------------------
# 3. 基因组组装 (Hifiasm)
# ------------------------------------------------------------------------------
run_assembly() {
    if [ "$RUN_HIFIASM" != "yes" ]; then log "跳过 Step 3: Hifiasm 组装"; return; fi
    log "Step 3: 运行 Hifiasm 组装 (HiFi + Hi-C 模式)..."
    mkdir -p "${HIFIASM_DIR}" && cd "${HIFIASM_DIR}"
    
    hifiasm -o "${PROJECT_NAME}" -t "${THREADS}" --h1 "${HIC_R1}" --h2 "${HIC_R2}" "${HIFI_READS}"
    
    # 转换 GFA 为 FASTA
    log "  提取 Primary Contigs 并建立索引..."
    [ -f "${PROJECT_NAME}.hic.p_ctg.gfa" ] && GFA="${PROJECT_NAME}.hic.p_ctg.gfa" || GFA="${PROJECT_NAME}.bp.p_ctg.gfa"
    awk '/^S/{print ">"$2;print $3}' "$GFA" > "${PROJECT_NAME}.p_ctg.fa"
    samtools faidx "${PROJECT_NAME}.p_ctg.fa"
    
    cd "${PROJECT_ROOT}"
    log "Step 3 完成。"
}

# ------------------------------------------------------------------------------
# 4. 质量评估 (BUSCO)
# ------------------------------------------------------------------------------
run_busco() {
    if [ "$RUN_BUSCO" != "yes" ]; then log "跳过 Step 4: BUSCO 评估"; return; fi
    log "Step 4: 运行 BUSCO 完整度评估..."
    mkdir -p "${BUSCO_DIR}"
    
    B_MODE=$([ "${BUSCO_LINEAGE}" == "auto" ] && echo "--auto-lineage-euk" || echo "-l ${BUSCO_LINEAGE}")
    
    busco -i "${HIFIASM_DIR}/${PROJECT_NAME}.p_ctg.fa" -o busco_result --out_path "${BUSCO_DIR}" \
          -m genome -c "${THREADS}" ${B_MODE} --download_path "${BUSCO_DB}" --offline
    
    log "Step 4 完成。"
}

# ------------------------------------------------------------------------------
# 5. Hi-C 比对 (Chromap)
# ------------------------------------------------------------------------------
run_chromap() {
    if [ "$RUN_CHROMAP" != "yes" ]; then log "跳过 Step 5: Chromap 比对"; return; fi
    log "Step 5: 运行 Chromap Hi-C 比对..."
    mkdir -p "${CHROMAP_DIR}"
    
    log "  正在执行 Chromap Mapping..."
    chromap --preset hic -r "${HIFIASM_DIR}/${PROJECT_NAME}.p_ctg.fa" \
            -1 "${HIC_R1}" -2 "${HIC_R2}" \
            -o "${CHROMAP_DIR}/aligned.sam" -t "${THREADS}" --SAM
    
    log "  转换并排序 BAM 文件..."
    samtools view -@ "${THREADS}" -bS "${CHROMAP_DIR}/aligned.sam" | \
    samtools sort -@ "${THREADS}" -o "${CHROMAP_DIR}/aligned.bam"
    rm "${CHROMAP_DIR}/aligned.sam"
    
    log "Step 5 完成。"
}

# ------------------------------------------------------------------------------
# 6. 挂载 (YAHS)
# ------------------------------------------------------------------------------
run_yahs() {
    if [ "$RUN_YAHS" != "yes" ]; then log "跳过 Step 6: YAHS 挂载"; return; fi
    log "Step 6: 运行 YAHS Scaffolding..."
    mkdir -p "${YAHS_DIR}" && cd "${YAHS_DIR}"
    
    yahs "${HIFIASM_DIR}/${PROJECT_NAME}.p_ctg.fa" "${CHROMAP_DIR}/aligned.bam"
    
    cd "${PROJECT_ROOT}"
    log "Step 6 完成。"
}

# ------------------------------------------------------------------------------
# 7. 可视化 (Juicer)
# ------------------------------------------------------------------------------
run_juicer() {
    if [ "$RUN_JUICER" != "yes" ]; then log "跳过 Step 7: Juicer 可视化"; return; fi
    log "Step 7: 生成 Juicer .hic 可视化文件..."
    mkdir -p "${JUICER_DIR}" && cd "${JUICER_DIR}"
    
    # 动态定位 YAHS 输出
    local AGP=$(ls -t "${YAHS_DIR}"/*_scaffolds_final.agp | head -n 1)
    local BIN=$(ls -t "${YAHS_DIR}"/*.bin | head -n 1)
    
    log "  运行 juicer_pre 处理辅助文件..."
    juicer_pre -a -o "${PROJECT_NAME}_yahs" "$BIN" "$AGP" "${HIFIASM_DIR}/${PROJECT_NAME}.p_ctg.fa.fai" > pre.log 2>&1
    
    log "  调用 Juicer Tools 生成 .hic (内存: ${JUICER_JVM_MEM})..."
    local C_SIZE=$(grep PRE_C_SIZE pre.log | awk '{print $2" "$3}')
    java -Xmx${JUICER_JVM_MEM} -jar "${JUICER_JAR}" pre -j "${THREADS}" \
         "${PROJECT_NAME}_yahs.txt" "${PROJECT_NAME}.hic" <(echo "$C_SIZE")
    
    cd "${PROJECT_ROOT}"
    log "Step 7 完成。"
}

# ------------------------------------------------------------------------------
# 流程控制器 (Main Control)
# ------------------------------------------------------------------------------
run_fastp
run_survey
run_assembly
run_busco
run_chromap
run_yahs
run_juicer

log "========================================================"
log "🎉 所有选定流程执行完毕！"
log "最终产物目录: ${OUT_BASE}"
log "日志详情请参考: ${LOG_FILE}"
log "========================================================"
