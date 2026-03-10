#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_ROOT}/script/common_domain_db.sh"
load_management_config

trap cleanup_mysql_client_config EXIT

name=""
username=""
port_number=""
new_expiration_date=""
domains_csv="${EXPORT_DOMAINS:-${SERVER_DOMAIN:-LAB,FARM}}"
dry_run=true
apply_changes=false
all_matches=false

show_help() {
  cat <<EOF
Usage: $0 [options]

Options:
      --name NAME               User's actual name filter
      --username USERNAME       Ubuntu username filter
      --port PORT               Port number filter
      --expiration-date DATE    New expiration date (YYYY-MM-DD)
      --domains CSV             Domains to search (default: ${domains_csv})
      --dry-run                 Show matched containers and planned changes (default)
      --apply                   Apply the expiration update
      --all-matches             Allow updating all matched containers
  -h, --help                    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --name)
    name="$2"
    shift 2
    ;;
  --username)
    username="$2"
    shift 2
    ;;
  --port)
    port_number="$2"
    shift 2
    ;;
  --expiration-date)
    new_expiration_date="$2"
    shift 2
    ;;
  --domains)
    domains_csv="$2"
    shift 2
    ;;
  --dry-run)
    dry_run=true
    apply_changes=false
    shift
    ;;
  --apply)
    apply_changes=true
    dry_run=false
    shift
    ;;
  --all-matches)
    all_matches=true
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

if [ -z "${name}" ] && [ -z "${username}" ] && [ -z "${port_number}" ]; then
  echo "Error: provide at least one filter: --name, --username, or --port." >&2
  exit 1
fi

if [ -z "${new_expiration_date}" ]; then
  read -p "New expiration date (YYYY-MM-DD): " new_expiration_date
fi

if ! [[ "${new_expiration_date}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "Error: --expiration-date must be in YYYY-MM-DD format." >&2
  exit 1
fi

if [ -n "${port_number}" ] && ! [[ "${port_number}" =~ ^[0-9]+$ ]]; then
  echo "Error: --port must be numeric." >&2
  exit 1
fi

require_mysql_cli || exit 1

if [ "${apply_changes}" = "true" ]; then
  require_mysqldump_cli || exit 1
fi

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

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

name_sql=""
username_sql=""
port_sql=""

if [ -n "${name}" ]; then
  name_sql=" AND u.name = '$(sql_escape "${name}")'"
fi

if [ -n "${username}" ]; then
  username_sql=" AND u.ubuntu_username = '$(sql_escape "${username}")'"
fi

if [ -n "${port_number}" ]; then
  port_sql=" AND EXISTS (
      SELECT 1
      FROM used_ports up_filter
      WHERE up_filter.docker_container_record_id = dc.id
        AND up_filter.port_number = ${port_number}
    )"
fi

matches_file="$(mktemp)"
cleanup_matches_file() {
  rm -f "${matches_file}"
}
trap 'cleanup_mysql_client_config; cleanup_matches_file' EXIT

total_matches=0

if [ "${dry_run}" = "true" ]; then
  echo "[DRY-RUN] Searching matching active containers..."
else
  echo "Searching matching active containers..."
fi
echo "  Filters: name='${name:-*}', username='${username:-*}', port='${port_number:-*}'"
echo "  New expiration date: ${new_expiration_date}"
echo

for domain_name in "${DOMAINS[@]}"; do
  db_host="$(resolve_db_host_for_domain "${domain_name}")" || exit 1
  create_mysql_client_config "${db_host}"

  if ! mysql_exec -e "SELECT 1;" >/dev/null 2>&1; then
    echo "[${domain_name}] Error: failed to connect to ${DB_NAME} on ${db_host}" >&2
    exit 1
  fi

  result_rows="$(mysql_exec --batch --raw -N -e "
    SELECT
      '${domain_name}' AS domain_name,
      dc.id,
      dc.container_name,
      dc.server_id,
      DATE_FORMAT(dc.expiring_at, '%Y-%m-%d'),
      u.name,
      u.ubuntu_username,
      IFNULL(GROUP_CONCAT(up.port_number ORDER BY up.port_number SEPARATOR ', '), '')
    FROM docker_container dc
    JOIN user u ON u.id = dc.user_id
    LEFT JOIN used_ports up ON up.docker_container_record_id = dc.id
    WHERE dc.existing = 1
      ${name_sql}
      ${username_sql}
      ${port_sql}
    GROUP BY dc.id, dc.container_name, dc.server_id, dc.expiring_at, u.name, u.ubuntu_username
    ORDER BY dc.expiring_at ASC, dc.server_id ASC, dc.container_name ASC;
  ")"

  cleanup_mysql_client_config

  if [ -z "${result_rows}" ]; then
    continue
  fi

  while IFS= read -r row; do
    [ -z "${row}" ] && continue
    printf '%s\n' "${row}" >>"${matches_file}"
    total_matches=$((total_matches + 1))
  done <<<"${result_rows}"
done

if [ "${total_matches}" -eq 0 ]; then
  echo "No active containers matched the given filters."
  exit 0
fi

echo "Matched containers:"
match_index=0
invalid_extension_count=0

while IFS=$'\t' read -r domain_name db_container_id container_name server_id current_expiration matched_name matched_username matched_ports; do
  [ -z "${db_container_id}" ] && continue
  match_index=$((match_index + 1))
  echo "  ${match_index}. ${container_name} | user=${matched_username} (${matched_name}) | server=${server_id} | ports=${matched_ports:-none} | current=${current_expiration} | new=${new_expiration_date}"
  if [[ "${new_expiration_date}" < "${current_expiration}" ]] || [[ "${new_expiration_date}" == "${current_expiration}" ]]; then
    invalid_extension_count=$((invalid_extension_count + 1))
  fi
done <"${matches_file}"

echo

if [ "${invalid_extension_count}" -gt 0 ]; then
  echo "Error: new expiration date must be later than the current expiration date for all matched containers." >&2
  exit 1
fi

if [ "${dry_run}" = "true" ]; then
  echo "[DRY-RUN] ${total_matches} container(s) would be updated."
  exit 0
fi

if [ "${total_matches}" -gt 1 ] && [ "${all_matches}" != "true" ]; then
  echo "Error: ${total_matches} containers matched. Re-run with --all-matches to update them all." >&2
  exit 1
fi

updated_domains_file="$(mktemp)"
cleanup_updated_domains_file() {
  rm -f "${updated_domains_file}"
}
trap 'cleanup_mysql_client_config; cleanup_matches_file; cleanup_updated_domains_file' EXIT

updated_count=0

while IFS=$'\t' read -r domain_name db_container_id container_name server_id current_expiration matched_name matched_username matched_ports; do
  [ -z "${db_container_id}" ] && continue
  db_host="$(resolve_db_host_for_domain "${domain_name}")" || exit 1
  create_mysql_client_config "${db_host}"

  update_count="$(mysql_exec -N -e "
    UPDATE docker_container
    SET expiring_at = '${new_expiration_date}'
    WHERE id = ${db_container_id};
    SELECT ROW_COUNT();
  ")"

  cleanup_mysql_client_config

  if [ "${update_count}" != "1" ]; then
    echo "Error: failed to update ${container_name} on ${server_id}." >&2
    exit 1
  fi

  printf '%s\n' "${domain_name}" >>"${updated_domains_file}"
  updated_count=$((updated_count + 1))
  echo "Updated ${container_name} on ${server_id}: ${current_expiration} -> ${new_expiration_date}"
done <"${matches_file}"

if [ "${updated_count}" -gt 0 ]; then
  while IFS= read -r domain_name; do
    [ -z "${domain_name}" ] && continue
    db_host="$(resolve_db_host_for_domain "${domain_name}")" || exit 1
    create_mysql_client_config "${db_host}"
    echo "Creating database backup for ${domain_name}..."
    backup_database_locally "${domain_name}" || true
    cleanup_mysql_client_config
  done < <(sort -u "${updated_domains_file}")

  echo "Updating Google Sheets and Excel export for LAB and FARM..."
  update_all_domain_exports
fi

echo "Done. Updated ${updated_count} container(s)."
