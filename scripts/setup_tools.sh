#!/bin/bash
# ==============================================================================
# 脚本名称: setup.sh (原 setup_tools.sh)
# 功能: 自动化环境安装、源码编译与实战验证 (深度加固版)
# 特点: 
#   1. 适配根目录 config.sh
#   2. 使用 mamba 极速并行安装
#   3. 自动编译 hifiasm + 2MB 真实数据在线测试
# ==============================================================================

set -e  # 遇到任何错误立即退出

# ------------------------------------------------------------------------------
# 1. 路径与配置加载
# ------------------------------------------------------------------------------
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# 适配：强制指向根目录 config.sh
CONFIG_FILE="${PROJECT_ROOT}/config.sh"

# 日志函数 (彩色输出)
log_info() { echo -e "\033[32m[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1\033[0m"; }
log_error() { echo -e "\033[31m[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1\033[0m"; exit 1; }
log_warn() { echo -e "\033[33m[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1\033[0m"; }

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    log_error "找不到配置文件: $CONFIG_FILE"
fi

# ------------------------------------------------------------------------------
# 2. 包管理器检查 (Conda/Mamba)
# ------------------------------------------------------------------------------
check_manager() {
    log_info "检查包管理器..."
    if ! command -v conda &> /dev/null; then
        log_error "未检测到 Conda，请先安装 Miniconda。"
    fi

    if command -v mamba &> /dev/null; then
        log_info "检测到 mamba，将开启极速下载模式。"
        PKG_MANAGER="mamba"
    else
        log_info "尝试安装 mamba 优化体验..."
        conda install -y -n base -c conda-forge mamba || log_warn "Mamba 安装失败，回退至 Conda"
        PKG_MANAGER=$(command -v mamba &> /dev/null && echo "mamba" || echo "conda")
    fi
}

# ------------------------------------------------------------------------------
# 3. Pipeline 环境构建
# ------------------------------------------------------------------------------
setup_env() {
    log_info "=== 配置 Conda 环境: ${CONDA_ENV_NAME} ==="
    
    # 自动重置旧环境 (生产安全)
    if conda info --envs | grep -q "${CONDA_ENV_NAME}"; then
        log_warn "检测到同名旧环境，正在进行覆盖安装..."
        conda env remove -n "${CONDA_ENV_NAME}" -y
    fi

    # 核心工具包列表 (包含编译所需的 GCC 链)
    CORE_TOOLS=(
        "python=3.9" "fastp" "jellyfish" "samtools" "chromap" 
        "yahs" "wget" "pigz" "make" "git" "busco" 
        "gcc_linux-64" "gxx_linux-64" "zlib"
    )

    log_info "正在通过 $PKG_MANAGER 安装核心依赖..."
    $PKG_MANAGER create -n "${CONDA_ENV_NAME}" -y -c bioconda -c conda-forge "${CORE_TOOLS[@]}"
    
    # 安装可选但推荐的组件
    log_info "安装辅助分析工具 (Genomescope2/Kraken2)..."
    source "$(conda info --base)/etc/profile.d/conda.sh"
    conda activate "${CONDA_ENV_NAME}"
    $PKG_MANAGER install -y -c bioconda genomescope2 kraken2 || log_warn "部分可选工具安装失败"
}

# ------------------------------------------------------------------------------
# 4. Hifiasm 源码编译与指令集实战验证
# ------------------------------------------------------------------------------
install_hifiasm() {
    log_info "=== 开始编译安装 Hifiasm (源码模式) ==="
    BUILD_DIR="${PROJECT_ROOT}/tools/hifiasm_build"
    mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"

    # 克隆源码
    if [ ! -d "hifiasm" ]; then
        log_info "从 GitHub 获取最新源码..."
        git clone https://github.com/chhylp123/hifiasm.git
    fi
    cd hifiasm && make clean >/dev/null 2>&1 || true

    # 使用 Conda 环境内的编译器确保库依赖一致性
    export CXX="${CONDA_PREFIX}/bin/x86_64-conda-linux-gnu-g++"
    log_info "使用 Conda 编译器进行构建: $CXX"
    make -j$(nproc) CXX="$CXX" || log_error "Hifiasm 编译失败，请检查 C++ 编译器。"

    # --- 实战验证逻辑 ---
    log_info "正在进行 CPU 指令集兼容性实战测试..."
    TEST_DATA="chr11-2M.fa.gz"
    if [ ! -f "$TEST_DATA" ]; then
        wget -q https://github.com/chhylp123/hifiasm/releases/download/v0.7/$TEST_DATA || log_warn "无法下载测试数据，跳过实战验证"
    fi

    if [ -f "$TEST_DATA" ]; then
        log_info "运行 2MB 测试数据组装测试..."
        if ./hifiasm -o test_asm -t 4 "$TEST_DATA" > test.log 2>&1; then
            log_info "✅ Hifiasm 测试通过！CPU 指令集完全兼容。"
        else
            log_error "❌ Hifiasm 运行崩溃！可能是当前 CPU 架构不支持编译产物，请在计算节点重新运行此脚本。"
        fi
        rm -f test_asm* test.log "$TEST_DATA"
    fi

    # 部署到环境路径
    cp hifiasm "${CONDA_PREFIX}/bin/"
    chmod +x "${CONDA_PREFIX}/bin/hifiasm"
    cd "${PROJECT_ROOT}"
}

# ------------------------------------------------------------------------------
# 5. Shell 交互增强
# ------------------------------------------------------------------------------
setup_shell() {
    log_info "配置 Shell 自动加载..."
    CURRENT_SHELL=$(basename "$SHELL")
    conda init "$CURRENT_SHELL" > /dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# 主程序入口
# ------------------------------------------------------------------------------
main() {
    log_info "🚀 启动一键部署流程..."
    
    check_manager
    setup_env
    install_hifiasm
    setup_shell

    log_info "========================================================"
    log_info "🎉 环境部署大功告成！"
    log_info "1. 重新加载 Shell: source ~/.${CURRENT_SHELL}rc"
    log_info "2. 激活环境: conda activate ${CONDA_ENV_NAME}"
    log_info "3. 开始组装: bash scripts/run_assembly.sh"
    log_info "========================================================"
}

main "$@"
