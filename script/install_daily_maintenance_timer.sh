#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${PROJECT_ROOT}/config"

SERVICE_NAME="uid-gid-daily-maintenance"
UNIT_DIR="/etc/systemd/system"
SERVICE_FILE="${UNIT_DIR}/${SERVICE_NAME}.service"
TIMER_FILE="${UNIT_DIR}/${SERVICE_NAME}.timer"
LOGROTATE_FILE="/etc/logrotate.d/${SERVICE_NAME}"
RUNNER_SCRIPT="${SCRIPT_DIR}/run_daily_maintenance.sh"
CONFIG_FILE="${CONFIG_DIR}/daily_maintenance.local.env"
ON_CALENDAR="*-*-* 11:00:00 Asia/Seoul"
LOG_FILE="/var/log/${SERVICE_NAME}.log"
LOG_ROTATE_COUNT=14
RUNNER_DOMAINS=""
FORCE_INSTALL=false
ORIGINAL_ARGS=("$@")

show_help() {
  cat <<EOF
Usage: $0 [options]

Options:
  --config PATH         config file path (default: ${CONFIG_FILE})
  --on-calendar VALUE   systemd OnCalendar value
  --log-file PATH       log file path
  --rotate-count N      logrotate daily retention count
  --domains CSV         domains passed to run_daily_maintenance.sh
  --force               rewrite files even when contents are unchanged
  -h, --help            show this help
EOF
}

for ((i = 0; i < ${#ORIGINAL_ARGS[@]}; i++)); do
  case "${ORIGINAL_ARGS[$i]}" in
  --config)
    if [ $((i + 1)) -ge ${#ORIGINAL_ARGS[@]} ]; then
      echo "Error: --config requires a value." >&2
      exit 1
    fi
    CONFIG_FILE="${ORIGINAL_ARGS[$((i + 1))]}"
    i=$((i + 1))
    ;;
  *)
    ;;
  esac
done

if [ -f "${CONFIG_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
  set +a
fi

if [ -n "${DAILY_MAINTENANCE_ON_CALENDAR:-}" ]; then
  ON_CALENDAR="${DAILY_MAINTENANCE_ON_CALENDAR}"
fi

if [ -n "${DAILY_MAINTENANCE_LOG_FILE:-}" ]; then
  LOG_FILE="${DAILY_MAINTENANCE_LOG_FILE}"
fi

if [ -n "${DAILY_MAINTENANCE_LOG_ROTATE_COUNT:-}" ]; then
  LOG_ROTATE_COUNT="${DAILY_MAINTENANCE_LOG_ROTATE_COUNT}"
fi

if [ -n "${DAILY_MAINTENANCE_DOMAINS:-}" ]; then
  RUNNER_DOMAINS="${DAILY_MAINTENANCE_DOMAINS}"
fi

set -- "${ORIGINAL_ARGS[@]}"

while [[ $# -gt 0 ]]; do
  case "$1" in
  --config)
    shift 2
    ;;
  --on-calendar)
    ON_CALENDAR="$2"
    shift 2
    ;;
  --log-file)
    LOG_FILE="$2"
    shift 2
    ;;
  --rotate-count)
    LOG_ROTATE_COUNT="$2"
    shift 2
    ;;
  --domains)
    RUNNER_DOMAINS="$2"
    shift 2
    ;;
  --force)
    FORCE_INSTALL=true
    shift
    ;;
  -h | --help)
    show_help
    exit 0
    ;;
  *)
    echo "Unknown option: $1" >&2
    show_help
    exit 1
    ;;
  esac
done

if ! command -v systemctl >/dev/null 2>&1; then
  echo "Error: systemctl is required." >&2
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
  echo "Error: sudo is required to install system units under /etc/systemd/system." >&2
  exit 1
fi

if [ ! -x "${RUNNER_SCRIPT}" ]; then
  chmod +x "${RUNNER_SCRIPT}"
fi

if ! [[ "${LOG_ROTATE_COUNT}" =~ ^[0-9]+$ ]] || [ "${LOG_ROTATE_COUNT}" -lt 1 ]; then
  echo "Error: --rotate-count must be a positive integer." >&2
  exit 1
fi

install_user="${SUDO_USER:-$USER}"
install_group="$(id -gn "${install_user}")"
runner_args=()

if [ -n "${RUNNER_DOMAINS}" ]; then
  runner_args+=("${RUNNER_DOMAINS}")
fi

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

service_tmp="${tmp_dir}/${SERVICE_NAME}.service"
timer_tmp="${tmp_dir}/${SERVICE_NAME}.timer"
logrotate_tmp="${tmp_dir}/${SERVICE_NAME}.logrotate"
runner_args_str=""

if [ ${#runner_args[@]} -gt 0 ]; then
  runner_args_str=" ${runner_args[*]}"
fi

cat >"${service_tmp}" <<EOF
[Unit]
Description=UID/GID daily maintenance (backups and reminder emails)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=${install_user}
Group=${install_group}
WorkingDirectory=${PROJECT_ROOT}
ExecStart=${RUNNER_SCRIPT}${runner_args_str}
Environment=PYTHONUNBUFFERED=1
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF

cat >"${timer_tmp}" <<EOF
[Unit]
Description=Run UID/GID daily maintenance every day

[Timer]
OnCalendar=${ON_CALENDAR}
Persistent=true
Unit=${SERVICE_NAME}.service

[Install]
WantedBy=timers.target
EOF

cat >"${logrotate_tmp}" <<EOF
${LOG_FILE} {
    daily
    rotate ${LOG_ROTATE_COUNT}
    compress
    delaycompress
    missingok
    notifempty
    create 0640 ${install_user} ${install_group}
}
EOF

sync_root_file() {
  local source_file="$1"
  local target_file="$2"
  local mode="$3"
  local label="$4"

  if run_as_root test -f "${target_file}"; then
    if [ "${FORCE_INSTALL}" = "false" ] && run_as_root cmp -s "${source_file}" "${target_file}"; then
      echo "${label} is already up to date: ${target_file}"
      return
    fi
    run_as_root install -D -m "${mode}" "${source_file}" "${target_file}"
    echo "Updated ${label}: ${target_file}"
    return
  fi

  run_as_root install -D -m "${mode}" "${source_file}" "${target_file}"
  echo "Installed ${label}: ${target_file}"
}

sync_root_file "${service_tmp}" "${SERVICE_FILE}" 0644 "service"
sync_root_file "${timer_tmp}" "${TIMER_FILE}" 0644 "timer"

if ! run_as_root test -f "${LOG_FILE}"; then
  run_as_root install -D -m 0640 /dev/null "${LOG_FILE}"
fi
run_as_root chown "${install_user}:${install_group}" "${LOG_FILE}"

sync_root_file "${logrotate_tmp}" "${LOGROTATE_FILE}" 0644 "logrotate config"

run_as_root systemctl daemon-reload
run_as_root systemctl enable "${SERVICE_NAME}.timer"

if run_as_root systemctl is-active --quiet "${SERVICE_NAME}.timer"; then
  run_as_root systemctl restart "${SERVICE_NAME}.timer"
else
  run_as_root systemctl start "${SERVICE_NAME}.timer"
fi

if run_as_root systemctl is-active --quiet "${SERVICE_NAME}.timer"; then
  echo "Timer is active: ${SERVICE_NAME}.timer"
else
  echo "Warning: timer is not active: ${SERVICE_NAME}.timer" >&2
fi

echo "Next runs:"
run_as_root systemctl list-timers "${SERVICE_NAME}.timer" --no-pager || true

echo
echo "To run the job immediately:"
echo "  sudo systemctl start ${SERVICE_NAME}.service"
echo
echo "Config file:"
echo "  ${CONFIG_FILE}"
echo "Log file:"
echo "  ${LOG_FILE}"
echo "Retention:"
echo "  ${LOG_ROTATE_COUNT} days via ${LOGROTATE_FILE}"
