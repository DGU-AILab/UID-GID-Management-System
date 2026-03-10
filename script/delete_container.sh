#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_ROOT}/script/common_domain_db.sh"
load_management_config

trap cleanup_mysql_client_config EXIT

container_id=""
container_name=""
filter_name=""
filter_username=""
filter_port=""
force=false
domain_name=""
server_number=""
server_id_input=""
server_id=""
expected_target_host=""
dry_run=false
skip_post_actions=false

function show_help {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  -h, --help                      Show this help message"
  echo "  -i, --container-id ID           Docker container ID"
  echo "  -n, --container-name NAME       Docker container name"
  echo "      --name NAME                 User's actual name filter"
  echo "      --username USERNAME         Ubuntu username filter"
  echo "      --port PORT                 Port number filter"
  echo "      --domain DOMAIN             Domain name (LAB or FARM)"
  echo "      --server-number NUMBER      Server number (e.g., 1, 10)"
  echo "  -s, --server-id SERVER_ID       Server ID (legacy option, e.g., LAB1, FARM3)"
  echo "  -f, --force                     Force deletion even if database update fails"
  echo "      --dry-run                   Show planned actions without changing remote hosts or DB"
  echo "      --skip-post-actions         Skip backup/export after deletion"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    show_help
    ;;
  -i | --container-id)
    container_id="$2"
    shift 2
    ;;
  -n | --container-name)
    container_name="$2"
    shift 2
    ;;
  --name)
    filter_name="$2"
    shift 2
    ;;
  --username)
    filter_username="$2"
    shift 2
    ;;
  --port)
    filter_port="$2"
    shift 2
    ;;
  --domain)
    domain_name="$2"
    shift 2
    ;;
  --server-number)
    server_number="$2"
    shift 2
    ;;
  -s | --server-id)
    server_id_input="$2"
    shift 2
    ;;
  -f | --force)
    force=true
    shift
    ;;
  --dry-run)
    dry_run=true
    shift
    ;;
  --skip-post-actions)
    skip_post_actions=true
    shift
    ;;
  *)
    echo "Unknown option: $1"
    show_help
    ;;
  esac
done

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

if [ -n "$filter_port" ] && ! [[ "$filter_port" =~ ^[0-9]+$ ]]; then
  echo "Error: --port must be numeric."
  exit 1
fi

if [ -z "$container_id" ] && [ -z "$container_name" ] && [ -z "$filter_name" ] && [ -z "$filter_username" ] && [ -z "$filter_port" ]; then
  echo "Error: provide --container-id, --container-name, or at least one of --name/--username/--port."
  exit 1
fi

if [ -z "$server_id_input" ]; then
  if [ -z "$domain_name" ]; then
    read -p "Domain name (LAB or FARM): " domain_name
  fi
  if [ -z "$server_number" ]; then
    read -p "Server number (e.g., 1, 10): " server_number
  fi
else
  read parsed_domain parsed_number <<<"$(split_server_id "$server_id_input")" || exit 1
  domain_name="$parsed_domain"
  server_number="$parsed_number"
fi

domain_name="$(normalize_domain_name "$domain_name")" || exit 1
server_number="$(validate_server_number "$server_number")" || exit 1
server_id="$(compose_server_id "$domain_name" "$server_number")"
expected_target_host="$(compose_ansible_host_alias "$domain_name" "$server_number")"
db_host="$(resolve_db_host_for_domain "$domain_name")" || exit 1

require_mysql_cli || exit 1
require_ansible_cli || exit 1
require_ansible_inventory || exit 1
ensure_ansible_host_exists "$expected_target_host" || exit 1
create_mysql_client_config "$db_host"

if ! mysql_exec -e "SELECT 1;" >/dev/null 2>&1; then
  echo "Error: Failed to connect to database $DB_NAME on $db_host"
  exit 1
fi

if [ -n "$container_id" ]; then
  db_container=$(mysql_exec -N -e "
    SELECT id, container_id, container_name, server_id
    FROM docker_container
    WHERE container_id LIKE '$container_id%' AND existing = 1;")
elif [ -n "$container_name" ]; then
  db_container=$(mysql_exec -N -e "
    SELECT id, container_id, container_name, server_id
    FROM docker_container
    WHERE container_name = '$container_name' AND existing = 1;")
else
  name_sql=""
  username_sql=""
  port_sql=""

  if [ -n "$filter_name" ]; then
    name_sql=" AND u.name = '$(sql_escape "$filter_name")'"
  fi

  if [ -n "$filter_username" ]; then
    username_sql=" AND u.ubuntu_username = '$(sql_escape "$filter_username")'"
  fi

  if [ -n "$filter_port" ]; then
    port_sql=" AND EXISTS (
      SELECT 1
      FROM used_ports up_filter
      WHERE up_filter.docker_container_record_id = dc.id
        AND up_filter.port_number = ${filter_port}
    )"
  fi

  matched_rows=$(mysql_exec --batch --raw -N -e "
    SELECT
      dc.id,
      dc.container_id,
      dc.container_name,
      dc.server_id,
      u.name,
      u.ubuntu_username,
      IFNULL(GROUP_CONCAT(up.port_number ORDER BY up.port_number SEPARATOR ', '), '')
    FROM docker_container dc
    JOIN user u ON u.id = dc.user_id
    LEFT JOIN used_ports up ON up.docker_container_record_id = dc.id
    WHERE dc.existing = 1
      AND dc.server_id = '$(sql_escape "$server_id")'
      ${name_sql}
      ${username_sql}
      ${port_sql}
    GROUP BY dc.id, dc.container_id, dc.container_name, dc.server_id, u.name, u.ubuntu_username
    ORDER BY dc.container_name ASC;
  ")

  match_count=$(printf '%s\n' "$matched_rows" | awk 'NF{count++} END{print count+0}')

  if [ "$match_count" -eq 0 ]; then
    echo "Container not found in database or already marked as deleted."
    exit 1
  fi

  if [ "$match_count" -gt 1 ]; then
    echo "Error: multiple containers matched the given filters on ${server_id}. Narrow the filters."
    printf '%s\n' "$matched_rows" | while IFS=$'\t' read -r row_id row_container_id row_container_name row_server_id row_name row_username row_ports; do
      [ -z "$row_id" ] && continue
      echo "  - ${row_container_name} (${row_container_id}) | user=${row_username} (${row_name}) | server=${row_server_id} | ports=${row_ports:-none}"
    done
    exit 1
  fi

  db_container=$(printf '%s\n' "$matched_rows" | head -n 1 | awk -F'\t' '{print $1, $2, $3, $4}')
fi

if [ -z "$db_container" ]; then
  echo "Container not found in database or already marked as deleted."
  mysql_exec -e "ROLLBACK;"
  exit 1
fi

read db_container_id actual_container_id actual_container_name actual_server_id <<<$(echo "$db_container" | awk '{print $1, $2, $3, $4}')
actual_domain=$(echo "$actual_server_id" | grep -o '^[A-Za-z]\+' | tr '[:lower:]' '[:upper:]')
actual_server_number=$(echo "$actual_server_id" | grep -o '[0-9]\+$')
actual_target_host="$(compose_ansible_host_alias "$actual_domain" "$actual_server_number")"
ensure_ansible_host_exists "$actual_target_host" || exit 1

echo "Found container in database: $actual_container_name ($actual_container_id) on $actual_server_id"

if [ "$actual_server_id" != "$server_id" ] && [ "$force" != "true" ]; then
  echo "Error: requested server $server_id does not match database record $actual_server_id"
  mysql_exec -e "ROLLBACK;"
  exit 1
fi

if [ "$dry_run" = "true" ]; then
  echo "[DRY-RUN] Planned remote host: ${actual_target_host}"
  echo "[DRY-RUN] Planned database host: ${db_host}"
  echo "[DRY-RUN] Target container: ${actual_container_name} (${actual_container_id})"
  echo "[DRY-RUN] Would delete used_ports rows for docker_container.id=${db_container_id}"
  echo "[DRY-RUN] Would mark docker_container.existing=0 and set deleted_at=NOW()"
  echo "[DRY-RUN] Would remove remote Docker container from ${actual_target_host}"
  if [ "${skip_post_actions}" = "true" ]; then
    echo "[DRY-RUN] Post-actions skipped: no DB backup or export refresh"
  else
    echo "[DRY-RUN] Would create local DB backup for ${domain_name}"
    echo "[DRY-RUN] Would refresh LAB and FARM Excel/Google Sheets exports"
  fi
  exit 0
fi

mysql_exec -e "START TRANSACTION;"

ports_update=$(mysql_exec -N -e "
  DELETE FROM used_ports
  WHERE docker_container_record_id = $db_container_id;
  SELECT ROW_COUNT();")

echo "Deleted $ports_update port records associated with the container."

container_update=$(mysql_exec -N -e "
  UPDATE docker_container
  SET existing = 0, deleted_at = NOW()
  WHERE id = $db_container_id;
  SELECT ROW_COUNT();")

if [ "$container_update" -ne 1 ]; then
  echo "Failed to update container record in database: $container_update"
  if [ "$force" != "true" ]; then
    mysql_exec -e "ROLLBACK;"
    exit 1
  fi
else
  echo "Container marked as deleted in database."
fi

if run_remote_shell "$actual_target_host" "docker rm -f '${actual_container_id}' >/dev/null 2>&1 || docker rm -f '${actual_container_name}' >/dev/null 2>&1" >/dev/null 2>&1; then
  echo "Container successfully removed from ${actual_target_host}."
else
  echo "Container not found on ${actual_target_host} or removal failed."
  if [ "$force" != "true" ]; then
    mysql_exec -e "ROLLBACK;"
    exit 1
  fi
fi

mysql_exec -e "COMMIT;"

echo "Container deletion completed successfully."

if [ "${skip_post_actions}" = "true" ]; then
  echo "Skipping backup and export refresh (--skip-post-actions)."
else
  echo "Creating database backup..."
  backup_database_locally "$domain_name" || true

  echo "Updating Google Sheets and Excel export for LAB and FARM..."
  update_all_domain_exports
fi
