#!/bin/bash
set -eo pipefail

# --- 1. 路径与环境初始化 ---
# 定位 scripts 目录和项目根目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# 强制加载根目录配置
if [ -f "${PROJECT_ROOT}/config.sh" ]; then
    source "${PROJECT_ROOT}/config.sh"
else
    echo "Error: Cannot find config.sh in ${PROJECT_ROOT}"
    exit 1
fi

# 自动激活 Conda 环境
CONDA_BASE=$(conda info --base)
source "${CONDA_BASE}/etc/profile.d/conda.sh"
conda activate ${CONDA_ENV_NAME}

# 创建必要目录
mkdir -p ${LOG_DIR} ${OUT_BASE}
LOG_FILE="${LOG_DIR}/pipeline_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo -e "\033[34m[$(date '+%Y-%m-%d %H:%M:%S')]\033[0m $1"; }

log "==== 启动流程: $PROJECT_NAME ===="

# --- 2. 核心执行逻辑 (带开关判断) ---

# Step 1: Fastp 质控
if [ "$RUN_FASTP" == "yes" ]; then
    log "Step 1: Running Fastp QC..."
    mkdir -p ${FASTP_DIR}
    fastp -i ${WGS_R1} -I ${WGS_R2} -o ${FASTP_DIR}/wgs_R1.fq.gz -O ${FASTP_DIR}/wgs_R2.fq.gz -t ${THREADS} -l ${FASTP_MIN_LEN}
fi

# Step 2: Hifiasm 组装
if [ "$RUN_HIFIASM" == "yes" ]; then
    log "Step 2: Running Hifiasm (Hi-C integrated mode)..."
    mkdir -p ${HIFIASM_DIR} && cd ${HIFIASM_DIR}
    hifiasm -o ${PROJECT_NAME} -t ${THREADS} --h1 ${HIC_R1} --h2 ${HIC_R2} ${HIFI_READS}
    
    # 自动识别输出模式
    [ -f "${PROJECT_NAME}.hic.p_ctg.gfa" ] && GFA="${PROJECT_NAME}.hic.p_ctg.gfa" || GFA="${PROJECT_NAME}.bp.p_ctg.gfa"
    awk '/^S/{print ">"$2;print $3}' "$GFA" > "${PROJECT_NAME}.p_ctg.fa"
    samtools faidx "${PROJECT_NAME}.p_ctg.fa"
    cd ${PROJECT_ROOT}
fi

# Step 3: BUSCO 评估
if [ "$RUN_BUSCO" == "yes" ]; then
    log "Step 3: Running BUSCO Assessment..."
    mkdir -p ${BUSCO_DIR}
    B_MODE=$([ "${BUSCO_LINEAGE}" == "auto" ] && echo "--auto-lineage-euk" || echo "-l ${BUSCO_LINEAGE}")
    busco -i "${HIFIASM_DIR}/${PROJECT_NAME}.p_ctg.fa" -o busco_result --out_path ${BUSCO_DIR} \
          -m genome -c ${THREADS} ${B_MODE} --download_path ${BUSCO_DB} --offline
fi

# Step 4: Chromap 比对
if [ "$RUN_CHROMAP" == "yes" ]; then
    log "Step 4: Running Chromap (Hi-C Mapping)..."
    mkdir -p ${CHROMAP_DIR}
    chromap --preset hic -r "${HIFIASM_DIR}/${PROJECT_NAME}.p_ctg.fa" -1 ${HIC_R1} -2 ${HIC_R2} \
            -o "${CHROMAP_DIR}/aligned.sam" -t ${THREADS} --SAM
    samtools view -@ ${THREADS} -bS "${CHROMAP_DIR}/aligned.sam" | samtools sort -@ ${THREADS} -o "${CHROMAP_DIR}/aligned.bam"
    rm "${CHROMAP_DIR}/aligned.sam"
fi

# Step 5: YAHS 挂载
if [ "$RUN_YAHS" == "yes" ]; then
    log "Step 5: Running YAHS Scaffolding..."
    mkdir -p ${YAHS_DIR} && cd ${YAHS_DIR}
    yahs "${HIFIASM_DIR}/${PROJECT_NAME}.p_ctg.fa" "${CHROMAP_DIR}/aligned.bam"
    cd ${PROJECT_ROOT}
fi

# Step 6: Juicer 可视化
if [ "$RUN_JUICER" == "yes" ]; then
    log "Step 6: Generating .hic for Juicebox..."
    mkdir -p ${JUICER_DIR} && cd ${JUICER_DIR}
    
    # 获取最新的 YAHS 产物
    AGP=$(ls -t ${YAHS_DIR}/*_scaffolds_final.agp | head -n 1)
    BIN=$(ls -t ${YAHS_DIR}/*.bin | head -n 1)
    
    juicer_pre -a -o "${PROJECT_NAME}_yahs" "$BIN" "$AGP" "${HIFIASM_DIR}/${PROJECT_NAME}.p_ctg.fa.fai" > pre.log 2>&1
    C_SIZE=$(grep PRE_C_SIZE pre.log | awk '{print $2" "$3}')
    java -Xmx${JUICER_JVM_MEM} -jar ${JUICER_JAR} pre -j ${THREADS} "${PROJECT_NAME}_yahs.txt" "${PROJECT_NAME}.hic" <(echo "$C_SIZE")
    cd ${PROJECT_ROOT}
fi

log "==== 流程完毕！最终产物位于 ${OUT_BASE} ===="
