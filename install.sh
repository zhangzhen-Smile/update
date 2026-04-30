#!/usr/bin/env bash
# OpenClaw one-click installer with Gateway recovery
# Target: Ubuntu 22.04 / 24.04

# Re-exec with bash when started by sh/dash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -Eeuo pipefail

BASE_URL="https://orcaterm-script-1258344699.cos.ap-shanghai.myqcloud.com/linux/AI/openclaw"
HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-15}"

HEARTBEAT_PID=""
CURRENT_TMP_SCRIPT=""
CURRENT_TMP_LOG=""
NPM_USERCONFIG_TMP=""

REGISTRY_CANDIDATES=(
  "${OPENCLAW_PRIMARY_REGISTRY:-https://registry.npmmirror.com/}"
  "https://registry.npmjs.org/"
  "https://mirrors.cloud.tencent.com/npm/"
)

STEPS=(
  "01-setup-deps.sh|Setup dependencies"
  "02-install-openclaw.sh|Install OpenClaw"
  "03-install-plugins.sh|Install plugins"
  "04-install-skills.sh|Install default skills"
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
      echo "[$(date '+%H:%M:%S')] ... installation running ..."
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

cleanup_registry_override() {
  [ -n "${NPM_USERCONFIG_TMP}" ] && rm -f "${NPM_USERCONFIG_TMP}" 2>/dev/null || true
  NPM_USERCONFIG_TMP=""
}

cleanup_and_exit() {
  trap - INT TERM EXIT
  echo ""
  log_error "Interrupted. Stopping installer..."
  cleanup_tmp
  cleanup_registry_override
  stop_heartbeat
  exit 130
}

trap cleanup_and_exit INT TERM
trap 'cleanup_tmp; cleanup_registry_override; stop_heartbeat' EXIT

normalize_registry() {
  local registry="$1"
  if [[ "${registry}" != */ ]]; then
    registry="${registry}/"
  fi
  echo "${registry}"
}

apply_registry_override() {
  local registry
  registry="$(normalize_registry "$1")"

  if [ -z "${NPM_USERCONFIG_TMP}" ]; then
    NPM_USERCONFIG_TMP="$(mktemp /tmp/openclaw-npmrc-XXXXXX)"
  fi

  cat > "${NPM_USERCONFIG_TMP}" <<EOF
registry=${registry}
fetch-retries=5
fetch-retry-factor=2
fetch-retry-mintimeout=10000
fetch-retry-maxtimeout=120000
fetch-timeout=180000
network-concurrency=8
EOF

  export NPM_CONFIG_USERCONFIG="${NPM_USERCONFIG_TMP}"
  export npm_config_userconfig="${NPM_USERCONFIG_TMP}"
  export NPM_CONFIG_REGISTRY="${registry}"
  export npm_config_registry="${registry}"
  export PNPM_REGISTRY="${registry}"
  export pnpm_config_registry="${registry}"
  export COREPACK_NPM_REGISTRY="${registry}"

  log_info "Using npm/pnpm registry: ${registry}"
}

patch_hardcoded_registry_in_script() {
  local script_path="$1"
  local registry
  registry="$(normalize_registry "$2")"

  if [ ! -f "${script_path}" ]; then
    return 1
  fi

  sed -i \
    -e "s#https\\?://mirrors.tencent.com/npm/?#${registry}#g" \
    -e "s#https\\?://mirrors.cloud.tencent.com/npm/?#${registry}#g" \
    -e "s#https\\?://registry.npmmirror.com/?#${registry}#g" \
    -e "s#https\\?://registry.npm.taobao.org/?#${registry}#g" \
    "${script_path}" || true
}

is_pnpm_fetch_issue() {
  local log_file="$1"
  grep -Eqi \
    'ERR_PNPM_FETCH_|Unknown Status - 567|ETIMEDOUT|ECONNRESET|EAI_AGAIN|ERR_SOCKET_TIMEOUT|CERT_HAS_EXPIRED' \
    "$log_file"
}

run_step_script() {
  local script_path="$1"
  local log_path="$2"

  set +e
  bash "${script_path}" 2>&1 | tee "${log_path}"
  local run_code=${PIPESTATUS[0]}
  set -e

  return "${run_code}"
}

retry_openclaw_install_with_registries() {
  local script_path="$1"
  local registry
  local idx=0
  local total=${#REGISTRY_CANDIDATES[@]}

  for registry in "${REGISTRY_CANDIDATES[@]}"; do
    idx=$((idx + 1))
    apply_registry_override "${registry}"
    patch_hardcoded_registry_in_script "${script_path}" "${registry}"
    CURRENT_TMP_LOG="$(mktemp /tmp/openclaw-install-XXXXXX.log)"
    log_warn "Retrying 02-install-openclaw.sh with registry (${idx}/${total})..."

    if run_step_script "${script_path}" "${CURRENT_TMP_LOG}"; then
      log_info "Retry succeeded with registry: $(normalize_registry "${registry}")"
      return 0
    fi

    if is_pnpm_fetch_issue "${CURRENT_TMP_LOG}"; then
      log_warn "Still failed with network/registry error; trying next registry."
      continue
    fi

    # Non-network failure: stop retrying and let upper logic handle the real cause.
    return 1
  done

  return 1
}

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
    log_warn "openclaw command not found; cannot recover gateway service."
    return 1
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    log_warn "systemctl not found; skip systemd recovery."
    return 1
  fi

  prepare_user_systemd_context
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
    log_warn "systemctl --user daemon-reload failed."
    return 1
  fi

  if ! systemctl --user enable --now openclaw-gateway.service >/dev/null 2>&1; then
    log_warn "systemctl --user enable --now openclaw-gateway.service failed."
    return 1
  fi

  log_info "Gateway service installed and started via user systemd unit."
  return 0
}

fallback_start_gateway_process() {
  local gateway_log

  if ! command -v openclaw >/dev/null 2>&1; then
    return 1
  fi

  openclaw config set gateway.mode local >/dev/null 2>&1 || true

  gateway_log="/tmp/openclaw-gateway.log"
  nohup openclaw gateway --port 18789 --bind loopback >"${gateway_log}" 2>&1 &
  sleep 2

  if openclaw gateway status --require-rpc >/dev/null 2>&1; then
    log_warn "Gateway started as background process (not systemd). Log: ${gateway_log}"
    return 0
  fi

  log_warn "Failed to start gateway background process. Check: ${gateway_log}"
  return 1
}

recover_gateway_install_failure() {
  log_warn "Detected known Gateway service install issue. Starting recovery..."

  if ! command -v openclaw >/dev/null 2>&1; then
    log_error "openclaw command missing; cannot recover."
    return 1
  fi

  if openclaw gateway install --force >/tmp/openclaw-gateway-fix.log 2>&1; then
    log_info "Gateway recovery via 'openclaw gateway install --force' succeeded."
    return 0
  fi

  log_warn "Official gateway install recovery failed; trying manual user service."

  if manual_install_gateway_service; then
    return 0
  fi

  log_warn "Manual systemd recovery failed; trying background fallback."
  if fallback_start_gateway_process; then
    return 0
  fi

  log_error "Gateway automatic recovery failed. Run: openclaw doctor && openclaw gateway status --deep"
  return 1
}

run_remote_script() {
  local script_name="$1"
  local description="$2"
  local url="${BASE_URL}/${script_name}"

  log_info "========================================"
  log_info "Step: ${description}"
  log_info "URL:  ${url}"
  log_info "========================================"

  CURRENT_TMP_SCRIPT="$(mktemp /tmp/openclaw-install-XXXXXX.sh)"
  CURRENT_TMP_LOG="$(mktemp /tmp/openclaw-install-XXXXXX.log)"

  if ! curl -fSL --connect-timeout 10 --max-time 180 -o "${CURRENT_TMP_SCRIPT}" "${url}"; then
    log_error "Download failed: ${script_name}"
    cleanup_tmp
    return 1
  fi

  chmod +x "${CURRENT_TMP_SCRIPT}"

  if [ "${script_name}" = "02-install-openclaw.sh" ]; then
    apply_registry_override "${REGISTRY_CANDIDATES[0]}"
    patch_hardcoded_registry_in_script "${CURRENT_TMP_SCRIPT}" "${REGISTRY_CANDIDATES[0]}"
  fi

  local run_code=0
  if run_step_script "${CURRENT_TMP_SCRIPT}" "${CURRENT_TMP_LOG}"; then
    run_code=0
  else
    run_code=$?
  fi

  if [ "${run_code}" -ne 0 ]; then
    if [ "${script_name}" = "02-install-openclaw.sh" ] && is_pnpm_fetch_issue "${CURRENT_TMP_LOG}"; then
      log_warn "Detected pnpm fetch/network failure in 02 step."
      if retry_openclaw_install_with_registries "${CURRENT_TMP_SCRIPT}"; then
        cleanup_tmp
        log_info "Done (recovered by registry retry): ${description}"
        echo ""
        return 0
      fi
    fi

    if [ "${script_name}" = "02-install-openclaw.sh" ] && is_gateway_service_known_issue "${CURRENT_TMP_LOG}"; then
      if recover_gateway_install_failure; then
        log_warn "Gateway issue recovered; continue installation."
        cleanup_tmp
        log_info "Done (recovered): ${description}"
        echo ""
        return 0
      fi
    fi

    log_error "Execution failed: ${script_name}"
    cleanup_tmp
    return 1
  fi

  cleanup_tmp
  log_info "Done: ${description}"
  echo ""
}

verify_install() {
  log_info "Verifying installation..."

  set +e
  source /etc/profile >/dev/null 2>&1
  set +e

  if [ -s "${NVM_DIR:-/usr/local/nvm}/nvm.sh" ]; then
    source "${NVM_DIR:-/usr/local/nvm}/nvm.sh"
  fi

  if ! command -v openclaw >/dev/null 2>&1; then
    log_error "Verification failed: openclaw command unavailable"
    return 1
  fi

  openclaw --version || return 1

  if ! openclaw doctor --non-interactive; then
    log_warn "'openclaw doctor' returned non-zero; please inspect manually."
  fi

  if ! openclaw gateway status --require-rpc; then
    log_warn "Gateway RPC check failed; run: openclaw gateway status --deep"
  fi

  return 0
}

main() {
  log_info "========== OpenClaw one-click installer =========="
  log_info "Start time: $(date)"
  log_info "Heartbeat every ${HEARTBEAT_SECONDS}s"
  echo ""

  start_heartbeat
  export OPENCLAW_HEARTBEAT_ACTIVE=1

  local failed=0

  for step in "${STEPS[@]}"; do
    local script_name="${step%%|*}"
    local description="${step##*|}"

    if ! run_remote_script "${script_name}" "${description}"; then
      log_error "${description} failed; aborting."
      failed=1
      break
    fi
  done

  echo ""
  if [ "${failed}" -eq 0 ]; then
    if verify_install; then
      log_info "========== Installation complete =========="
      log_info "Recommended check: openclaw gateway status --deep"
    else
      log_error "Install finished but verification found issues."
      exit 1
    fi

    stop_heartbeat
    exec bash -l
  else
    log_error "========== Installation failed =========="
    log_error "Please check above logs and rerun after fixing issues."
    exit 1
  fi
}

main "$@"
