#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_ROOT}/script/common_domain_db.sh"
load_management_config

trap cleanup_mysql_client_config EXIT

apply_changes=false
dry_run=true
today_date="$(date +%F)"
domains_csv="${EXPORT_DOMAINS:-${SERVER_DOMAIN:-LAB,FARM}}"

show_help() {
  cat <<EOF
Usage: $0 [options]

Options:
  --dry-run        list expired containers only (default behavior)
  --apply          delete expired containers after listing them
  --today DATE     기준 날짜 (YYYY-MM-DD). 기본값은 오늘
  --domains CSV    조회할 도메인 목록 (예: LAB,FARM)
  -h, --help       show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --apply)
    apply_changes=true
    dry_run=false
    shift
    ;;
  --dry-run)
    dry_run=true
    apply_changes=false
    shift
    ;;
  --today)
    today_date="$2"
    shift 2
    ;;
  --domains)
    domains_csv="$2"
    shift 2
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

if ! [[ "${today_date}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "Error: --today must be in YYYY-MM-DD format." >&2
  exit 1
fi

require_mysql_cli || exit 1

IFS=',' read -ra RAW_DOMAINS <<<"${domains_csv}"
DOMAINS=()
for raw_domain in "${RAW_DOMAINS[@]}"; do
  [ -z "${raw_domain// }" ] && continue
  normalized_domain="$(normalize_domain_name "$raw_domain")" || exit 1
  DOMAINS+=("${normalized_domain}")
done

if [ ${#DOMAINS[@]} -eq 0 ]; then
  echo "Error: no valid domains configured." >&2
  exit 1
fi

DELETE_SCRIPT="${PROJECT_ROOT}/script/delete_container.sh"
if [ ! -x "${DELETE_SCRIPT}" ]; then
  echo "Error: delete script not found or not executable: ${DELETE_SCRIPT}" >&2
  exit 1
fi

total_found=0
total_deleted=0
updated_domains=()

mark_domain_updated() {
  local domain_name="$1"
  local existing
  for existing in "${updated_domains[@]:-}"; do
    if [ "${existing}" = "${domain_name}" ]; then
      return
    fi
  done
  updated_domains+=("${domain_name}")
}

if [ "${dry_run}" = "true" ]; then
  echo "[DRY-RUN] Checking expired active containers as of ${today_date}"
else
  echo "Checking expired active containers as of ${today_date}"
fi
echo

for domain_name in "${DOMAINS[@]}"; do
  db_host="$(resolve_db_host_for_domain "$domain_name")" || exit 1
  create_mysql_client_config "$db_host"

  if ! mysql_exec -e "SELECT 1;" >/dev/null 2>&1; then
    echo "[${domain_name}] Error: failed to connect to ${DB_NAME} on ${db_host}" >&2
    exit 1
  fi

  expired_rows="$(mysql_exec --batch --raw -N -e "
    SELECT
      dc.container_id,
      dc.container_name,
      dc.server_id,
      DATE_FORMAT(dc.expiring_at, '%%Y-%%m-%%d'),
      u.name,
      u.ubuntu_username
    FROM docker_container dc
    JOIN user u ON u.id = dc.user_id
    WHERE dc.existing = 1
      AND DATE(dc.expiring_at) < DATE('${today_date}')
    ORDER BY dc.expiring_at ASC, dc.server_id ASC, dc.container_name ASC;
  ")"

  cleanup_mysql_client_config

  if [ -z "${expired_rows}" ]; then
    echo "[${domain_name}] No expired active containers."
    echo
    continue
  fi

  domain_count=0
  echo "[${domain_name}] Expired active containers:"
  while IFS=$'\t' read -r container_id container_name server_id expiring_date user_name ubuntu_username; do
    [ -z "${container_id}" ] && continue
    domain_count=$((domain_count + 1))
    total_found=$((total_found + 1))
    echo "  ${domain_count}. ${container_name} | user=${ubuntu_username} (${user_name}) | server=${server_id} | expired=${expiring_date}"

    if [ "${apply_changes}" = "true" ]; then
      echo "     -> deleting via script/delete_container.sh"
      bash "${DELETE_SCRIPT}" \
        --container-id "${container_id}" \
        --server-id "${server_id}" \
        --skip-post-actions
      total_deleted=$((total_deleted + 1))
      mark_domain_updated "${domain_name}"
    fi
  done <<<"${expired_rows}"
  echo
done

if [ "${apply_changes}" = "true" ] && [ "${total_deleted}" -gt 0 ]; then
  echo "Running one-time post-actions after batch deletion..."
  for domain_name in "${updated_domains[@]}"; do
    echo "  Creating database backup for ${domain_name}..."
    db_host="$(resolve_db_host_for_domain "$domain_name")" || exit 1
    create_mysql_client_config "$db_host"
    backup_database_locally "${domain_name}" || true
    cleanup_mysql_client_config
  done

  echo "  Refreshing LAB and FARM Excel/Google Sheets exports..."
  update_all_domain_exports
fi

echo "Summary:"
echo "  Expired active containers found: ${total_found}"
if [ "${apply_changes}" = "true" ]; then
  echo "  Deleted: ${total_deleted}"
else
  echo "  Mode: dry-run"
  echo "  Deleted: 0 (run with --apply to delete)"
fi
