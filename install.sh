#!/usr/bin/env bash
# OpenClaw one-click installer with Gateway recovery
# Target: Ubuntu 22.04 / 24.04
#
# Prefer: sudo -H bash install.sh   (so HOME=/root when installing as root)
# Env: OPENCLAW_SKIP_LOGIN_SHELL=1 — skip «exec bash -l» after success
#      OPENCLAW_FORCE_LOGIN_SHELL=1 — force login shell even when stdin is not a TTY
#      OPENCLAW_GATEWAY_INSTALL_TIMEOUT_SEC — recovery «gateway install --force» timeout (default 240)
#      OPENCLAW_NO_GATEWAY_INSTALL_TIMEOUT=1 — do not use timeout(1) on recovery install

# Re-exec with bash when started by sh/dash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -Eeuo pipefail

BASE_URL="https://orcaterm-script-1258344699.cos.ap-shanghai.myqcloud.com/linux/AI/openclaw"
HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-15}"
OPENCLAW_SKIP_LOGIN_SHELL="${OPENCLAW_SKIP_LOGIN_SHELL:-0}"

HEARTBEAT_PID=""
CURRENT_TMP_SCRIPT=""
CURRENT_TMP_LOG=""
STEP02_ORIG_FAIL_LOG=""
NPM_USERCONFIG_TMP=""
OPENCLAW_BIN=""

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
  [ -n "${STEP02_ORIG_FAIL_LOG:-}" ] && rm -f "${STEP02_ORIG_FAIL_LOG}" 2>/dev/null || true
  CURRENT_TMP_SCRIPT=""
  CURRENT_TMP_LOG=""
  STEP02_ORIG_FAIL_LOG=""
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

bootstrap_node_env() {
  # Try common profile files first.
  [ -f /etc/profile ] && source /etc/profile >/dev/null 2>&1 || true
  [ -f /etc/bash.bashrc ] && source /etc/bash.bashrc >/dev/null 2>&1 || true
  [ -f "${HOME}/.profile" ] && source "${HOME}/.profile" >/dev/null 2>&1 || true
  [ -f "${HOME}/.bashrc" ] && source "${HOME}/.bashrc" >/dev/null 2>&1 || true

  # NVM initialization (common locations).
  if [ -s "${NVM_DIR:-/usr/local/nvm}/nvm.sh" ]; then
    source "${NVM_DIR:-/usr/local/nvm}/nvm.sh" >/dev/null 2>&1 || true
  fi
  if [ -s "${HOME}/.nvm/nvm.sh" ]; then
    source "${HOME}/.nvm/nvm.sh" >/dev/null 2>&1 || true
  fi

  # Ensure global npm bin is in PATH.
  if command -v npm >/dev/null 2>&1; then
    local npm_prefix
    npm_prefix="$(npm prefix -g 2>/dev/null || true)"
    if [ -n "${npm_prefix}" ] && [ -d "${npm_prefix}/bin" ]; then
      case ":$PATH:" in
        *":${npm_prefix}/bin:"*) ;;
        *) export PATH="${npm_prefix}/bin:${PATH}" ;;
      esac
    fi
  fi

  # Common fallback paths.
  case ":$PATH:" in
    *":${HOME}/.npm-global/bin:"*) ;;
    *) [ -d "${HOME}/.npm-global/bin" ] && export PATH="${HOME}/.npm-global/bin:${PATH}" ;;
  esac
  case ":$PATH:" in
    *":${HOME}/.local/bin:"*) ;;
    *) [ -d "${HOME}/.local/bin" ] && export PATH="${HOME}/.local/bin:${PATH}" ;;
  esac
  case ":$PATH:" in
    *":${HOME}/.openclaw/bin:"*) ;;
    *) [ -d "${HOME}/.openclaw/bin" ] && export PATH="${HOME}/.openclaw/bin:${PATH}" ;;
  esac

  # pnpm global bin directory (COS installer often uses pnpm).
  if command -v pnpm >/dev/null 2>&1; then
    local pnpm_global_bin
    pnpm_global_bin="$(pnpm bin -g 2>/dev/null || true)"
    if [ -n "${pnpm_global_bin}" ] && [ -d "${pnpm_global_bin}" ]; then
      case ":$PATH:" in *":${pnpm_global_bin}:"*) ;; *) export PATH="${pnpm_global_bin}:${PATH}" ;; esac
    fi
  fi

  # Effective root but HOME still /home/foo (sudo without -H): binaries often under /root.
  if [ "$(id -u)" -eq 0 ]; then
    local rb
    for rb in /root/.local/bin /root/.npm-global/bin /root/.openclaw/bin; do
      [ -d "${rb}" ] || continue
      case ":$PATH:" in *":${rb}:"*) ;; *) export PATH="${rb}:${PATH}" ;; esac
    done
  fi

  hash -r 2>/dev/null || true
}

ensure_openclaw_command() {
  if [ -n "${OPENCLAW_BIN}" ] && [ -x "${OPENCLAW_BIN}" ]; then
    return 0
  fi

  bootstrap_node_env

  if command -v openclaw >/dev/null 2>&1; then
    OPENCLAW_BIN="$(command -v openclaw)"
    return 0
  fi

  local candidate
  for candidate in \
    "${HOME}/.npm-global/bin/openclaw" \
    "${HOME}/.local/bin/openclaw" \
    "${HOME}/.openclaw/bin/openclaw" \
    "/root/.local/bin/openclaw" \
    "/root/.npm-global/bin/openclaw" \
    "/root/.openclaw/bin/openclaw" \
    "/usr/local/bin/openclaw" \
    "/usr/bin/openclaw"
  do
    if [ -x "${candidate}" ]; then
      OPENCLAW_BIN="${candidate}"
      return 0
    fi
  done

  return 1
}

openclaw_exec() {
  ensure_openclaw_command || return 127
  "${OPENCLAW_BIN}" "$@"
}

debug_openclaw_env() {
  log_warn "Diagnostics: PATH=${PATH}"
  log_warn "Diagnostics: node=$(command -v node || echo missing), npm=$(command -v npm || echo missing), openclaw=$(command -v openclaw || echo missing)"
  if command -v npm >/dev/null 2>&1; then
    log_warn "Diagnostics: npm prefix -g=$(npm prefix -g 2>/dev/null || echo unknown)"
  fi
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

bootstrap_openclaw_cli() {
  local registry
  local npm_prefix="${HOME}/.npm-global"

  if ensure_openclaw_command; then
    return 0
  fi

  bootstrap_node_env
  if ! command -v npm >/dev/null 2>&1; then
    log_warn "npm command not found; cannot auto-install openclaw CLI."
    return 1
  fi

  mkdir -p "${npm_prefix}/bin" >/dev/null 2>&1 || true
  export NPM_CONFIG_PREFIX="${npm_prefix}"
  export npm_config_prefix="${npm_prefix}"
  case ":$PATH:" in
    *":${npm_prefix}/bin:"*) ;;
    *) export PATH="${npm_prefix}/bin:${PATH}" ;;
  esac

  local bootstrap_log
  bootstrap_log="$(mktemp /tmp/openclaw-cli-bootstrap-XXXXXX.log)"

  for registry in "${REGISTRY_CANDIDATES[@]}"; do
    apply_registry_override "${registry}"
    log_warn "openclaw CLI missing; trying npm install with registry: $(normalize_registry "${registry}")"
    if npm install -g openclaw@latest >"${bootstrap_log}" 2>&1; then
      if ensure_openclaw_command; then
        log_info "openclaw CLI bootstrap succeeded: ${OPENCLAW_BIN}"
        rm -f "${bootstrap_log}" 2>/dev/null || true
        return 0
      fi
    fi
  done

  log_error "Failed to bootstrap openclaw CLI. Log: ${bootstrap_log}"
  return 1
}

retry_openclaw_install_with_registries() {
  local script_path="$1"
  local registry
  local idx=0
  local total=${#REGISTRY_CANDIDATES[@]}
  local prev_log=""

  for registry in "${REGISTRY_CANDIDATES[@]}"; do
    idx=$((idx + 1))
    apply_registry_override "${registry}"
    patch_hardcoded_registry_in_script "${script_path}" "${registry}"
    if [ -n "${prev_log}" ]; then
      rm -f "${prev_log}" 2>/dev/null || true
    fi
    CURRENT_TMP_LOG="$(mktemp /tmp/openclaw-install-XXXXXX.log)"
    prev_log="${CURRENT_TMP_LOG}"
    log_warn "Retrying 02-install-openclaw.sh with registry (${idx}/${total})..."

    if run_step_script "${script_path}" "${CURRENT_TMP_LOG}"; then
      log_info "Retry succeeded with registry: $(normalize_registry "${registry}")"
      rm -f "${CURRENT_TMP_LOG}" 2>/dev/null || true
      CURRENT_TMP_LOG=""
      prev_log=""
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
  [ -n "${log_file}" ] && [ -f "${log_file}" ] || return 1
  grep -Eqi \
    'openclaw-gateway(\.service)? does not exist|Gateway install failed|systemctl enable failed|Failed to enable unit|Unit file openclaw-gateway|systemctl( --user)? is-enabled unavailable|Failed to connect to bus' \
    "$log_file"
}

step02_gateway_recovery_candidate() {
  local f
  for f in "$@"; do
    [ -z "${f}" ] && continue
    is_gateway_service_known_issue "${f}" && return 0
  done
  return 1
}

try_gateway_recovery_step02() {
  local script_name="$1"
  local description="$2"

  if [ "${script_name}" != "02-install-openclaw.sh" ]; then
    return 1
  fi
  if ! step02_gateway_recovery_candidate "${STEP02_ORIG_FAIL_LOG}" "${CURRENT_TMP_LOG}"; then
    return 1
  fi
  if ! recover_gateway_install_failure; then
    return 1
  fi
  log_warn "Gateway issue recovered; continue installation."
  cleanup_tmp
  log_info "Done (recovered): ${description}"
  echo ""
  return 0
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
  local openclaw_bin

  if ! ensure_openclaw_command; then
    log_warn "openclaw command not found; cannot recover gateway service."
    return 1
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    log_warn "systemctl not found; skip systemd recovery."
    return 1
  fi

  openclaw_exec config set gateway.mode local >/dev/null 2>&1 || true
  openclaw_bin="${OPENCLAW_BIN}"

  # Root install: prefer system service to avoid user-bus issues.
  if [ "$(id -u)" -eq 0 ]; then
    local svc_file="/etc/systemd/system/openclaw-gateway.service"
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
WantedBy=multi-user.target
EOF

    if ! systemctl daemon-reload >/dev/null 2>&1; then
      log_warn "systemctl daemon-reload failed."
      return 1
    fi

    if ! systemctl enable --now openclaw-gateway.service >/dev/null 2>&1; then
      log_warn "systemctl enable --now openclaw-gateway.service failed."
      return 1
    fi

    log_info "Gateway service installed and started via system systemd unit."
    return 0
  fi

  # Non-root install: user service.
  prepare_user_systemd_context
  local svc_dir="${HOME}/.config/systemd/user"
  local svc_file="${svc_dir}/openclaw-gateway.service"

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

  if ! ensure_openclaw_command; then
    return 1
  fi

  openclaw_exec config set gateway.mode local >/dev/null 2>&1 || true

  gateway_log="/tmp/openclaw-gateway.log"
  nohup "${OPENCLAW_BIN}" gateway --port 18789 --bind loopback >"${gateway_log}" 2>&1 &

  local attempt
  for attempt in $(seq 1 20); do
    sleep 2
    if openclaw_exec gateway status --require-rpc >/dev/null 2>&1; then
      log_warn "Gateway started as background process (not systemd). Log: ${gateway_log}"
      return 0
    fi
  done

  log_warn "Failed to start gateway background process after ~40s. Check: ${gateway_log}"
  return 1
}

recover_gateway_install_failure() {
  log_warn "Detected known Gateway service install issue. Starting recovery..."
  log_info "Recovery steps: (1) openclaw gateway install --force (2) systemd unit (3) nohup."

  bootstrap_node_env

  if ! ensure_openclaw_command; then
    debug_openclaw_env
    log_warn "openclaw not in PATH after bootstrap; trying CLI bootstrap..."
    if ! bootstrap_openclaw_cli; then
      debug_openclaw_env
      log_error "Still cannot find «openclaw». If you used sudo, try: sudo -H bash $0"
      log_error "Or run: hash -r && command -v openclaw"
      return 1
    fi
  fi

  log_info "Recovery: using OPENCLAW_BIN=${OPENCLAW_BIN}"

  local gw_fix_log
  gw_fix_log="$(mktemp /tmp/openclaw-gateway-fix-XXXXXX.log)"
  log_info "Recovery 1/3: «openclaw gateway install --force» (log: ${gw_fix_log}; may take up to a few minutes)..."

  local gw_force_ok=1
  local tsec="${OPENCLAW_GATEWAY_INSTALL_TIMEOUT_SEC:-240}"

  set +e
  if command -v timeout >/dev/null 2>&1 && [ "${OPENCLAW_NO_GATEWAY_INSTALL_TIMEOUT:-0}" != "1" ]; then
    timeout "${tsec}" "${OPENCLAW_BIN}" gateway install --force >>"${gw_fix_log}" 2>&1
    gw_force_ok=$?
    if [ "${gw_force_ok}" -eq 124 ]; then
      log_warn "«gateway install --force» exceeded ${tsec}s; trying manual systemd unit."
      gw_force_ok=1
    fi
  else
    "${OPENCLAW_BIN}" gateway install --force >>"${gw_fix_log}" 2>&1
    gw_force_ok=$?
  fi
  set -e

  if [ "${gw_force_ok}" -eq 0 ]; then
    log_info "Gateway recovery via «gateway install --force» succeeded."
    rm -f "${gw_fix_log}" 2>/dev/null || true
    return 0
  fi

  log_warn "«gateway install --force» failed. Last lines from ${gw_fix_log}:"
  tail -25 "${gw_fix_log}" 2>/dev/null | while IFS= read -r line || [ -n "${line}" ]; do log_warn "  ${line}"; done || true
  rm -f "${gw_fix_log}" 2>/dev/null || true

  log_info "Recovery 2/3: writing systemd unit under /etc/systemd/system (root) or user systemd..."
  if manual_install_gateway_service; then
    return 0
  fi

  log_info "Recovery 3/3: starting gateway with nohup..."
  if fallback_start_gateway_process; then
    return 0
  fi

  log_error "Gateway automatic recovery failed. Run as root if needed: sudo openclaw doctor && sudo openclaw gateway status --deep"
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
  STEP02_ORIG_FAIL_LOG=""

  if ! curl -fSL --connect-timeout 15 --max-time 300 --retry 3 --retry-delay 2 \
    -o "${CURRENT_TMP_SCRIPT}" "${url}"; then
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
    if [ "${script_name}" = "02-install-openclaw.sh" ]; then
      STEP02_ORIG_FAIL_LOG="${CURRENT_TMP_LOG}"
    fi

    if try_gateway_recovery_step02 "${script_name}" "${description}"; then
      return 0
    fi

    if [ "${script_name}" = "02-install-openclaw.sh" ] && is_pnpm_fetch_issue "${STEP02_ORIG_FAIL_LOG}"; then
      log_warn "Detected pnpm fetch/network failure in 02 step."
      if retry_openclaw_install_with_registries "${CURRENT_TMP_SCRIPT}"; then
        cleanup_tmp
        log_info "Done (recovered by registry retry): ${description}"
        echo ""
        return 0
      fi
    fi

    if try_gateway_recovery_step02 "${script_name}" "${description}"; then
      return 0
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

  bootstrap_node_env

  if ! ensure_openclaw_command; then
    log_error "Verification failed: openclaw command unavailable"
    return 1
  fi

  openclaw_exec --version || return 1

  if ! openclaw_exec doctor --non-interactive; then
    log_warn "'openclaw doctor' returned non-zero; please inspect manually."
  fi

  if ! openclaw_exec gateway status --require-rpc; then
    log_warn "Gateway RPC check failed; run: openclaw gateway status --deep"
  fi

  return 0
}

main() {
  log_info "========== OpenClaw one-click installer =========="
  log_info "Start time: $(date)"
  log_info "Heartbeat every ${HEARTBEAT_SECONDS}s"
  echo ""

  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${HOME}" != "/root" ]; then
    log_warn "You are root via sudo but HOME=${HOME} (not /root). Prefer: sudo -H bash $0"
    log_warn "Otherwise recovery may not find the «openclaw» binary installed under /root."
  fi

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
      cleanup_registry_override
      stop_heartbeat
      exit 1
    fi

    stop_heartbeat
    cleanup_registry_override

    if [ "${OPENCLAW_SKIP_LOGIN_SHELL}" = "1" ]; then
      log_info "OPENCLAW_SKIP_LOGIN_SHELL=1 — exiting without login shell."
      exit 0
    fi

    if [ "${OPENCLAW_FORCE_LOGIN_SHELL:-0}" != "1" ] && [ ! -t 0 ]; then
      log_info "stdin is not a terminal — skipping «exec bash -l» (use OPENCLAW_FORCE_LOGIN_SHELL=1 to force)."
      exit 0
    fi

    exec bash -l
  else
    log_error "========== Installation failed =========="
    log_error "Please check above logs and rerun after fixing issues."
    exit 1
  fi
}

main "$@"
