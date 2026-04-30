#!/usr/bin/env bash
# OpenClaw 一键安装（含 Gateway service 兼容修复）
# 适用：Ubuntu 22.04 / 24.04

set -Eeuo pipefail

BASE_URL="https://orcaterm-script-1258344699.cos.ap-shanghai.myqcloud.com/linux/AI/openclaw"
HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-15}"

HEARTBEAT_PID=""
CURRENT_TMP_SCRIPT=""
CURRENT_TMP_LOG=""

STEPS=(
  "01-setup-deps.sh|系统依赖与环境配置"
  "02-install-openclaw.sh|安装 OpenClaw"
  "03-install-plugins.sh|安装插件"
  "04-install-skills.sh|安装默认 Skills"
)

log_info() {
  echo "[$(date '+%H:%M:%S')] $*"
}

log_warn() {
  echo "[$(date '+%H:%M:%S')] WARN: $*"
}

log_error() {
  echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2
}

start_heartbeat() {
  (
    while true; do
      sleep "$HEARTBEAT_SECONDS"
      echo "[$(date '+%H:%M:%S')] ... 安装进行中 ..."
    done
  ) &
  HEARTBEAT_PID=$!
}

stop_heartbeat() {
  if [ -n "${HEARTBEAT_PID}" ]; then
    kill "${HEARTBEAT_PID}" 2>/dev/null || true
    wait "${HEARTBEAT_PID}" 2>/dev/null || true
    HEARTBEAT_PID=""
  fi
}

cleanup_tmp() {
  [ -n "${CURRENT_TMP_SCRIPT}" ] && rm -f "${CURRENT_TMP_SCRIPT}" 2>/dev/null || true
  [ -n "${CURRENT_TMP_LOG}" ] && rm -f "${CURRENT_TMP_LOG}" 2>/dev/null || true
  CURRENT_TMP_SCRIPT=""
  CURRENT_TMP_LOG=""
}

cleanup_and_exit() {
  trap - INT TERM EXIT
  echo ""
  log_error "收到中断信号，正在停止安装..."
  cleanup_tmp
  stop_heartbeat
  exit 130
}

trap cleanup_and_exit INT TERM
trap 'cleanup_tmp; stop_heartbeat' EXIT

is_gateway_service_known_issue() {
  local log_file="$1"
  grep -Eqi \
    'openclaw-gateway\.service does not exist|systemctl( --user)? is-enabled unavailable|Failed to connect to bus' \
    "$log_file"
}

prepare_user_systemd_context() {
  local uid
  uid="$(id -u)"

  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${uid}}"
  if [ ! -d "${XDG_RUNTIME_DIR}" ]; then
    mkdir -p "${XDG_RUNTIME_DIR}" 2>/dev/null || true
  fi
  chmod 700 "${XDG_RUNTIME_DIR}" 2>/dev/null || true

  if command -v loginctl >/dev/null 2>&1; then
    loginctl enable-linger "${USER}" >/dev/null 2>&1 || true
  fi
}

manual_install_gateway_service() {
  local svc_dir svc_file openclaw_bin

  if ! command -v openclaw >/dev/null 2>&1; then
    log_warn "找不到 openclaw 命令，无法执行 Gateway 修复。"
    return 1
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    log_warn "当前系统无 systemctl，跳过 systemd 修复。"
    return 1
  fi

  prepare_user_systemd_context

  # 尝试补齐 local 模式，避免 Gateway 因 mode 缺失拒绝启动。
  openclaw config set gateway.mode local >/dev/null 2>&1 || true

  svc_dir="${HOME}/.config/systemd/user"
  svc_file="${svc_dir}/openclaw-gateway.service"
  openclaw_bin="$(command -v openclaw)"

  mkdir -p "${svc_dir}"

  cat > "${svc_file}" <<EOF
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${openclaw_bin} gateway --port 18789 --bind loopback
Restart=always
RestartSec=5
TimeoutStopSec=30
TimeoutStartSec=30
SuccessExitStatus=0 143
KillMode=control-group

[Install]
WantedBy=default.target
EOF

  if ! systemctl --user daemon-reload >/dev/null 2>&1; then
    log_warn "systemctl --user daemon-reload 失败（可能是 user bus 未就绪）。"
    return 1
  fi

  if ! systemctl --user enable --now openclaw-gateway.service >/dev/null 2>&1; then
    log_warn "systemctl --user enable --now openclaw-gateway.service 失败。"
    return 1
  fi

  log_info "已通过手动 user unit 安装并启动 openclaw-gateway.service"
  return 0
}

fallback_start_gateway_process() {
  local gateway_log

  if ! command -v openclaw >/dev/null 2>&1; then
    return 1
  fi

  # 尝试补齐 local 模式，避免 gateway 拒绝启动。
  openclaw config set gateway.mode local >/dev/null 2>&1 || true

  gateway_log="/tmp/openclaw-gateway.log"
  nohup openclaw gateway --port 18789 --bind loopback >"${gateway_log}" 2>&1 &
  sleep 2

  if openclaw gateway status --require-rpc >/dev/null 2>&1; then
    log_warn "Gateway 已以后台进程方式启动（非 systemd）。日志: ${gateway_log}"
    return 0
  fi

  log_warn "后台启动 Gateway 失败，请检查 ${gateway_log}"
  return 1
}

recover_gateway_install_failure() {
  log_warn "检测到 OpenClaw Gateway 服务安装已知问题，开始自动修复..."

  if ! command -v openclaw >/dev/null 2>&1; then
    log_error "OpenClaw 命令不存在，无法继续修复。"
    return 1
  fi

  if openclaw gateway install --force >/tmp/openclaw-gateway-fix.log 2>&1; then
    log_info "openclaw gateway install --force 修复成功"
    return 0
  fi
  log_warn "官方命令修复失败，继续尝试手动安装 systemd user unit。"

  if manual_install_gateway_service; then
    return 0
  fi

  log_warn "systemd 修复失败，尝试兜底为后台进程运行。"
  if fallback_start_gateway_process; then
    return 0
  fi

  log_error "Gateway 自动修复失败。请执行: openclaw doctor && openclaw gateway status --deep"
  return 1
}

run_remote_script() {
  local script_name="$1"
  local description="$2"
  local url="${BASE_URL}/${script_name}"

  log_info "========================================"
  log_info "步骤: ${description}"
  log_info "执行: ${url}"
  log_info "========================================"

  CURRENT_TMP_SCRIPT="$(mktemp /tmp/openclaw-install-XXXXXX.sh)"
  CURRENT_TMP_LOG="$(mktemp /tmp/openclaw-install-XXXXXX.log)"

  if ! curl -fSL --connect-timeout 10 --max-time 180 -o "${CURRENT_TMP_SCRIPT}" "${url}"; then
    log_error "下载失败: ${script_name}"
    cleanup_tmp
    return 1
  fi

  chmod +x "${CURRENT_TMP_SCRIPT}"

  set +e
  bash "${CURRENT_TMP_SCRIPT}" 2>&1 | tee "${CURRENT_TMP_LOG}"
  local run_code=${PIPESTATUS[0]}
  set -e

  if [ "${run_code}" -ne 0 ]; then
    if [ "${script_name}" = "02-install-openclaw.sh" ] && is_gateway_service_known_issue "${CURRENT_TMP_LOG}"; then
      if recover_gateway_install_failure; then
        log_warn "已跳过 02 步骤中的 Gateway service 异常，继续后续安装。"
        cleanup_tmp
        log_info "完成(修复后继续): ${description}"
        echo ""
        return 0
      fi
    fi

    log_error "执行失败: ${script_name}"
    cleanup_tmp
    return 1
  fi

  cleanup_tmp
  log_info "完成: ${description}"
  echo ""
}

verify_install() {
  log_info "开始验证安装结果..."

  set +e
  source /etc/profile >/dev/null 2>&1
  set +e

  if [ -s "${NVM_DIR:-/usr/local/nvm}/nvm.sh" ]; then
    source "${NVM_DIR:-/usr/local/nvm}/nvm.sh"
  fi

  if ! command -v openclaw >/dev/null 2>&1; then
    log_error "验证失败: openclaw 命令不可用"
    return 1
  fi

  openclaw --version || return 1

  if ! openclaw doctor --non-interactive; then
    log_warn "doctor 返回非零，请稍后手动检查。"
  fi

  if ! openclaw gateway status --require-rpc; then
    log_warn "Gateway 暂未通过 RPC 探测，可稍后执行: openclaw gateway status --deep"
  fi

  return 0
}

main() {
  log_info "========== OpenClaw 一键安装 =========="
  log_info "开始时间: $(date)"
  log_info "提示: 安装过程中每 ${HEARTBEAT_SECONDS} 秒输出一次心跳信息"
  echo ""

  start_heartbeat
  export OPENCLAW_HEARTBEAT_ACTIVE=1

  local failed=0

  for step in "${STEPS[@]}"; do
    local script_name="${step%%|*}"
    local description="${step##*|}"

    if ! run_remote_script "${script_name}" "${description}"; then
      log_error "${description} 失败，中止安装"
      failed=1
      break
    fi
  done

  echo ""
  if [ "${failed}" -eq 0 ]; then
    if verify_install; then
      log_info "========== 安装完成 =========="
      log_info "环境已就绪，建议执行: openclaw gateway status --deep"
    else
      log_error "安装完成，但验证阶段发现问题，请检查日志。"
      exit 1
    fi

    stop_heartbeat
    exec bash -l
  else
    log_error "========== 安装失败 =========="
    log_error "请检查上方错误日志，修复后可重新执行此脚本"
    exit 1
  fi
}

main "$@"
