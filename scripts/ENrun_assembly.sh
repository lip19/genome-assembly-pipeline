#!/bin/bash
# ==============================================================================
# 脚本名称: run_assembly.sh
# 功能: 基因组组装主流程
# ==============================================================================

set -e

# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PROJECT_ROOT}/config/config.sh"

# 加载配置
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# 激活 Conda 环境
# 注意：在脚本中激活 Conda 需要先 source conda.sh
if [ -f "${PROJECT_ROOT}/tools/miniconda3/bin/activate" ]; then
    source "${PROJECT_ROOT}/tools/miniconda3/bin/activate" "${CONDA_ENV_NAME}"
elif [ -f "$(conda info --base)/etc/profile.d/conda.sh" ]; then
    source "$(conda info --base)/etc/profile.d/conda.sh"
    conda activate "${CONDA_ENV_NAME}"
else
    echo "WARNING: Failed to auto-activate Conda environment. Please ensure ${CONDA_ENV_NAME} is activated manually."
fi

# 创建日志目录
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/pipeline_$(date '+%Y%m%d_%H%M%S').log"

# 日志函数
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

log "========================================================"
log "Starting genome assembly pipeline"
log "Project name: ${PROJECT_NAME}"
log "Working directory: ${WORKDIR}"
log "========================================================"

# ------------------------------------------------------------------------------
# 1. 数据质控 (Fastp) - 针对 WGS 和 Hi-C 数据
# ------------------------------------------------------------------------------
run_fastp() {
    log "Step 1: Running Fastp for read quality control..."
    
    local OUT_DIR="${WORKDIR}/results/01_fastp"
    mkdir -p "${OUT_DIR}"

    # WGS 质控
    if [ -f "${WGS_R1}" ] && [ -f "${WGS_R2}" ]; then
        log "  Processing WGS reads..."
        fastp -i "${WGS_R1}" -I "${WGS_R2}" \
              -o "${OUT_DIR}/wgs_clean_R1.fastq.gz" -O "${OUT_DIR}/wgs_clean_R2.fastq.gz" \
              -l "${FASTP_MIN_LEN}" \
              --thread "${THREADS}" \
              --html "${OUT_DIR}/wgs_fastp.html" \
              --json "${OUT_DIR}/wgs_fastp.json" 2>> "${LOG_FILE}"
    else
        log "  WARNING: WGS reads not found. Skipping WGS quality control."
    fi

    # Hi-C 质控
    if [ -f "${HIC_R1}" ] && [ -f "${HIC_R2}" ]; then
        log "  Processing Hi-C reads..."
        fastp -i "${HIC_R1}" -I "${HIC_R2}" \
              -o "${OUT_DIR}/hic_clean_R1.fastq.gz" -O "${OUT_DIR}/hic_clean_R2.fastq.gz" \
              -l "${FASTP_MIN_LEN}" \
              --thread "${THREADS}" \
              --html "${OUT_DIR}/hic_fastp.html" \
              --json "${OUT_DIR}/hic_fastp.json" 2>> "${LOG_FILE}"
    else
        log "  WARNING: Hi-C reads not found. Skipping Hi-C quality control."
    fi
    
    log "Step 1 completed."
}

# ------------------------------------------------------------------------------
# 2. 基因组调查 (Jellyfish + GenomeScope)
# ------------------------------------------------------------------------------
run_genome_survey() {
    log "Step 2: Running genome survey analysis..."
    
    local IN_R1="${WORKDIR}/results/01_fastp/wgs_clean_R1.fastq.gz"
    local IN_R2="${WORKDIR}/results/01_fastp/wgs_clean_R2.fastq.gz"
    local OUT_DIR="${WORKDIR}/results/02_genome_survey"
    mkdir -p "${OUT_DIR}"

    if [ ! -f "${IN_R1}" ]; then
        log "  ERROR: Cleaned WGS reads not found. Skipping genome survey."
        return
    fi

    # Jellyfish count
    log "  Running Jellyfish count..."
    jellyfish count -C -m "${KMER_SIZE}" -s "${GENOME_SIZE_EST}" -t "${THREADS}" \
        -o "${OUT_DIR}/mer_counts.jf" \
        <(pigz -dc "${IN_R1}" "${IN_R2}") 2>> "${LOG_FILE}"

    # Jellyfish histo
    log "  Running Jellyfish histogram..."
    jellyfish histo -t "${THREADS}" "${OUT_DIR}/mer_counts.jf" > "${OUT_DIR}/mer_counts.histo"

    # GenomeScope
    log "  Running GenomeScope..."
    genomescope2 -i "${OUT_DIR}/mer_counts.histo" -o "${OUT_DIR}" -k "${KMER_SIZE}" -p 2 2>> "${LOG_FILE}"

    log "Step 2 completed."
}

# ------------------------------------------------------------------------------
# 3. 污染去除 (Kraken2) - 可选
# ------------------------------------------------------------------------------
run_kraken() {
    log "Step 3: Running Kraken2 contamination screening..."
    
    if [ ! -d "${KRAKEN_DB}" ]; then
        log "  WARNING: Kraken2 database not found (${KRAKEN_DB}). Skipping this step."
        return
    fi

    local OUT_DIR="${WORKDIR}/results/03_kraken"
    mkdir -p "${OUT_DIR}"
    
    kraken2 --db "${KRAKEN_DB}" --threads "${THREADS}" \
        --output "${OUT_DIR}/kraken_output.txt" \
        --report "${OUT_DIR}/kraken_report.txt" \
        --confidence "${KRAKEN_CONFIDENCE}" \
        "${HIFI_READS}" 2>> "${LOG_FILE}"
        
    log "  Kraken2 report generated. Please review the report to decide whether manual filtering is required."
    log "Step 3 completed."
}

# ------------------------------------------------------------------------------
# 4. 基因组组装 (Hifiasm)
# ------------------------------------------------------------------------------
run_assembly() {
    log "Step 4: Running Hifiasm assembly..."
    
    local OUT_DIR="${WORKDIR}/results/04_assembly"
    mkdir -p "${OUT_DIR}"
    
    cd "${OUT_DIR}"
    
    log "  Starting Hifiasm assembly..."
    
    hifiasm -o "${PROJECT_NAME}" -t "${THREADS}" "${HIFI_READS}" 2>> "${LOG_FILE}"
    
    if [ -f "${PROJECT_NAME}.bp.p_ctg.gfa" ]; then
        awk '/^S/{print ">"$2;print $3}' "${PROJECT_NAME}.bp.p_ctg.gfa" > "${PROJECT_NAME}.p_ctg.fa"
        log "  Assembly completed. Primary contigs generated: ${OUT_DIR}/${PROJECT_NAME}.p_ctg.fa"
    else
        log "  ERROR: GFA file not generated. Assembly may have failed. Please check the log."
        exit 1
    fi
    
    log "Step 4 completed."
}

# ------------------------------------------------------------------------------
# 5. 质量评估 (BUSCO) - Contig 级别
# ------------------------------------------------------------------------------
run_busco() {
    log "Step 5: Running BUSCO assessment (contig level)..."
    
    if [ ! -d "${BUSCO_DB}" ]; then
        log "  WARNING: BUSCO database not found (${BUSCO_DB}). Skipping this step."
        return
    fi

    local IN_FASTA="${WORKDIR}/results/04_assembly/${PROJECT_NAME}.p_ctg.fa"
    local OUT_DIR="${WORKDIR}/results/05_busco_contig"
    
    if [ ! -f "${IN_FASTA}" ]; then
        log "  ERROR: Assembly FASTA not found. Skipping BUSCO."
        return
    fi

    busco -i "${IN_FASTA}" -l "${BUSCO_DB}" -o "${OUT_DIR}" -m genome -c "${THREADS}" --offline 2>> "${LOG_FILE}"
    
    log "Step 5 completed."
}

# ------------------------------------------------------------------------------
# 6. Hi-C 比对 (Chromap)
# ------------------------------------------------------------------------------
run_chromap() {
    log "Step 6: Running Chromap Hi-C alignment..."
    
    local CONTIGS="${WORKDIR}/results/04_assembly/${PROJECT_NAME}.p_ctg.fa"
    local HIC_R1_CLEAN="${WORKDIR}/results/01_fastp/hic_clean_R1.fastq.gz"
    local HIC_R2_CLEAN="${WORKDIR}/results/01_fastp/hic_clean_R2.fastq.gz"
    local OUT_DIR="${WORKDIR}/results/06_chromap"
    mkdir -p "${OUT_DIR}"

    if [ ! -f "${HIC_R1_CLEAN}" ]; then
        log "  ERROR: Clean Hi-C reads not found. Skipping this step."
        return
    fi

    log "  Building Chromap index..."
    chromap -i -r "${CONTIGS}" -o "${OUT_DIR}/contigs.index" 2>> "${LOG_FILE}"
    
    log "  Aligning Hi-C reads..."
    chromap --preset "${CHROMAP_PRESET}" -r "${CONTIGS}" -x "${OUT_DIR}/contigs.index" \
        --remove-pcr-duplicates \
        -1 "${HIC_R1_CLEAN}" -2 "${HIC_R2_CLEAN}" \
        --SAM \
        -o "${OUT_DIR}/aligned.sam" -t "${THREADS}" 2>> "${LOG_FILE}"
        
    log "  Converting SAM to sorted BAM..."
    samtools view -bS "${OUT_DIR}/aligned.sam" | samtools sort -@ "${THREADS}" -o "${OUT_DIR}/aligned.sorted.bam"
    rm "${OUT_DIR}/aligned.sam"
    
    log "Step 6 completed."
}

# ------------------------------------------------------------------------------
# 7. Scaffolding (Yahs)
# ------------------------------------------------------------------------------
run_yahs() {
    log "Step 7: Running Yahs scaffolding..."
    
    local CONTIGS="${WORKDIR}/results/04_assembly/${PROJECT_NAME}.p_ctg.fa"
    local BAM="${WORKDIR}/results/06_chromap/aligned.sorted.bam"
    local OUT_DIR="${WORKDIR}/results/07_yahs"
    mkdir -p "${OUT_DIR}"
    
    cd "${OUT_DIR}"
    
    samtools faidx "${CONTIGS}"
    
    yahs "${CONTIGS}" "${BAM}" 2>> "${LOG_FILE}"
    
    log "  Scaffolding completed. Results are located in ${OUT_DIR}"
    log "Step 7 completed."
}

# ------------------------------------------------------------------------------
# 8. 可视化 (Juicer)
# ------------------------------------------------------------------------------
run_juicer() {
    log "Step 8: Running Juicer pre-processing (hic generation)..."
    
    local OUT_DIR="${WORKDIR}/results/08_juicer"
    mkdir -p "${OUT_DIR}"
    
    local BIN_FILE="${WORKDIR}/results/07_yahs/yahs.out.bin"
    local AGP_FILE="${WORKDIR}/results/07_yahs/yahs.out_scaffolds_final.agp"
    local FAI_FILE="${WORKDIR}/results/04_assembly/${PROJECT_NAME}.p_ctg.fa.fai"
    
    if [ ! -f "${JUICER_JAR}" ]; then
        log "  WARNING: Juicer jar not found. Skipping visualization step."
        return
    fi

    log "  NOTE: Please run the following command manually to generate the .hic file (requires large memory):"
    log "  java -Xmx${JUICER_JVM_MEM} -jar ${JUICER_JAR} pre ${BIN_FILE} ${AGP_FILE} ${FAI_FILE}"
    
    log "Step 8 completed."
}

# ------------------------------------------------------------------------------
# 执行所有步骤
# ------------------------------------------------------------------------------
run_fastp
run_genome_survey
run_kraken
run_assembly
run_busco
run_chromap 
run_yahs
run_juicer

log "========================================================"
log "Pipeline finished successfully!"
log "Log file: ${LOG_FILE}"
log "========================================================"
