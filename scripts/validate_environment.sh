#!/bin/bash
# ==============================================================================
# 脚本名称: check.sh (原 validate_environment.sh)
# 功能: 验证 Dpil 基因组组装流程的运行环境与依赖
# ==============================================================================

set -e

# --- 1. 路径与配置加载 ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# 适配：指向根目录下的 config.sh
CONFIG_FILE="${PROJECT_ROOT}/config.sh"

# 日志函数 (带颜色提示)
log_info() { echo -e "\033[32m[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1\033[0m"; }
log_error() { echo -e "\033[31m[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1\033[0m"; }
log_warn() { echo -e "\033[33m[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1\033[0m"; }

# 加载配置
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    log_error "找不到配置文件 $CONFIG_FILE"
    exit 1
fi

# --- 2. 检查 Conda 环境 ---
log_info "=== 1. 检查 Conda 环境 ==="
if ! command -v conda &> /dev/null; then
    log_error "未检测到 Conda，请先安装 Miniconda 或 Anaconda。"
    exit 1
fi

# 检查环境是否存在
if conda info --envs | grep -q "${CONDA_ENV_NAME}"; then
    log_info "Conda 环境 '${CONDA_ENV_NAME}' 已就绪。"
else
    log_error "环境 '${CONDA_ENV_NAME}' 未创建！请先运行: bash scripts/setup.sh"
    exit 1
fi

# 自动尝试激活环境以进行深度检查
CONDA_PATH=$(conda info --base)
source "${CONDA_PATH}/etc/profile.d/conda.sh"
conda activate "${CONDA_ENV_NAME}"

# --- 3. 检查核心工具链 ---
log_info "=== 2. 检查核心工具链 ==="
# 这里的工具列表已根据 run_assembly.sh 的需求对齐
CORE_TOOLS=("fastp" "jellyfish" "samtools" "chromap" "yahs" "pigz" "busco" "java")
MISSING_TOOLS=0

for tool in "${CORE_TOOLS[@]}"; do
    if command -v "$tool" &> /dev/null; then
        # 获取版本号的前 50 个字符
        VER_INFO=$($tool --version 2>&1 | head -n 1 | cut -c 1-50)
        echo -e "  [OK] $tool: $VER_INFO"
    else
        echo -e "  \033[31m[FAIL] $tool 未找到\033[0m"
        MISSING_TOOLS=$((MISSING_TOOLS + 1))
    fi
done

# --- 4. 特别检查 Hifiasm (指令集兼容性测试) ---
log_info "=== 3. 检查 Hifiasm (源码编译版) ==="
if command -v hifiasm &> /dev/null; then
    if hifiasm --version &> /dev/null; then
        echo -e "  [OK] hifiasm: $(hifiasm --version)"
    else
        echo -e "  \033[31m[FAIL] hifiasm 存在但无法运行 (可能是 CPU 指令集非法指令错误)\033[0m"
        MISSING_TOOLS=$((MISSING_TOOLS + 1))
    fi
else
    echo -e "  \033[31m[FAIL] hifiasm 未安装\033[0m"
    MISSING_TOOLS=$((MISSING_TOOLS + 1))
fi

# --- 5. 检查 Juicer 关键组件 ---
log_info "=== 4. 检查 Juicer 可视化组件 ==="
if [ -f "$JUICER_JAR" ]; then
    echo -e "  [OK] Juicer JAR 路径正确: $JUICER_JAR"
else
    log_warn "Juicer JAR 缺失: $JUICER_JAR (Step 7 将无法生成 .hic 文件)"
    # 这里设为警告而非报错，因为不影响前面的组装
fi

# --- 6. 验证结果总结 ---
log_info "=== 验证结果 ==="
if [ $MISSING_TOOLS -eq 0 ]; then
    log_info "✅ 环境验证通过！所有核心工具均已准备就绪。"
    log_info "您可以放心地运行组装流程了: bash scripts/run_assembly.sh"
    exit 0
else
    log_error "❌ 环境验证失败！共有 $MISSING_TOOLS 个核心工具存在问题。"
    log_error "请检查上述 [FAIL] 项，并尝试重新运行 scripts/setup.sh"
    exit 1
fi
