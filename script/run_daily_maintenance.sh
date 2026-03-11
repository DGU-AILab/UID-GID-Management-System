#!/bin/bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/common_domain_db.sh"
load_management_config
load_daily_maintenance_config
redirect_logs_to_file_if_configured || true

trap cleanup_mysql_client_config EXIT

require_mysql_cli || exit 1
require_mysqldump_cli || exit 1
require_command "python3" "install Python 3 on the management server." || exit 1

domains_csv="${1:-${EXPORT_DOMAINS:-${SERVER_DOMAIN:-LAB,FARM}}}"
IFS=',' read -ra RAW_DOMAINS <<<"$domains_csv"

DOMAINS=()
for raw_domain in "${RAW_DOMAINS[@]}"; do
  [ -z "${raw_domain// }" ] && continue
  normalized_domain="$(normalize_domain_name "$raw_domain")" || exit 1
  DOMAINS+=("$normalized_domain")
done

if [ ${#DOMAINS[@]} -eq 0 ]; then
  echo "Error: no valid domains configured for daily maintenance." >&2
  exit 1
fi

domains_arg=$(IFS=,; echo "${DOMAINS[*]}")
failures=0

log_event "BACKUP" "daily_maintenance_started domains=${domains_arg}"

for domain_name in "${DOMAINS[@]}"; do
  db_host="$(resolve_db_host_for_domain "$domain_name")" || {
    failures=$((failures + 1))
    continue
  }

  log_event "BACKUP" "backup_started domain=${domain_name} host=${db_host} port=${DB_PORT}"
  create_mysql_client_config "$db_host"

  if ! mysql_exec -e "SELECT 1;" >/dev/null 2>&1; then
    log_error "backup_db_connect_failed domain=${domain_name} database=${DB_NAME} host=${db_host} port=${DB_PORT}"
    cleanup_mysql_client_config
    failures=$((failures + 1))
    continue
  fi

  if ! backup_database_locally "$domain_name"; then
    log_error "backup_failed domain=${domain_name}"
    failures=$((failures + 1))
  fi

  cleanup_mysql_client_config
done

log_event "REMINDER" "reminder_run_started domains=${domains_arg}"
if ! python3 "${SCRIPT_DIR}/send_expiration_reminder_emails.py" --domains "${domains_arg}"; then
  log_error "reminder_run_failed domains=${domains_arg}"
  failures=$((failures + 1))
fi

log_event "DELETE" "expired_cleanup_started domains=${domains_arg}"
if ! bash "${PROJECT_ROOT}/maintenance/delete_expired_containers.sh" --domains "${domains_arg}" --apply; then
  log_error "expired_cleanup_failed domains=${domains_arg}"
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  log_error "daily_maintenance_finished failures=${failures}"
  exit 1
fi

log_event "BACKUP" "daily_maintenance_completed domains=${domains_arg} failures=0"
