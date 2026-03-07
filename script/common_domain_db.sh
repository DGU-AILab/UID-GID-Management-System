#!/bin/bash

resolve_script_dir() {
  cd "$(dirname "${BASH_SOURCE[1]}")" && pwd
}

resolve_project_root() {
  cd "$(resolve_script_dir)/.." && pwd
}

load_management_config() {
  SCRIPT_DIR="$(resolve_script_dir)"
  PROJECT_ROOT="$(resolve_project_root)"
  CONFIG_DIR="${PROJECT_ROOT}/config"
  OPS_SCRIPT_DIR="${PROJECT_ROOT}/script"

  if [ -f "${CONFIG_DIR}/db_config.local.env" ]; then
    DB_CONFIG_FILE="${CONFIG_DIR}/db_config.local.env"
  else
    echo "Error: db_config.local.env not found"
    echo "Hint: copy config/db_config.example.env to config/db_config.local.env"
    exit 1
  fi

  # shellcheck disable=SC1090
  source "${DB_CONFIG_FILE}"

  DB_PORT=${DB_PORT:-3307}
  DB_NAME=${DB_NAME:-nfs_db}
  DB_CHARSET=${DB_CHARSET:-utf8mb4}
  ANSIBLE_INVENTORY=${ANSIBLE_INVENTORY:-}
  BACKUP_ROOT_DIR=${BACKUP_ROOT_DIR:-"${PROJECT_ROOT}/mysql_backups"}
}

normalize_domain_name() {
  local raw_domain="$1"
  local normalized
  normalized=$(echo "$raw_domain" | tr '[:lower:]' '[:upper:]')

  case "$normalized" in
  LAB | FARM)
    echo "$normalized"
    ;;
  *)
    echo "Error: domain name must be LAB or FARM" >&2
    return 1
    ;;
  esac
}

split_server_id() {
  local raw_server_id="$1"
  local parsed_domain parsed_number

  parsed_domain=$(echo "$raw_server_id" | grep -o '^[A-Za-z]\+')
  parsed_number=$(echo "$raw_server_id" | grep -o '[0-9]\+$')

  if [ -z "$parsed_domain" ] || [ -z "$parsed_number" ]; then
    echo "Error: server id must be in format [DOMAIN][NUMBER] (e.g., LAB1, FARM3)" >&2
    return 1
  fi

  printf '%s %s\n' "$(normalize_domain_name "$parsed_domain")" "$parsed_number"
}

validate_server_number() {
  local raw_number="$1"
  if ! [[ "$raw_number" =~ ^[0-9]+$ ]]; then
    echo "Error: server number must be numeric." >&2
    return 1
  fi
  echo "$raw_number"
}

compose_server_id() {
  local domain_name="$1"
  local server_number="$2"
  echo "${domain_name}${server_number}"
}

compose_ansible_host_alias() {
  local domain_name="$1"
  local server_number="$2"
  local prefix
  prefix=$(echo "$domain_name" | tr '[:upper:]' '[:lower:]')
  echo "${prefix}${server_number}"
}

resolve_db_host_for_domain() {
  local domain_name="$1"
  case "$domain_name" in
  LAB)
    if [ -n "${LAB_DB_HOST:-}" ]; then
      echo "$LAB_DB_HOST"
    elif [ -n "${DB_HOST:-}" ]; then
      echo "$DB_HOST"
    else
      echo "Error: LAB_DB_HOST is not configured." >&2
      return 1
    fi
    ;;
  FARM)
    if [ -n "${FARM_DB_HOST:-}" ]; then
      echo "$FARM_DB_HOST"
    elif [ -n "${DB_HOST:-}" ]; then
      echo "$DB_HOST"
    else
      echo "Error: FARM_DB_HOST is not configured." >&2
      return 1
    fi
    ;;
  *)
    echo "Error: unsupported domain ${domain_name}" >&2
    return 1
    ;;
  esac
}

require_ansible_inventory() {
  if [ -z "$ANSIBLE_INVENTORY" ]; then
    echo "Error: ANSIBLE_INVENTORY is not configured." >&2
    return 1
  fi

  if [ ! -f "$ANSIBLE_INVENTORY" ]; then
    echo "Error: ansible inventory file not found: $ANSIBLE_INVENTORY" >&2
    return 1
  fi
}

ensure_ansible_host_exists() {
  local host_alias="$1"
  local output

  if command -v ansible >/dev/null 2>&1; then
    output=$(ansible "$host_alias" -i "$ANSIBLE_INVENTORY" --list-hosts 2>/dev/null || true)
    if echo "$output" | grep -q "hosts (0):"; then
      echo "Error: target host '$host_alias' is not defined in $ANSIBLE_INVENTORY" >&2
      return 1
    fi
    if echo "$output" | grep -Eq "(^|[[:space:]])${host_alias}([[:space:]]|$)"; then
      return 0
    fi
  fi

  if grep -Eq "^[[:space:]]*${host_alias}([[:space:]]|$)" "$ANSIBLE_INVENTORY"; then
    return 0
  fi

  echo "Error: target host '$host_alias' is not defined in $ANSIBLE_INVENTORY" >&2
  return 1
}

create_mysql_client_config() {
  local db_host="$1"
  MYSQL_CNF_FILE=$(mktemp)
  cat >"$MYSQL_CNF_FILE" <<EOF
[client]
user=$DB_USER
password=$DB_PASSWORD
host=$db_host
port=$DB_PORT
default-character-set=$DB_CHARSET
EOF
  chmod 600 "$MYSQL_CNF_FILE"
}

cleanup_mysql_client_config() {
  if [ -n "${MYSQL_CNF_FILE:-}" ] && [ -f "$MYSQL_CNF_FILE" ]; then
    rm -f "$MYSQL_CNF_FILE"
  fi
}

mysql_exec() {
  mysql --defaults-extra-file="$MYSQL_CNF_FILE" -D "$DB_NAME" "$@"
}

mysqldump_exec() {
  mysqldump --defaults-extra-file="$MYSQL_CNF_FILE" --no-tablespaces "$DB_NAME" "$@"
}

run_remote_shell() {
  local host_alias="$1"
  local remote_command="$2"
  ansible "$host_alias" -i "$ANSIBLE_INVENTORY" -m shell -a "$remote_command"
}

run_remote_shell_capture() {
  local host_alias="$1"
  local remote_command="$2"
  local output

  if ! output=$(ansible "$host_alias" -i "$ANSIBLE_INVENTORY" -m shell -a "$remote_command" 2>&1); then
    echo "$output" >&2
    return 1
  fi

  printf '%s\n' "$output"
}

backup_database_locally() {
  local domain_name="$1"
  local backup_dir temp_file timestamp backup_file

  backup_dir="${BACKUP_ROOT_DIR}/$(echo "$domain_name" | tr '[:upper:]' '[:lower:]')"
  mkdir -p "$backup_dir"

  temp_file=$(mktemp)
  timestamp=$(date +"%Y%m%d_%H%M%S")
  backup_file="${backup_dir}/nfs_db_backup_${timestamp}.sql.gz"

  if mysqldump_exec >"$temp_file"; then
    gzip -c "$temp_file" >"$backup_file"
    rm -f "$temp_file"
    echo "Database backup created successfully: $backup_file"
  else
    rm -f "$temp_file"
    echo "Error: Database backup failed"
    return 1
  fi
}

update_all_domain_exports() {
  if [ -f "${OPS_SCRIPT_DIR}/export_users_to_excel.py" ]; then
    python3 "${OPS_SCRIPT_DIR}/export_users_to_excel.py" --domains LAB,FARM
  else
    echo "Warning: export_users_to_excel.py not found"
  fi
}
