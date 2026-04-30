#!/bin/bash
# OpenClaw 一键安装脚本
# 依次从远程下载并执行四个安装步骤

set -e

BASE_URL="https://orcaterm-script-1258344699.cos.ap-shanghai.myqcloud.com/linux/AI/openclaw"

# ========== 心跳保活 ==========
# 防止终端因长时间无输出而判定脚本已结束
# 每 15 秒输出一个进度点，确保终端持续收到输出
HEARTBEAT_PID=""

start_heartbeat() {
  (
    while true; do
      sleep 15
      echo "[$(date '+%H:%M:%S')] ... 安装进行中 ..."
    done
  ) &
  HEARTBEAT_PID=$!
}

stop_heartbeat() {
  if [ -n "$HEARTBEAT_PID" ]; then
    kill $HEARTBEAT_PID 2>/dev/null || true
    wait $HEARTBEAT_PID 2>/dev/null || true
    HEARTBEAT_PID=""
  fi
}

STEPS=(
  "01-setup-deps.sh|系统依赖与环境配置"
  "02-install-openclaw.sh|安装 OpenClaw"
  "03-install-plugins.sh|安装插件"
  "04-install-skills.sh|安装默认 Skills"
)

log_info() {
  echo "[$(date '+%H:%M:%S')] $*"
}

log_error() {
  echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2
}

# 用于追踪当前正在使用的临时脚本文件
CURRENT_TMP_SCRIPT=""

# 中断处理：收到 SIGINT/SIGTERM 时清理所有子进程并退出（放在 log_error 之后确保可用）
cleanup_and_exit() {
  # 重置 trap 避免重复触发
  trap - INT TERM EXIT
  echo ""
  log_error "收到中断信号，正在停止安装..."
  # 清理可能残留的临时脚本文件
  [ -n "$CURRENT_TMP_SCRIPT" ] && rm -f "$CURRENT_TMP_SCRIPT"
  stop_heartbeat
  exit 130
}
trap cleanup_and_exit INT TERM
# 确保脚本正常退出时也停止心跳
trap stop_heartbeat EXIT

run_remote_script() {
  local script_name="$1"
  local description="$2"
  local url="${BASE_URL}/${script_name}"

  log_info "========================================"
  log_info "步骤: ${description}"
  log_info "执行: ${url}"
  log_info "========================================"

  # 先下载到临时文件再执行，避免 bash <(curl ...) 导致子进程不在同一进程组
  # 这样 Ctrl+C 的 SIGINT 信号能正确传播到子脚本
  CURRENT_TMP_SCRIPT=$(mktemp /tmp/openclaw-install-XXXXXX.sh)
  local tmp_script="$CURRENT_TMP_SCRIPT"
  if ! curl -fSL --connect-timeout 10 --max-time 120 -o "$tmp_script" "$url"; then
    log_error "下载失败: ${script_name}"
    rm -f "$tmp_script"
    return 1
  fi

  chmod +x "$tmp_script"
  if ! bash "$tmp_script"; then
    log_error "执行失败: ${script_name}"
    rm -f "$tmp_script"
    return 1
  fi

  rm -f "$tmp_script"
  log_info "完成: ${description}"
  echo ""
}

main() {
  log_info "========== OpenClaw 一键安装 =========="
  log_info "开始时间: $(date)"
  log_info "提示: 安装过程中每 15 秒会输出心跳信息，表示安装仍在进行中"
  echo ""

  start_heartbeat
  export OPENCLAW_HEARTBEAT_ACTIVE=1

  local failed=0

  for step in "${STEPS[@]}"; do
    local script_name="${step%%|*}"
    local description="${step##*|}"

    if ! run_remote_script "$script_name" "$description"; then
      log_error "${description} 失败，中止安装"
      failed=1
      break
    fi
  done

  echo ""
  if [ $failed -eq 0 ]; then
    log_info "========== 安装完成 =========="
    log_info "正在加载环境变量..."

    # 关闭 set -e，防止环境加载或验证阶段的非零退出码导致脚本中断
    # 确保无论如何都能走到最后的 exec bash -l
    set +e

    if ! source /etc/profile; then
      log_info "加载 /etc/profile 时出现异常，部分环境变量可能未正确设置"
    fi
    # /etc/profile 可能内部设置了 set -e，确保此处恢复为 +e
    set +e

    # 显式加载 NVM 环境，确保 node/pnpm/openclaw/clawhub 等命令可用
    export NVM_DIR="${NVM_DIR:-/usr/local/nvm}"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
      source "$NVM_DIR/nvm.sh"
    fi

    log_info "环境变量已加载"
    log_info "验证安装结果:"

    # 验证命令是否可用，失败只输出警告，不阻止进入新 shell
    if openclaw --version && clawhub -V && openclaw plugins list; then
      log_info "所有命令验证通过"
    else
      log_info "警告: 部分命令验证失败，请在新终端中手动检查"
    fi

    echo ""
    log_info "=========================================="
    log_info "安装完成! 正在启动新的终端会话以加载环境变量..."
    log_info "=========================================="
    # exec 会替换当前进程，不会触发 EXIT trap，需要手动停止心跳
    stop_heartbeat
    # 启动一个新的登录 shell，自动加载 /etc/profile 中的环境变量
    # 这样用户无需手动 source /etc/profile，node/nvm/pnpm 等命令立即可用
    exec bash -l
  else
    log_error "========== 安装失败 =========="
    log_error "请检查上方错误日志，修复后可重新执行此脚本"
    exit 1
  fi
}

main "$@"
