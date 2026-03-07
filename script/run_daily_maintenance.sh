#!/bin/bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/common_domain_db.sh"
load_management_config

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

echo "Running daily maintenance for domains: ${domains_arg}"

for domain_name in "${DOMAINS[@]}"; do
  db_host="$(resolve_db_host_for_domain "$domain_name")" || {
    failures=$((failures + 1))
    continue
  }

  echo "[${domain_name}] Preparing database backup from ${db_host}:${DB_PORT}"
  create_mysql_client_config "$db_host"

  if ! mysql_exec -e "SELECT 1;" >/dev/null 2>&1; then
    echo "[${domain_name}] Error: failed to connect to ${DB_NAME} on ${db_host}" >&2
    cleanup_mysql_client_config
    failures=$((failures + 1))
    continue
  fi

  if ! backup_database_locally "$domain_name"; then
    echo "[${domain_name}] Error: backup failed" >&2
    failures=$((failures + 1))
  fi

  cleanup_mysql_client_config
done

echo "Running expiration reminder emails..."
if ! python3 "${SCRIPT_DIR}/send_expiration_reminder_emails.py" --domains "${domains_arg}"; then
  echo "Error: reminder email run failed." >&2
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  echo "Daily maintenance finished with ${failures} failure(s)." >&2
  exit 1
fi

echo "Daily maintenance completed successfully."
