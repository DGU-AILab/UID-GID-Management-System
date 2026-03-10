#!/bin/bash

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_ROOT}/script/common_domain_db.sh"
load_management_config

trap cleanup_mysql_client_config EXIT

RAW_DELETE_SCRIPT="${PROJECT_ROOT}/script/delete_container.sh"
MAIL_SCRIPT="${PROJECT_ROOT}/script/send_container_deleted_email.py"

forward_args=("$@")

container_id=""
container_name=""
filter_name=""
filter_username=""
filter_port=""
domain_name=""
server_number=""
server_id_input=""
dry_run=false

show_help() {
  cat <<EOF_HELP
Usage: $0 [options]

Notification-aware wrapper for script/delete_container.sh.
It sends a deletion email only when the underlying delete script succeeds.

Supported options are the same as script/delete_container.sh.
EOF_HELP
}

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

prefetch_row=""
metadata_reason=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      exec "${RAW_DELETE_SCRIPT}" --help
      ;;
    -i|--container-id)
      container_id="$2"
      shift 2
      ;;
    -n|--container-name)
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
    -s|--server-id)
      server_id_input="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      shift
      ;;
  esac
done

if [ -n "$server_id_input" ]; then
  if read parsed_domain parsed_number <<<"$(split_server_id "$server_id_input")"; then
    domain_name="$parsed_domain"
    server_number="$parsed_number"
  fi
fi

if [ -n "$domain_name" ] && [ -n "$server_number" ]; then
  if domain_name="$(normalize_domain_name "$domain_name")" && server_number="$(validate_server_number "$server_number")"; then
    server_id="$(compose_server_id "$domain_name" "$server_number")"
    if db_host="$(resolve_db_host_for_domain "$domain_name" 2>/dev/null)"; then
      create_mysql_client_config "$db_host"
      if mysql_exec -e "SELECT 1;" >/dev/null 2>&1; then
        if [ -n "$container_id" ]; then
          matched_rows="$(mysql_exec --batch --raw -N -e "
            SELECT
              dc.container_id,
              dc.container_name,
              dc.server_id,
              u.name,
              u.ubuntu_username,
              COALESCE(u.email, ''),
              IFNULL(GROUP_CONCAT(up.port_number ORDER BY up.port_number SEPARATOR ', '), ''),
              DATE_FORMAT(dc.expiring_at, '%Y-%m-%d')
            FROM docker_container dc
            JOIN user u ON u.id = dc.user_id
            LEFT JOIN used_ports up ON up.docker_container_record_id = dc.id
            WHERE dc.existing = 1
              AND dc.server_id = '$(sql_escape "$server_id")'
              AND dc.container_id LIKE '$(sql_escape "$container_id")%'
            GROUP BY dc.id, dc.container_id, dc.container_name, dc.server_id, u.name, u.ubuntu_username, u.email, dc.expiring_at
            ORDER BY dc.container_name ASC;
          ")"
        elif [ -n "$container_name" ]; then
          matched_rows="$(mysql_exec --batch --raw -N -e "
            SELECT
              dc.container_id,
              dc.container_name,
              dc.server_id,
              u.name,
              u.ubuntu_username,
              COALESCE(u.email, ''),
              IFNULL(GROUP_CONCAT(up.port_number ORDER BY up.port_number SEPARATOR ', '), ''),
              DATE_FORMAT(dc.expiring_at, '%Y-%m-%d')
            FROM docker_container dc
            JOIN user u ON u.id = dc.user_id
            LEFT JOIN used_ports up ON up.docker_container_record_id = dc.id
            WHERE dc.existing = 1
              AND dc.server_id = '$(sql_escape "$server_id")'
              AND dc.container_name = '$(sql_escape "$container_name")'
            GROUP BY dc.id, dc.container_id, dc.container_name, dc.server_id, u.name, u.ubuntu_username, u.email, dc.expiring_at
            ORDER BY dc.container_name ASC;
          ")"
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
          if [ -n "$filter_port" ] && [[ "$filter_port" =~ ^[0-9]+$ ]]; then
            port_sql=" AND EXISTS (
              SELECT 1
              FROM used_ports up_filter
              WHERE up_filter.docker_container_record_id = dc.id
                AND up_filter.port_number = ${filter_port}
            )"
          fi
          matched_rows="$(mysql_exec --batch --raw -N -e "
            SELECT
              dc.container_id,
              dc.container_name,
              dc.server_id,
              u.name,
              u.ubuntu_username,
              COALESCE(u.email, ''),
              IFNULL(GROUP_CONCAT(up.port_number ORDER BY up.port_number SEPARATOR ', '), ''),
              DATE_FORMAT(dc.expiring_at, '%Y-%m-%d')
            FROM docker_container dc
            JOIN user u ON u.id = dc.user_id
            LEFT JOIN used_ports up ON up.docker_container_record_id = dc.id
            WHERE dc.existing = 1
              AND dc.server_id = '$(sql_escape "$server_id")'
              ${name_sql}
              ${username_sql}
              ${port_sql}
            GROUP BY dc.id, dc.container_id, dc.container_name, dc.server_id, u.name, u.ubuntu_username, u.email, dc.expiring_at
            ORDER BY dc.container_name ASC;
          ")"
        fi

        match_count=$(printf '%s\n' "$matched_rows" | awk 'NF{count++} END{print count+0}')
        if [ "$match_count" -eq 1 ]; then
          prefetch_row="$matched_rows"
        elif [ "$match_count" -gt 1 ]; then
          metadata_reason="metadata lookup matched multiple active containers"
        else
          metadata_reason="metadata lookup found no matching active container"
        fi
      else
        metadata_reason="metadata lookup could not connect to ${db_host}"
      fi
      cleanup_mysql_client_config
    else
      metadata_reason="could not resolve DB host for ${domain_name}"
    fi
  else
    metadata_reason="invalid server selection"
  fi
else
  metadata_reason="server information was not provided"
fi

delete_output=""
if delete_output="$(bash "${RAW_DELETE_SCRIPT}" "${forward_args[@]}" 2>&1)"; then
  delete_status=0
else
  delete_status=$?
fi
printf '%s\n' "$delete_output"

if [ "$delete_status" -ne 0 ]; then
  exit "$delete_status"
fi

if [ "$dry_run" = "true" ]; then
  exit 0
fi

if ! printf '%s\n' "$delete_output" | grep -Fq "Container deletion completed successfully."; then
  exit 0
fi

if [ -z "$prefetch_row" ]; then
  if [ -n "$metadata_reason" ]; then
    echo "Warning: container was deleted but no notification email was sent (${metadata_reason})." >&2
  else
    echo "Warning: container was deleted but no notification email was sent (metadata unavailable)." >&2
  fi
  exit 0
fi

IFS=$'\t' read -r actual_container_id actual_container_name actual_server_id user_name ubuntu_username recipient_email allocated_ports expiring_date <<<"$prefetch_row"

if [ -z "$recipient_email" ]; then
  echo "Warning: container was deleted but the user has no email address on file; skipping notification." >&2
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Warning: container was deleted but python3 is not available; skipping notification email." >&2
  exit 0
fi

if ! python3 "${MAIL_SCRIPT}" \
  --recipient-email "$recipient_email" \
  --name "$user_name" \
  --username "$ubuntu_username" \
  --server-id "$actual_server_id" \
  --container-name "$actual_container_name" \
  --allocated-ports "$allocated_ports" \
  --expiring-date "$expiring_date"; then
  echo "Warning: container was deleted but failed to send notification email to ${recipient_email}." >&2
fi
