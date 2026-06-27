#!/bin/bash

log_timestamp() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

log_event() {
  local tag="$1"
  shift
  printf '%s [%s] %s\n' "$(log_timestamp)" "$tag" "$*"
}

log_error() {
  log_event "ERROR" "$*"
}

resolve_script_dir() {
  cd "$(dirname "${BASH_SOURCE[1]}")" && pwd
}

resolve_project_root() {
  cd "$(resolve_script_dir)/../.." && pwd
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

load_daily_maintenance_config() {
  local config_file="${PROJECT_ROOT}/config/daily_maintenance.local.env"

  if [ ! -f "${config_file}" ]; then
    return 0
  fi

  set -a
  # shellcheck disable=SC1090
  source "${config_file}"
  set +a
}

redirect_logs_to_file_if_configured() {
  local log_file="${1:-${UID_GID_LOG_FILE:-${DAILY_MAINTENANCE_LOG_FILE:-}}}"
  local log_dir

  if [ -z "${log_file}" ] || [ "${UID_GID_LOG_REDIRECTED:-false}" = "true" ]; then
    return 0
  fi

  log_dir="$(dirname "${log_file}")"

  if ! mkdir -p "${log_dir}" 2>/dev/null; then
    log_error "log_directory_unavailable path=${log_dir}"
    return 1
  fi

  if ! touch "${log_file}" 2>/dev/null; then
    log_error "log_file_unavailable path=${log_file}"
    return 1
  fi

  export UID_GID_LOG_REDIRECTED=true
  export UID_GID_LOG_FILE="${log_file}"
  exec >>"${log_file}" 2>&1
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

require_command() {
  local command_name="$1"
  local install_hint="${2:-}"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    log_error "required_command_missing command=${command_name}"
    if [ -n "$install_hint" ]; then
      log_error "hint=${install_hint}"
    fi
    return 1
  fi
}

require_ansible_cli() {
  require_command "ansible" "install Ansible on the management server and verify ANSIBLE_INVENTORY."
}

require_mysql_cli() {
  require_command "mysql" "install a MySQL client on the management server. Example: sudo apt install mysql-client"
}

require_mysqldump_cli() {
  require_command "mysqldump" "install MySQL client tools on the management server. Example: sudo apt install mysql-client"
}

ensure_ansible_host_exists() {
  local host_alias="$1"
  local output quoted_ssh_common_args

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

shell_quote() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

validate_identity_name() {
  local name="$1"
  local label="${2:-name}"

  if ! [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,63}$ ]]; then
    echo "Error: ${label} must match ^[A-Za-z_][A-Za-z0-9_.-]{0,63}$" >&2
    return 1
  fi
}

ensure_group_membership_schema() {
  mysql_exec -e "
    CREATE TABLE IF NOT EXISTS user_group_membership (
      id INT PRIMARY KEY AUTO_INCREMENT,
      ubuntu_uid INT NOT NULL,
      ubuntu_gid INT NOT NULL,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      UNIQUE KEY unique_user_group_membership (ubuntu_uid, ubuntu_gid),
      FOREIGN KEY (ubuntu_uid) REFERENCES user (ubuntu_uid),
      FOREIGN KEY (ubuntu_gid) REFERENCES \`group\` (ubuntu_gid)
    ) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
  "
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

run_remote_raw_capture() {
  local host="$1"
  local port="$2"
  local user="$3"
  local key="$4"
  local raw_command="$5"
  local ssh_common_args="${6:-}"
  local output
  local ansible_args=()

  ansible_args=(
    "$host"
    -i "${host},"
    -u "$user"
    -e "ansible_port=${port}"
    -m raw
    -a "$raw_command"
  )

  if [ -n "$key" ]; then
    ansible_args+=(--private-key "$key")
  fi

  if [ -n "$ssh_common_args" ]; then
    quoted_ssh_common_args="$(shell_quote "$ssh_common_args")"
    ansible_args+=(-e "ansible_ssh_common_args=${quoted_ssh_common_args}")
  fi

  if ! output=$(ansible "${ansible_args[@]}" 2>&1); then
    echo "$output" >&2
    return 1
  fi

  printf '%s\n' "$output"
}

lab_storage_user_home_dir() {
  local username="$1"
  local share_root="${LAB_STORAGE_USER_SHARE_ROOT:-/294t/dcloud/share/user-share}"
  share_root="${share_root%/}"
  printf '%s/%s\n' "$share_root" "$username"
}

lab_kerberos_storage_user_home_dir() {
  local username="$1"
  local share_root="${LAB_KERBEROS_STORAGE_USER_SHARE_ROOT:-/294t/share/test-krb/user-share}"
  share_root="${share_root%/}"
  printf '%s/%s\n' "$share_root" "$username"
}

lab_host_user_share_root() {
  local server_number="$1"
  local share_root_template="${LAB_HOST_USER_SHARE_ROOT_TEMPLATE:-/home/tako{server_number}/share/user-share}"
  share_root_template="${share_root_template//\{server_number\}/$server_number}"
  share_root_template="${share_root_template%/}"
  printf '%s\n' "$share_root_template"
}

lab_kerberos_mount_user_share_root() {
  local share_root="${LAB_KERBEROS_MOUNT_USER_SHARE_ROOT:-/mnt/decs-lab-test-krb/user-share}"
  share_root="${share_root%/}"
  printf '%s\n' "$share_root"
}

farm_nas_user_home_dir() {
  local username="$1"
  local share_root="${FARM_NAS_USER_SHARE_ROOT:-/volume1/share/user-share}"
  share_root="${share_root%/}"
  printf '%s/%s\n' "$share_root" "$username"
}

farm_kerberos_nas_user_home_dir() {
  local username="$1"
  local share_root="${FARM_KERBEROS_NAS_USER_SHARE_ROOT:-/volume1/test_krb/user-share}"
  share_root="${share_root%/}"
  printf '%s/%s\n' "$share_root" "$username"
}

farm_kerberos_mount_user_share_root() {
  local share_root="${FARM_KERBEROS_MOUNT_USER_SHARE_ROOT:-/mnt/nas-krb-test-v4/user-share}"
  share_root="${share_root%/}"
  printf '%s\n' "$share_root"
}

farm_kerberos_ccache_dir() {
  local uid="$1"
  local ccache_base="${FARM_KERBEROS_CCACHE_BASE:-/run/user}"
  ccache_base="${ccache_base%/}"
  printf '%s/%s\n' "$ccache_base" "$uid"
}

farm_kerberos_ccache_file() {
  local uid="$1"
  printf '%s/krb5cc\n' "$(farm_kerberos_ccache_dir "$uid")"
}

lab_kerberos_ccache_dir() {
  local uid="$1"
  local ccache_base="${LAB_KERBEROS_CCACHE_BASE:-/run/user}"
  ccache_base="${ccache_base%/}"
  printf '%s/%s\n' "$ccache_base" "$uid"
}

lab_kerberos_ccache_file() {
  local uid="$1"
  printf '%s/krb5cc\n' "$(lab_kerberos_ccache_dir "$uid")"
}

farm_kerberos_realm() {
  printf '%s\n' "${FARM_KERBEROS_REALM:-FARM.DECS.INTERNAL}"
}

lab_kerberos_realm() {
  printf '%s\n' "${LAB_KERBEROS_REALM:-LAB.DECS.INTERNAL}"
}

farm_kerberos_ad_dc_hosts() {
  local raw_hosts="${FARM_KERBEROS_AD_DC_HOSTS:-${FARM_KERBEROS_AD_DC_HOST:-farm2}}"
  raw_hosts="${raw_hosts//,/ }"
  # shellcheck disable=SC2086
  printf '%s\n' $raw_hosts
}

farm_kerberos_default_ad_dc_host() {
  farm_kerberos_ad_dc_hosts | head -n 1
}

farm_kerberos_domain_fqdn() {
  farm_kerberos_realm | tr '[:upper:]' '[:lower:]'
}

farm_kerberos_domain_dn() {
  local fqdn part dn=""
  fqdn="$(farm_kerberos_domain_fqdn)"
  IFS='.' read -ra parts <<<"$fqdn"
  for part in "${parts[@]}"; do
    if [ -n "$dn" ]; then
      dn+=","
    fi
    dn+="DC=${part}"
  done
  printf '%s\n' "$dn"
}

farm_kerberos_ad_dc_fqdn() {
  local host_alias="$1"
  local default_host domain
  default_host="$(farm_kerberos_default_ad_dc_host)"
  domain="$(farm_kerberos_domain_fqdn)"
  if [[ "$host_alias" == *.* ]]; then
    printf '%s\n' "$host_alias"
  elif [ "$host_alias" = "$default_host" ] && [ "$host_alias" = "farm2" ]; then
    printf 'dc1.%s\n' "$domain"
  else
    printf '%s.%s\n' "$host_alias" "$domain"
  fi
}

farm_kerberos_is_ad_dc_host() {
  local candidate="$1"
  local host
  while IFS= read -r host; do
    if [ "$host" = "$candidate" ]; then
      return 0
    fi
  done < <(farm_kerberos_ad_dc_hosts)
  return 1
}

farm_kerberos_principal() {
  local username="$1"
  printf '%s@%s\n' "$username" "$(farm_kerberos_realm)"
}

lab_kerberos_principal() {
  local username="$1"
  printf '%s@%s\n' "$username" "$(lab_kerberos_realm)"
}

farm_kerberos_keytab_dir() {
  local keytab_dir="${FARM_KERBEROS_KEYTAB_DIR:-/etc/decs-krb/keytabs}"
  keytab_dir="${keytab_dir%/}"
  printf '%s\n' "$keytab_dir"
}

lab_kerberos_keytab_dir() {
  local keytab_dir="${LAB_KERBEROS_KEYTAB_DIR:-/etc/decs-krb/keytabs}"
  keytab_dir="${keytab_dir%/}"
  printf '%s\n' "$keytab_dir"
}

farm_kerberos_keytab_file() {
  local username="$1"
  printf '%s/%s.keytab\n' "$(farm_kerberos_keytab_dir)" "$username"
}

lab_kerberos_keytab_file() {
  local username="$1"
  printf '%s/%s.keytab\n' "$(lab_kerberos_keytab_dir)" "$username"
}

lab_kerberos_storage_keytab_dir() {
  local keytab_dir="${LAB_KERBEROS_STORAGE_KEYTAB_DIR:-/root/decs-lab-test-krb/keytabs}"
  keytab_dir="${keytab_dir%/}"
  printf '%s\n' "$keytab_dir"
}

lab_kerberos_storage_keytab_file() {
  local username="$1"
  printf '%s/%s.keytab\n' "$(lab_kerberos_storage_keytab_dir)" "$username"
}

farm_kerberos_refresh_env_dir() {
  local env_dir="${FARM_KERBEROS_REFRESH_ENV_DIR:-/etc/decs-krb/refresh.d}"
  env_dir="${env_dir%/}"
  printf '%s\n' "$env_dir"
}

lab_kerberos_refresh_env_dir() {
  local env_dir="${LAB_KERBEROS_REFRESH_ENV_DIR:-/etc/decs-krb/refresh.d}"
  env_dir="${env_dir%/}"
  printf '%s\n' "$env_dir"
}

farm_kerberos_refresh_env_file() {
  local username="$1"
  printf '%s/%s.env\n' "$(farm_kerberos_refresh_env_dir)" "$username"
}

lab_kerberos_refresh_env_file() {
  local username="$1"
  printf '%s/%s.env\n' "$(lab_kerberos_refresh_env_dir)" "$username"
}

build_remote_storage_prepare_home_command() {
  local home_dir="$1"
  local uid="$2"
  local gid="$3"
  local sudo_prefix="${4-sudo -n}"
  local quoted_home quoted_owner

  quoted_home="$(shell_quote "$home_dir")"
  quoted_owner="$(shell_quote "${uid}:${gid}")"

  cat <<EOF
set -eu
${sudo_prefix} mkdir -p ${quoted_home}
${sudo_prefix} chown ${quoted_owner} ${quoted_home}
${sudo_prefix} chmod 750 ${quoted_home}
EOF
}

build_lab_storage_prepare_home_command() {
  local home_dir="$1"
  local uid="$2"
  local gid="$3"
  build_remote_storage_prepare_home_command "$home_dir" "$uid" "$gid" "${LAB_STORAGE_SUDO-sudo -n}"
}

build_farm_nas_prepare_home_command() {
  local home_dir="$1"
  local uid="$2"
  local gid="$3"
  build_remote_storage_prepare_home_command "$home_dir" "$uid" "$gid" "${FARM_NAS_SUDO-sudo -n}"
}

build_lab_kerberos_storage_keytab_command() {
  local username="$1"
  local principal="$2"
  local storage_keytab_file="$3"
  local rotate_keytab="$4"
  local uid="$5"
  local gid="$6"
  local sudo_prefix="${LAB_STORAGE_SUDO-sudo -n}"
  local home_dir keytab_dir

  home_dir="$(lab_kerberos_storage_user_home_dir "$username")"
  keytab_dir="$(dirname "$storage_keytab_file")"

  cat <<EOF
set -eu
username=$(shell_quote "$username")
principal=$(shell_quote "$principal")
keytab_file=$(shell_quote "$storage_keytab_file")
keytab_dir=$(shell_quote "$keytab_dir")
home_dir=$(shell_quote "$home_dir")
rotate_keytab=$(shell_quote "$rotate_keytab")
uid=$(shell_quote "$uid")
gid=$(shell_quote "$gid")

if getent group "\$gid" >/dev/null 2>&1; then
  :
elif getent group "\$username" >/dev/null 2>&1; then
  current_gid="\$(getent group "\$username" | awk -F: 'NR==1 { print \$3 }')"
  if [ "\$current_gid" != "\$gid" ]; then
    echo "Storage group \$username exists with GID \$current_gid, expected \$gid" >&2
    exit 1
  fi
else
  ${sudo_prefix} groupadd -g "\$gid" "\$username"
fi

if getent passwd "\$uid" >/dev/null 2>&1; then
  current_user="\$(getent passwd "\$uid" | awk -F: 'NR==1 { print \$1 }')"
  if [ "\$current_user" != "\$username" ]; then
    echo "Storage UID \$uid already belongs to \$current_user, expected \$username" >&2
    exit 1
  fi
elif getent passwd "\$username" >/dev/null 2>&1; then
  current_uid="\$(getent passwd "\$username" | awk -F: 'NR==1 { print \$3 }')"
  if [ "\$current_uid" != "\$uid" ]; then
    echo "Storage user \$username exists with UID \$current_uid, expected \$uid" >&2
    exit 1
  fi
else
  ${sudo_prefix} useradd -u "\$uid" -g "\$gid" -M -N -s /sbin/nologin "\$username"
fi

${sudo_prefix} mkdir -p "\$home_dir"
${sudo_prefix} chown "\$uid:\$gid" "\$home_dir"
${sudo_prefix} chmod 750 "\$home_dir"

${sudo_prefix} install -d -o root -g root -m 0700 "\$keytab_dir"
if ! ${sudo_prefix} kadmin.local -q "getprinc \$principal" 2>/dev/null | grep -q '^Principal:'; then
  ${sudo_prefix} kadmin.local -q "addprinc -randkey \$principal" >/dev/null
elif [ "\$rotate_keytab" = "true" ]; then
  ${sudo_prefix} kadmin.local -q "cpw -randkey \$principal" >/dev/null
fi

keytab_needs_refresh=false
if [ ! -f "\$keytab_file" ] || [ "\$rotate_keytab" = "true" ]; then
  keytab_needs_refresh=true
elif ! ${sudo_prefix} klist -kte "\$keytab_file" >/dev/null 2>&1; then
  keytab_needs_refresh=true
fi

if [ "\$keytab_needs_refresh" = "true" ]; then
  tmp_keytab="\$(mktemp)"
  rm -f "\$tmp_keytab"
  ${sudo_prefix} kadmin.local -q "ktadd -k \$tmp_keytab \$principal" >/dev/null
  ${sudo_prefix} chown root:root "\$tmp_keytab"
  ${sudo_prefix} chmod 0400 "\$tmp_keytab"
  ${sudo_prefix} mv "\$tmp_keytab" "\$keytab_file"
fi

${sudo_prefix} chown root:root "\$keytab_file"
${sudo_prefix} chmod 0400 "\$keytab_file"
${sudo_prefix} klist -kte "\$keytab_file" >/dev/null
echo "__DECS_KEYTAB_B64_BEGIN__"
${sudo_prefix} base64 -w0 "\$keytab_file"
echo
echo "__DECS_KEYTAB_B64_END__"
EOF
}

build_remote_keytab_install_command() {
  local keytab_file="$1"
  local keytab_b64="$2"
  local sudo_prefix="${KERBEROS_REMOTE_SUDO:-sudo -n}"
  local keytab_dir

  keytab_dir="$(dirname "$keytab_file")"

  cat <<EOF
set -eu
keytab_file=$(shell_quote "$keytab_file")
keytab_dir=$(shell_quote "$keytab_dir")
${sudo_prefix} install -d -o root -g root -m 0700 "\$keytab_dir"
tmp_keytab="\$(mktemp)"
base64 -d > "\$tmp_keytab" <<'DECS_KEYTAB_B64'
${keytab_b64}
DECS_KEYTAB_B64
${sudo_prefix} chown root:root "\$tmp_keytab"
${sudo_prefix} chmod 0400 "\$tmp_keytab"
${sudo_prefix} mv "\$tmp_keytab" "\$keytab_file"
${sudo_prefix} klist -kte "\$keytab_file" >/dev/null
EOF
}

build_kerberos_local_host_identity_command() {
  local username="$1"
  local uid="$2"
  local groupname="$3"
  local gid="$4"
  local sudo_prefix="${KERBEROS_REMOTE_SUDO:-sudo -n}"

  cat <<EOF
set -eu
username=$(shell_quote "$username")
uid=$(shell_quote "$uid")
groupname=$(shell_quote "$groupname")
gid=$(shell_quote "$gid")

if getent group "\$gid" >/dev/null 2>&1; then
  :
elif getent group "\$groupname" >/dev/null 2>&1; then
  current_gid="\$(getent group "\$groupname" | awk -F: 'NR==1 { print \$3 }')"
  if [ "\$current_gid" != "\$gid" ]; then
    echo "Host group \$groupname exists with GID \$current_gid, expected \$gid" >&2
    exit 1
  fi
else
  ${sudo_prefix} groupadd -g "\$gid" "\$groupname"
fi

if getent passwd "\$uid" >/dev/null 2>&1; then
  current_user="\$(getent passwd "\$uid" | awk -F: 'NR==1 { print \$1 }')"
  if [ "\$current_user" != "\$username" ]; then
    echo "Host UID \$uid already belongs to \$current_user, expected \$username" >&2
    exit 1
  fi
  ${sudo_prefix} usermod -g "\$gid" "\$username" >/dev/null 2>&1 || true
elif getent passwd "\$username" >/dev/null 2>&1; then
  current_uid="\$(getent passwd "\$username" | awk -F: 'NR==1 { print \$3 }')"
  if [ "\$current_uid" != "\$uid" ]; then
    echo "Host user \$username exists with UID \$current_uid, expected \$uid" >&2
    exit 1
  fi
  ${sudo_prefix} usermod -g "\$gid" "\$username" >/dev/null 2>&1 || true
else
  ${sudo_prefix} useradd -u "\$uid" -g "\$gid" -M -N -s /usr/sbin/nologin "\$username"
fi

if command -v nfsidmap >/dev/null 2>&1; then
  ${sudo_prefix} nfsidmap -c >/dev/null 2>&1 || true
fi

echo "kerberos_local_host_identity_ready user=\$username uid=\$uid group=\$groupname gid=\$gid"
EOF
}

build_farm_kerberos_keytab_command() {
  local username="$1"
  local principal="$2"
  local keytab_file="$3"
  local rotate_keytab="$4"
  local uid="$5"
  local gid="$6"
  local groupname="${7:-$username}"
  local sudo_prefix="${KERBEROS_REMOTE_SUDO:-sudo -n}"
  local nis_domain="${FARM_KERBEROS_NIS_DOMAIN:-farm}"
  local keytab_dir quoted_username quoted_principal quoted_keytab quoted_keytab_dir quoted_rotate quoted_home quoted_nis_domain quoted_groupname

  keytab_dir="$(dirname "$keytab_file")"
  quoted_username="$(shell_quote "$username")"
  quoted_groupname="$(shell_quote "$groupname")"
  quoted_principal="$(shell_quote "$principal")"
  quoted_keytab="$(shell_quote "$keytab_file")"
  quoted_keytab_dir="$(shell_quote "$keytab_dir")"
  quoted_rotate="$(shell_quote "$rotate_keytab")"
  quoted_home="$(shell_quote "/home/$username")"
  quoted_nis_domain="$(shell_quote "$nis_domain")"

  cat <<EOF
set -eu
username=${quoted_username}
groupname=${quoted_groupname}
principal=${quoted_principal}
keytab_file=${quoted_keytab}
keytab_dir=${quoted_keytab_dir}
rotate_keytab=${quoted_rotate}
uid=${uid}
gid=${gid}
nis_domain=${quoted_nis_domain}

${sudo_prefix} install -d -o root -g root -m 0700 "\$keytab_dir"

if [ "\$groupname" != "\$username" ]; then
  if ! ${sudo_prefix} samba-tool group show "\$groupname" >/dev/null 2>&1; then
    ${sudo_prefix} samba-tool group add "\$groupname" >/dev/null
  fi

  ${sudo_prefix} env DECS_KRB_GROUPNAME="\$groupname" DECS_KRB_GROUP_GID="\$gid" DECS_KRB_NIS_DOMAIN="\$nis_domain" python3 - <<'PY'
import os

from samba.auth import system_session
from samba.param import LoadParm
from samba.samdb import SamDB
from ldb import FLAG_MOD_REPLACE, Message, MessageElement

groupname = os.environ["DECS_KRB_GROUPNAME"]
gid = os.environ["DECS_KRB_GROUP_GID"]
nis_domain = os.environ["DECS_KRB_NIS_DOMAIN"]

lp = LoadParm()
lp.load_default()
samdb = SamDB(url="/var/lib/samba/private/sam.ldb", session_info=system_session(), lp=lp)
result = samdb.search(expression=f"(&(sAMAccountName={groupname})(objectClass=group))", attrs=["distinguishedName"])
if not result:
    raise SystemExit(f"AD group not found: {groupname}")

message = Message(result[0].dn)
message["gidNumber"] = MessageElement(gid, FLAG_MOD_REPLACE, "gidNumber")
message["msSFU30NisDomain"] = MessageElement(nis_domain, FLAG_MOD_REPLACE, "msSFU30NisDomain")
message["msSFU30Name"] = MessageElement(groupname, FLAG_MOD_REPLACE, "msSFU30Name")
samdb.modify(message)
PY
fi

if ! ${sudo_prefix} samba-tool user show "\$username" >/dev/null 2>&1; then
  new_password="Krb\$(date +%y%m%d)!\$(tr -dc A-Za-z0-9 </dev/urandom | head -c 24)"
  ${sudo_prefix} samba-tool user create "\$username" "\$new_password" >/dev/null
  ${sudo_prefix} samba-tool user setexpiry "\$username" --noexpiry >/dev/null 2>&1 || true
elif [ "\$rotate_keytab" = "true" ]; then
  new_password="Krb\$(date +%y%m%d)!\$(tr -dc A-Za-z0-9 </dev/urandom | head -c 24)"
  ${sudo_prefix} samba-tool user setpassword "\$username" --newpassword="\$new_password" >/dev/null
fi

if ! ${sudo_prefix} samba-tool user show "\$username" | grep -q '^uidNumber:'; then
  ${sudo_prefix} samba-tool user addunixattrs "\$username" "\$uid" --gid-number="\$gid" --unix-home=${quoted_home} --login-shell=/bin/bash --uid="\$username" >/dev/null
fi

${sudo_prefix} env DECS_KRB_USERNAME="\$username" DECS_KRB_UID="\$uid" DECS_KRB_GID="\$gid" DECS_KRB_NIS_DOMAIN="\$nis_domain" python3 - <<'PY'
import os

from samba.auth import system_session
from samba.param import LoadParm
from samba.samdb import SamDB
from ldb import FLAG_MOD_REPLACE, Message, MessageElement

username = os.environ["DECS_KRB_USERNAME"]
uid = os.environ["DECS_KRB_UID"]
gid = os.environ["DECS_KRB_GID"]
nis_domain = os.environ["DECS_KRB_NIS_DOMAIN"]
home = f"/home/{username}"

lp = LoadParm()
lp.load_default()
samdb = SamDB(url="/var/lib/samba/private/sam.ldb", session_info=system_session(), lp=lp)
result = samdb.search(expression=f"(sAMAccountName={username})", attrs=["distinguishedName"])
if not result:
    raise SystemExit(f"AD user not found: {username}")

message = Message(result[0].dn)
message["uidNumber"] = MessageElement(uid, FLAG_MOD_REPLACE, "uidNumber")
message["gidNumber"] = MessageElement(gid, FLAG_MOD_REPLACE, "gidNumber")
message["unixHomeDirectory"] = MessageElement(home, FLAG_MOD_REPLACE, "unixHomeDirectory")
message["loginShell"] = MessageElement("/bin/bash", FLAG_MOD_REPLACE, "loginShell")
message["msSFU30NisDomain"] = MessageElement(nis_domain, FLAG_MOD_REPLACE, "msSFU30NisDomain")
message["msSFU30Name"] = MessageElement(username, FLAG_MOD_REPLACE, "msSFU30Name")
samdb.modify(message)
PY

if [ "\$groupname" != "\$username" ]; then
  ${sudo_prefix} samba-tool group addmembers "\$groupname" "\$username" >/dev/null 2>&1 || {
    ${sudo_prefix} samba-tool group listmembers "\$groupname" | grep -Fx "\$username" >/dev/null
  }
fi

tmp_keytab="\$(mktemp)"
${sudo_prefix} samba-tool domain exportkeytab "\$tmp_keytab" --principal="\$principal" >/dev/null
${sudo_prefix} chown root:root "\$tmp_keytab"
${sudo_prefix} chmod 0400 "\$tmp_keytab"
${sudo_prefix} mv "\$tmp_keytab" "\$keytab_file"
${sudo_prefix} chown root:root "\$keytab_file"
${sudo_prefix} chmod 0400 "\$keytab_file"
${sudo_prefix} klist -kte "\$keytab_file" >/dev/null
EOF
}

build_farm_kerberos_ensure_group_command() {
  local groupname="$1"
  local gid="$2"
  local sudo_prefix="${KERBEROS_REMOTE_SUDO:-sudo -n}"
  local nis_domain="${FARM_KERBEROS_NIS_DOMAIN:-farm}"

  cat <<EOF
set -eu
groupname=$(shell_quote "$groupname")
gid=$(shell_quote "$gid")
nis_domain=$(shell_quote "$nis_domain")

if ! ${sudo_prefix} samba-tool group show "\$groupname" >/dev/null 2>&1; then
  ${sudo_prefix} samba-tool group add "\$groupname" >/dev/null
fi

${sudo_prefix} env DECS_KRB_GROUPNAME="\$groupname" DECS_KRB_GROUP_GID="\$gid" DECS_KRB_NIS_DOMAIN="\$nis_domain" python3 - <<'PY'
import os

from samba.auth import system_session
from samba.param import LoadParm
from samba.samdb import SamDB
from ldb import FLAG_MOD_REPLACE, Message, MessageElement

groupname = os.environ["DECS_KRB_GROUPNAME"]
gid = os.environ["DECS_KRB_GROUP_GID"]
nis_domain = os.environ["DECS_KRB_NIS_DOMAIN"]

lp = LoadParm()
lp.load_default()
samdb = SamDB(url="/var/lib/samba/private/sam.ldb", session_info=system_session(), lp=lp)
result = samdb.search(expression=f"(&(sAMAccountName={groupname})(objectClass=group))", attrs=["distinguishedName"])
if not result:
    raise SystemExit(f"AD group not found: {groupname}")

message = Message(result[0].dn)
message["gidNumber"] = MessageElement(gid, FLAG_MOD_REPLACE, "gidNumber")
message["msSFU30NisDomain"] = MessageElement(nis_domain, FLAG_MOD_REPLACE, "msSFU30NisDomain")
message["msSFU30Name"] = MessageElement(groupname, FLAG_MOD_REPLACE, "msSFU30Name")
samdb.modify(message)
PY

${sudo_prefix} samba-tool group show "\$groupname"
EOF
}

build_farm_kerberos_add_group_member_command() {
  local groupname="$1"
  local username="$2"
  local sudo_prefix="${KERBEROS_REMOTE_SUDO:-sudo -n}"

  cat <<EOF
set -eu
groupname=$(shell_quote "$groupname")
username=$(shell_quote "$username")
${sudo_prefix} samba-tool user show "\$username" >/dev/null
${sudo_prefix} samba-tool group show "\$groupname" >/dev/null
${sudo_prefix} samba-tool group addmembers "\$groupname" "\$username" >/dev/null 2>&1 || {
  ${sudo_prefix} samba-tool group listmembers "\$groupname" | grep -Fx "\$username" >/dev/null
}
${sudo_prefix} samba-tool group listmembers "\$groupname"
EOF
}

build_farm_kerberos_remove_group_member_command() {
  local groupname="$1"
  local username="$2"
  local sudo_prefix="${KERBEROS_REMOTE_SUDO:-sudo -n}"

  cat <<EOF
set -eu
groupname=$(shell_quote "$groupname")
username=$(shell_quote "$username")
${sudo_prefix} samba-tool group show "\$groupname" >/dev/null
if ${sudo_prefix} samba-tool group listmembers "\$groupname" | grep -Fx "\$username" >/dev/null; then
  ${sudo_prefix} samba-tool group removemembers "\$groupname" "\$username" >/dev/null
fi
${sudo_prefix} samba-tool group listmembers "\$groupname"
EOF
}

build_farm_kerberos_delete_group_command() {
  local groupname="$1"
  local sudo_prefix="${KERBEROS_REMOTE_SUDO:-sudo -n}"

  cat <<EOF
set -eu
groupname=$(shell_quote "$groupname")
if ${sudo_prefix} samba-tool group show "\$groupname" >/dev/null 2>&1; then
  ${sudo_prefix} samba-tool group delete "\$groupname" >/dev/null
fi
echo "kerberos_ad_group_deleted=\$groupname"
EOF
}

build_farm_kerberos_show_group_command() {
  local groupname="$1"
  local sudo_prefix="${KERBEROS_REMOTE_SUDO:-sudo -n}"

  cat <<EOF
set -eu
groupname=$(shell_quote "$groupname")
${sudo_prefix} samba-tool group show "\$groupname"
echo "members:"
${sudo_prefix} samba-tool group listmembers "\$groupname" || true
EOF
}

ensure_farm_kerberos_ad_group() {
  local host_alias="$1"
  local groupname="$2"
  local gid="$3"
  local raw_command

  raw_command="$(build_farm_kerberos_ensure_group_command "$groupname" "$gid")"
  run_remote_shell "$host_alias" "$raw_command"
}

add_farm_kerberos_group_member() {
  local host_alias="$1"
  local groupname="$2"
  local username="$3"
  local raw_command

  raw_command="$(build_farm_kerberos_add_group_member_command "$groupname" "$username")"
  run_remote_shell "$host_alias" "$raw_command"
}

remove_farm_kerberos_group_member() {
  local host_alias="$1"
  local groupname="$2"
  local username="$3"
  local raw_command

  raw_command="$(build_farm_kerberos_remove_group_member_command "$groupname" "$username")"
  run_remote_shell "$host_alias" "$raw_command"
}

delete_farm_kerberos_ad_group() {
  local host_alias="$1"
  local groupname="$2"
  local raw_command

  raw_command="$(build_farm_kerberos_delete_group_command "$groupname")"
  run_remote_shell "$host_alias" "$raw_command"
}

show_farm_kerberos_ad_group() {
  local host_alias="$1"
  local groupname="$2"
  local raw_command

  raw_command="$(build_farm_kerberos_show_group_command "$groupname")"
  run_remote_shell "$host_alias" "$raw_command"
}

build_kerberos_host_refresh_command() {
  local username="$1"
  local uid="$2"
  local gid="$3"
  local principal="$4"
  local keytab_file="$5"
  local ccache_dir="$6"
  local ccache_file="$7"
  local refresh_env_file="$8"
  local sudo_prefix="${KERBEROS_REMOTE_SUDO:-sudo -n}"
  local refresh_env_dir refresh_interval
  local quoted_refresh_env_dir quoted_ccache_dir quoted_refresh_env_file

  refresh_env_dir="$(dirname "$refresh_env_file")"
  refresh_interval="${FARM_KERBEROS_REFRESH_INTERVAL:-1h}"
  quoted_refresh_env_dir="$(shell_quote "$refresh_env_dir")"
  quoted_ccache_dir="$(shell_quote "$ccache_dir")"
  quoted_refresh_env_file="$(shell_quote "$refresh_env_file")"

  cat <<EOF
set -eu
username=$(shell_quote "$username")
uid=$(shell_quote "$uid")
gid=$(shell_quote "$gid")
principal=$(shell_quote "$principal")
keytab_file=$(shell_quote "$keytab_file")
ccache_dir=$(shell_quote "$ccache_dir")
ccache_file=$(shell_quote "$ccache_file")
refresh_env_file=$(shell_quote "$refresh_env_file")

${sudo_prefix} install -d -o root -g root -m 0755 /etc/decs-krb
${sudo_prefix} install -d -o root -g root -m 0700 ${quoted_refresh_env_dir}
${sudo_prefix} install -d -o "\$uid" -g "\$gid" -m 0700 ${quoted_ccache_dir}

${sudo_prefix} tee /usr/local/sbin/decs-krb-refresh >/dev/null <<'DECS_KRB_REFRESH_SCRIPT'
#!/bin/bash
set -euo pipefail

env_file="\${1:?refresh env file is required}"
if [[ ! -f "\$env_file" ]]; then
  echo "Missing Kerberos refresh env file: \$env_file" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "\$env_file"

: "\${DECS_KRB_PRINCIPAL:?}"
: "\${DECS_KRB_KEYTAB:?}"
: "\${DECS_KRB_CCACHE:?}"
: "\${DECS_KRB_CCACHE_DIR:?}"
: "\${DECS_KRB_UID:?}"
: "\${DECS_KRB_GID:?}"

ccache_path="\$DECS_KRB_CCACHE"
if [[ "\$ccache_path" == FILE:* ]]; then
  ccache_path="\${ccache_path#FILE:}"
fi

install -d -o "\$DECS_KRB_UID" -g "\$DECS_KRB_GID" -m 0700 "\$DECS_KRB_CCACHE_DIR"

if klist -s -c "\$DECS_KRB_CCACHE" 2>/dev/null; then
  if kinit -R -c "\$DECS_KRB_CCACHE" >/dev/null 2>&1; then
    chown "\$DECS_KRB_UID:\$DECS_KRB_GID" "\$ccache_path"
    chmod 0600 "\$ccache_path"
    exit 0
  fi
fi

kinit -k -t "\$DECS_KRB_KEYTAB" -c "\$DECS_KRB_CCACHE" "\$DECS_KRB_PRINCIPAL"
chown "\$DECS_KRB_UID:\$DECS_KRB_GID" "\$ccache_path"
chmod 0600 "\$ccache_path"
DECS_KRB_REFRESH_SCRIPT
${sudo_prefix} chmod 0755 /usr/local/sbin/decs-krb-refresh

${sudo_prefix} tee ${quoted_refresh_env_file} >/dev/null <<DECS_KRB_REFRESH_ENV
DECS_KRB_PRINCIPAL=$(shell_quote "$principal")
DECS_KRB_KEYTAB=$(shell_quote "$keytab_file")
DECS_KRB_CCACHE=$(shell_quote "FILE:$ccache_file")
DECS_KRB_CCACHE_DIR=$(shell_quote "$ccache_dir")
DECS_KRB_UID=$(shell_quote "$uid")
DECS_KRB_GID=$(shell_quote "$gid")
DECS_KRB_REFRESH_ENV
${sudo_prefix} chown root:root ${quoted_refresh_env_file}
${sudo_prefix} chmod 0600 ${quoted_refresh_env_file}

${sudo_prefix} tee /etc/systemd/system/decs-krb-refresh@.service >/dev/null <<'DECS_KRB_REFRESH_SERVICE'
[Unit]
Description=Refresh DECS Kerberos credential cache for %i
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
DECS_KRB_REFRESH_SERVICE
${sudo_prefix} tee -a /etc/systemd/system/decs-krb-refresh@.service >/dev/null <<DECS_KRB_REFRESH_SERVICE_PATH
ExecStart=/usr/local/sbin/decs-krb-refresh ${refresh_env_dir}/%i.env
DECS_KRB_REFRESH_SERVICE_PATH

${sudo_prefix} tee /etc/systemd/system/decs-krb-refresh@.timer >/dev/null <<DECS_KRB_REFRESH_TIMER
[Unit]
Description=Refresh DECS Kerberos credential cache for %i

[Timer]
OnBootSec=2min
OnUnitActiveSec=${refresh_interval}
AccuracySec=5min
Persistent=true

[Install]
WantedBy=timers.target
DECS_KRB_REFRESH_TIMER

instance="\$username"
${sudo_prefix} systemctl daemon-reload
${sudo_prefix} systemctl enable --now "decs-krb-refresh@\${instance}.timer" >/dev/null
${sudo_prefix} systemctl start "decs-krb-refresh@\${instance}.service"
EOF
}

build_farm_nas_lookup_ad_identity_command() {
  local username="$1"
  local netbios_domain="${FARM_KERBEROS_AD_NETBIOS:-FARM}"
  local quoted_identity

  quoted_identity="$(shell_quote "${netbios_domain}\\${username}")"

  cat <<EOF
set -eu
wbinfo_bin=/usr/local/packages/@appstore/SMBService/usr/bin/wbinfo
entry="\$("\$wbinfo_bin" -i ${quoted_identity})"
printf '%s\n' "\$entry" | awk -F: '{ print \$3 " " \$4 }'
EOF
}

build_farm_nas_lookup_ad_group_gid_command() {
  local groupname="$1"
  local netbios_domain="${FARM_KERBEROS_AD_NETBIOS:-FARM}"
  local quoted_identity

  quoted_identity="$(shell_quote "${netbios_domain}\\${groupname}")"

  cat <<EOF
set -eu
wbinfo_bin=/usr/local/packages/@appstore/SMBService/usr/bin/wbinfo
if entry="\$("\$wbinfo_bin" --group-info ${quoted_identity} 2>/dev/null)"; then
  printf '%s\n' "\$entry" | awk -F: '{ print \$3 }'
  exit 0
fi
sid_line="\$("\$wbinfo_bin" --name-to-sid ${quoted_identity})"
sid="\$(printf '%s\n' "\$sid_line" | awk '{ print \$1 }')"
"\$wbinfo_bin" --sid-to-gid "\$sid"
EOF
}

build_farm_kerberos_prepare_home_command() {
  local home_dir="$1"
  local nas_uid="$2"
  local nas_gid="$3"
  local sudo_prefix="${FARM_NAS_SUDO-sudo -n}"
  local quoted_home quoted_owner

  quoted_home="$(shell_quote "$home_dir")"
  quoted_owner="$(shell_quote "${nas_uid}:${nas_gid}")"

  cat <<EOF
set -eu
${sudo_prefix} mkdir -p ${quoted_home}
${sudo_prefix} chown ${quoted_owner} ${quoted_home}
${sudo_prefix} chmod 750 ${quoted_home}
EOF
}

build_kerberos_ccache_dir_command() {
  local ccache_dir="$1"
  local uid="$2"
  local gid="$3"
  local sudo_prefix="${KERBEROS_REMOTE_SUDO:-sudo -n}"
  local quoted_dir quoted_owner

  quoted_dir="$(shell_quote "$ccache_dir")"
  quoted_owner="$(shell_quote "${uid}:${gid}")"

  cat <<EOF
set -eu
${sudo_prefix} install -d -o ${uid} -g ${gid} -m 0700 ${quoted_dir}
${sudo_prefix} chown ${quoted_owner} ${quoted_dir}
${sudo_prefix} chmod 700 ${quoted_dir}
EOF
}

build_kerberos_host_nfs_identity_command() {
  local username="$1"
  local uid="$2"
  local groupname="$3"
  local gid="$4"
  local sudo_prefix="${KERBEROS_REMOTE_SUDO:-sudo -n}"
  local netbios_domain="${FARM_KERBEROS_AD_NETBIOS:-FARM}"
  local host_group

  host_group="${netbios_domain}\\${groupname}"

  cat <<EOF
set -eu
username=$(shell_quote "$username")
uid=$(shell_quote "$uid")
groupname=$(shell_quote "$groupname")
host_group=$(shell_quote "$host_group")
gid=$(shell_quote "$gid")

if getent group "\$host_group" >/dev/null 2>&1; then
  current_gid="\$(getent group "\$host_group" | awk -F: 'NR==1 { print \$3 }')"
  if [ "\$current_gid" != "\$gid" ]; then
    echo "Host group \$host_group exists with GID \$current_gid, expected \$gid" >&2
    exit 1
  fi
elif getent group "\$gid" >/dev/null 2>&1; then
  current_group="\$(getent group "\$gid" | awk -F: 'NR==1 { print \$1 }')"
  if [ "\$current_group" = "\$groupname" ]; then
    ${sudo_prefix} groupmod -n "\$host_group" "\$current_group"
  else
    echo "Host GID \$gid already belongs to \$current_group, expected \$host_group" >&2
    exit 1
  fi
else
  ${sudo_prefix} groupadd -g "\$gid" "\$host_group"
fi

if getent passwd "\$username" >/dev/null 2>&1; then
  current_uid="\$(getent passwd "\$username" | awk -F: 'NR==1 { print \$3 }')"
  if [ "\$current_uid" != "\$uid" ]; then
    echo "Host user \$username exists with UID \$current_uid, expected \$uid" >&2
    exit 1
  fi
  ${sudo_prefix} usermod -g "\$gid" "\$username"
elif getent passwd "\$uid" >/dev/null 2>&1; then
  current_user="\$(getent passwd "\$uid" | awk -F: 'NR==1 { print \$1 }')"
  if [ "\$current_user" != "\$username" ]; then
    echo "Host UID \$uid already belongs to \$current_user, expected \$username" >&2
    exit 1
  fi
  ${sudo_prefix} usermod -g "\$gid" "\$username"
else
  ${sudo_prefix} useradd -u "\$uid" -g "\$gid" -M -N -s /usr/sbin/nologin "\$username"
fi

if command -v nfsidmap >/dev/null 2>&1; then
  ${sudo_prefix} nfsidmap -c >/dev/null 2>&1 || true
fi

echo "kerberos_host_nfs_identity_ready user=\$username uid=\$uid group=\$host_group gid=\$gid"
EOF
}

build_kerberos_host_nfs_group_command() {
  local groupname="$1"
  local gid="$2"
  local sudo_prefix="${KERBEROS_REMOTE_SUDO:-sudo -n}"
  local netbios_domain="${FARM_KERBEROS_AD_NETBIOS:-FARM}"
  local host_group

  host_group="${netbios_domain}\\${groupname}"

  cat <<EOF
set -eu
groupname=$(shell_quote "$groupname")
host_group=$(shell_quote "$host_group")
gid=$(shell_quote "$gid")

if getent group "\$host_group" >/dev/null 2>&1; then
  current_gid="\$(getent group "\$host_group" | awk -F: 'NR==1 { print \$3 }')"
  if [ "\$current_gid" != "\$gid" ]; then
    echo "Host group \$host_group exists with GID \$current_gid, expected \$gid" >&2
    exit 1
  fi
elif getent group "\$gid" >/dev/null 2>&1; then
  current_group="\$(getent group "\$gid" | awk -F: 'NR==1 { print \$1 }')"
  if [ "\$current_group" = "\$groupname" ]; then
    ${sudo_prefix} groupmod -n "\$host_group" "\$current_group"
  else
    echo "Host GID \$gid already belongs to \$current_group, expected \$host_group" >&2
    exit 1
  fi
else
  ${sudo_prefix} groupadd -g "\$gid" "\$host_group"
fi

if command -v nfsidmap >/dev/null 2>&1; then
  ${sudo_prefix} nfsidmap -c >/dev/null 2>&1 || true
fi

echo "kerberos_host_nfs_group_ready group=\$host_group gid=\$gid"
EOF
}

build_kerberos_nfs_home_access_test_command() {
  local mount_root="$1"
  local username="$2"
  local uid="$3"
  local gid="$4"
  local ccache_file="$5"
  local sudo_prefix="${KERBEROS_REMOTE_SUDO:-sudo -n}"
  local attempts="${FARM_KERBEROS_NFS_ACCESS_RETRIES:-12}"
  local delay_seconds="${FARM_KERBEROS_NFS_ACCESS_RETRY_DELAY:-5}"
  local initial_delay_seconds="${FARM_KERBEROS_NFS_ACCESS_INITIAL_DELAY:-30}"
  local home_dir test_file

  mount_root="${mount_root%/}"
  home_dir="${mount_root}/${username}"
  test_file="${home_dir}/.decs_kerberos_access_check"

  cat <<EOF
set -eu
command -v setpriv >/dev/null
home_dir=$(shell_quote "$home_dir")
test_file=$(shell_quote "$test_file")
ccache=$(shell_quote "FILE:$ccache_file")
if [ "${initial_delay_seconds}" -gt 0 ]; then
  sleep ${initial_delay_seconds}
fi
for attempt in \$(seq 1 ${attempts}); do
  if ${sudo_prefix} setpriv --reuid=${uid} --regid=${gid} --clear-groups env KRB5CCNAME="\$ccache" sh -c 'printf access-check > "\$1" && rm -f "\$1"' _ "\$test_file"; then
    echo "kerberos_nfs_access_ok attempt=\${attempt}"
    exit 0
  fi
  sleep ${delay_seconds}
done
echo "kerberos_nfs_access_failed home=\${home_dir} uid=${uid} gid=${gid}" >&2
exit 1
EOF
}

prepare_lab_storage_user_home() {
  local username="$1"
  local uid="$2"
  local gid="$3"
  local storage_host="${LAB_STORAGE_HOST:-192.168.1.20}"
  local storage_port="${LAB_STORAGE_PORT:-6953}"
  local storage_user="${LAB_STORAGE_USER:-jy}"
  local storage_key="${LAB_STORAGE_SSH_KEY:-}"
  local storage_ssh_common_args="${LAB_STORAGE_SSH_COMMON_ARGS:-}"
  local storage_home_dir raw_command

  storage_home_dir="$(lab_storage_user_home_dir "$username")"
  raw_command="$(build_lab_storage_prepare_home_command "$storage_home_dir" "$uid" "$gid")"
  run_remote_raw_capture "$storage_host" "$storage_port" "$storage_user" "$storage_key" "$raw_command" "$storage_ssh_common_args"
}

prepare_farm_nas_user_home() {
  local username="$1"
  local uid="$2"
  local gid="$3"
  local nas_host="${FARM_NAS_HOST:-192.168.2.30}"
  local nas_port="${FARM_NAS_PORT:-6954}"
  local nas_user="${FARM_NAS_USER:-jy}"
  local nas_key="${FARM_NAS_SSH_KEY:-}"
  local nas_home_dir raw_command

  nas_home_dir="$(farm_nas_user_home_dir "$username")"
  raw_command="$(build_farm_nas_prepare_home_command "$nas_home_dir" "$uid" "$gid")"

  run_remote_raw_capture "$nas_host" "$nas_port" "$nas_user" "$nas_key" "$raw_command"
}

lookup_farm_nas_ad_identity() {
  local username="$1"
  local nas_host="${FARM_NAS_HOST:-192.168.2.30}"
  local nas_port="${FARM_NAS_PORT:-6954}"
  local nas_user="${FARM_NAS_USER:-jy}"
  local nas_key="${FARM_NAS_SSH_KEY:-}"
  local raw_command output identity

  raw_command="$(build_farm_nas_lookup_ad_identity_command "$username")"
  output="$(run_remote_raw_capture "$nas_host" "$nas_port" "$nas_user" "$nas_key" "$raw_command")" || return 1
  identity="$(printf '%s\n' "$output" | tr -d '\r' | awk '/^[0-9]+[[:space:]][0-9]+$/ { print $1 " " $2; found=1 } END { if (!found) exit 1 }')" || {
    echo "Error: could not parse NAS AD identity for ${username}" >&2
    echo "$output" >&2
    return 1
  }

  printf '%s\n' "$identity"
}

lookup_farm_nas_ad_identity_with_retry() {
  local username="$1"
  local attempts="${FARM_KERBEROS_NAS_IDENTITY_RETRIES:-12}"
  local delay_seconds="${FARM_KERBEROS_NAS_IDENTITY_RETRY_DELAY:-5}"
  local attempt output

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if output="$(lookup_farm_nas_ad_identity "$username")"; then
      printf '%s\n' "$output"
      return 0
    fi

    if ((attempt < attempts)); then
      log_event "KERBEROS" "waiting_for_nas_ad_identity username=${username} attempt=${attempt}/${attempts}"
      sleep "$delay_seconds"
    fi
  done

  return 1
}

lookup_farm_nas_ad_group_gid() {
  local groupname="$1"
  local nas_host="${FARM_NAS_HOST:-192.168.2.30}"
  local nas_port="${FARM_NAS_PORT:-6954}"
  local nas_user="${FARM_NAS_USER:-jy}"
  local nas_key="${FARM_NAS_SSH_KEY:-}"
  local raw_command output gid

  raw_command="$(build_farm_nas_lookup_ad_group_gid_command "$groupname")"
  output="$(run_remote_raw_capture "$nas_host" "$nas_port" "$nas_user" "$nas_key" "$raw_command")" || return 1
  gid="$(printf '%s\n' "$output" | tr -d '\r' | awk '/^[0-9]+$/ { print $1; found=1 } END { if (!found) exit 1 }')" || {
    echo "Error: could not parse NAS AD group GID for ${groupname}" >&2
    echo "$output" >&2
    return 1
  }

  printf '%s\n' "$gid"
}

lookup_farm_nas_ad_group_gid_with_retry() {
  local groupname="$1"
  local attempts="${FARM_KERBEROS_NAS_IDENTITY_RETRIES:-12}"
  local delay_seconds="${FARM_KERBEROS_NAS_IDENTITY_RETRY_DELAY:-5}"
  local attempt output

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if output="$(lookup_farm_nas_ad_group_gid "$groupname")"; then
      printf '%s\n' "$output"
      return 0
    fi

    if ((attempt < attempts)); then
      log_event "KERBEROS" "waiting_for_nas_ad_group_gid group=${groupname} attempt=${attempt}/${attempts}"
      sleep "$delay_seconds"
    fi
  done

  return 1
}

prepare_farm_kerberos_nas_user_home() {
  local username="$1"
  local nas_uid="$2"
  local nas_gid="$3"
  local nas_host="${FARM_NAS_HOST:-192.168.2.30}"
  local nas_port="${FARM_NAS_PORT:-6954}"
  local nas_user="${FARM_NAS_USER:-jy}"
  local nas_key="${FARM_NAS_SSH_KEY:-}"
  local nas_home_dir raw_command

  nas_home_dir="$(farm_kerberos_nas_user_home_dir "$username")"
  raw_command="$(build_farm_kerberos_prepare_home_command "$nas_home_dir" "$nas_uid" "$nas_gid")"
  run_remote_raw_capture "$nas_host" "$nas_port" "$nas_user" "$nas_key" "$raw_command"
}

build_farm_kerberos_nas_gss_service_restart_command() {
  local sudo_prefix="${FARM_NAS_SUDO-sudo -n}"
  local svcgssd_bin="${FARM_KERBEROS_NAS_SVCGSSD:-/usr/sbin/svcgssd}"
  local idmapd_bin="${FARM_KERBEROS_NAS_IDMAPD:-/usr/sbin/idmapd}"
  local nfs_principal="${FARM_KERBEROS_NAS_NFS_PRINCIPAL:-nfs/nas.farm.decs.internal@FARM.DECS.INTERNAL}"

  cat <<EOF
set -eu
svcgssd_bin=$(shell_quote "$svcgssd_bin")
idmapd_bin=$(shell_quote "$idmapd_bin")
nfs_principal=$(shell_quote "$nfs_principal")

if [ -n "\$(pidof svcgssd 2>/dev/null || true)" ]; then
  ${sudo_prefix} kill \$(pidof svcgssd)
  sleep 1
fi
${sudo_prefix} "\$svcgssd_bin" -p "\$nfs_principal"

if [ -n "\$(pidof idmapd 2>/dev/null || true)" ]; then
  ${sudo_prefix} kill \$(pidof idmapd)
  sleep 1
fi
${sudo_prefix} "\$idmapd_bin"

flush_epoch="\$(date +%s)"
for cache_flush in \
  /proc/net/rpc/auth.unix.gid/flush \
  /proc/net/rpc/nfs4.idtoname/flush \
  /proc/net/rpc/nfs4.nametoid/flush \
  /proc/net/rpc/auth.rpcsec.init/flush \
  /proc/net/rpc/auth.rpcsec.context/flush; do
  if [ -e "\$cache_flush" ]; then
    printf '%s' "\$flush_epoch" | ${sudo_prefix} tee "\$cache_flush" >/dev/null 2>&1 || true
  fi
done

sleep 1
pidof svcgssd >/dev/null
pidof idmapd >/dev/null
echo "kerberos_nas_gss_services_restarted_and_rpc_caches_flushed"
EOF
}

restart_farm_kerberos_nas_gss_services() {
  local nas_host="${FARM_NAS_HOST:-192.168.2.30}"
  local nas_port="${FARM_NAS_PORT:-6954}"
  local nas_user="${FARM_NAS_USER:-jy}"
  local nas_key="${FARM_NAS_SSH_KEY:-}"
  local enabled="${FARM_KERBEROS_NAS_RESTART_GSS_SERVICES:-true}"
  local raw_command

  case "$enabled" in
  true | TRUE | 1 | yes | YES | on | ON)
    ;;
  *)
    return 0
    ;;
  esac

  raw_command="$(build_farm_kerberos_nas_gss_service_restart_command)"
  run_remote_raw_capture "$nas_host" "$nas_port" "$nas_user" "$nas_key" "$raw_command"
}

prepare_remote_kerberos_ccache_dir() {
  local host_alias="$1"
  local uid="$2"
  local gid="$3"
  local ccache_dir

  ccache_dir="$(farm_kerberos_ccache_dir "$uid")"
  prepare_remote_kerberos_ccache_dir_at "$host_alias" "$ccache_dir" "$uid" "$gid"
}

prepare_remote_kerberos_ccache_dir_at() {
  local host_alias="$1"
  local ccache_dir="$2"
  local uid="$3"
  local gid="$4"
  local raw_command

  raw_command="$(build_kerberos_ccache_dir_command "$ccache_dir" "$uid" "$gid")"
  run_remote_shell "$host_alias" "$raw_command"
}

ensure_remote_kerberos_nfs_identity() {
  local host_alias="$1"
  local username="$2"
  local uid="$3"
  local groupname="$4"
  local gid="$5"
  local raw_command

  raw_command="$(build_kerberos_host_nfs_identity_command "$username" "$uid" "$groupname" "$gid")"
  run_remote_shell "$host_alias" "$raw_command"
}

ensure_remote_kerberos_nfs_group() {
  local host_alias="$1"
  local groupname="$2"
  local gid="$3"
  local raw_command

  raw_command="$(build_kerberos_host_nfs_group_command "$groupname" "$gid")"
  run_remote_shell "$host_alias" "$raw_command"
}

ensure_remote_kerberos_local_identity() {
  local host_alias="$1"
  local username="$2"
  local uid="$3"
  local groupname="$4"
  local gid="$5"
  local raw_command

  raw_command="$(build_kerberos_local_host_identity_command "$username" "$uid" "$groupname" "$gid")"
  run_remote_shell "$host_alias" "$raw_command"
}

ensure_farm_kerberos_keytab() {
  local host_alias="$1"
  local username="$2"
  local principal="$3"
  local keytab_file="$4"
  local rotate_keytab="$5"
  local uid="$6"
  local gid="$7"
  local groupname="${8:-$username}"
  local raw_command

  raw_command="$(build_farm_kerberos_keytab_command "$username" "$principal" "$keytab_file" "$rotate_keytab" "$uid" "$gid" "$groupname")"
  run_remote_shell "$host_alias" "$raw_command"
}

ensure_lab_kerberos_keytab() {
  local host_alias="$1"
  local username="$2"
  local principal="$3"
  local keytab_file="$4"
  local rotate_keytab="$5"
  local uid="$6"
  local gid="$7"
  local storage_host="${LAB_STORAGE_HOST:-192.168.1.20}"
  local storage_port="${LAB_STORAGE_PORT:-6953}"
  local storage_user="${LAB_STORAGE_USER:-jy}"
  local storage_key="${LAB_STORAGE_SSH_KEY:-}"
  local storage_ssh_common_args="${LAB_STORAGE_SSH_COMMON_ARGS:-}"
  local storage_keytab_file output keytab_b64 raw_command

  storage_keytab_file="$(lab_kerberos_storage_keytab_file "$username")"
  raw_command="$(build_lab_kerberos_storage_keytab_command "$username" "$principal" "$storage_keytab_file" "$rotate_keytab" "$uid" "$gid")"
  output="$(run_remote_raw_capture "$storage_host" "$storage_port" "$storage_user" "$storage_key" "$raw_command" "$storage_ssh_common_args")" || return 1
  keytab_b64="$(printf '%s\n' "$output" | awk '
    /__DECS_KEYTAB_B64_BEGIN__/ { capture=1; next }
    /__DECS_KEYTAB_B64_END__/ { capture=0 }
    capture {
      line=$0
      gsub(/\r/, "", line)
      if (line ~ /^[A-Za-z0-9+\/=]+$/) printf "%s", line
    }
  ')"

  if [ -z "$keytab_b64" ]; then
    echo "Error: could not extract LAB Kerberos keytab payload for ${username}" >&2
    echo "$output" >&2
    return 1
  fi

  raw_command="$(build_remote_keytab_install_command "$keytab_file" "$keytab_b64")"
  run_remote_shell "$host_alias" "$raw_command"
}

sync_farm_kerberos_dc_from_dc() {
  local destination_host_alias="$1"
  local source_host_alias="$2"
  local source_fqdn destination_fqdn domain_dn raw_command

  if [ "$source_host_alias" = "$destination_host_alias" ]; then
    return 0
  fi

  source_fqdn="$(farm_kerberos_ad_dc_fqdn "$source_host_alias")"
  destination_fqdn="$(farm_kerberos_ad_dc_fqdn "$destination_host_alias")"
  domain_dn="$(farm_kerberos_domain_dn)"
  raw_command="set -eu
${KERBEROS_REMOTE_SUDO:-sudo -n} samba-tool drs replicate $(shell_quote "$destination_fqdn") $(shell_quote "$source_fqdn") $(shell_quote "$domain_dn") --local --full-sync -P >/dev/null
echo kerberos_ad_dc_synced"
  run_remote_shell "$destination_host_alias" "$raw_command"
}

sync_farm_kerberos_primary_from_dc() {
  sync_farm_kerberos_dc_from_dc "$(farm_kerberos_default_ad_dc_host)" "$1"
}

install_farm_kerberos_host_refresh() {
  local host_alias="$1"
  local username="$2"
  local uid="$3"
  local gid="$4"
  local principal="$5"
  local keytab_file="$6"
  local ccache_dir="$7"
  local ccache_file="$8"
  local refresh_env_file="$9"
  local raw_command

  raw_command="$(build_kerberos_host_refresh_command "$username" "$uid" "$gid" "$principal" "$keytab_file" "$ccache_dir" "$ccache_file" "$refresh_env_file")"
  run_remote_shell "$host_alias" "$raw_command"
}

verify_remote_kerberos_nfs_home_access() {
  local host_alias="$1"
  local mount_root="$2"
  local username="$3"
  local uid="$4"
  local gid="$5"
  local ccache_file="$6"
  local raw_command

  raw_command="$(build_kerberos_nfs_home_access_test_command "$mount_root" "$username" "$uid" "$gid" "$ccache_file")"
  run_remote_shell "$host_alias" "$raw_command"
}

backup_database_locally() {
  local domain_name="$1"
  local backup_dir temp_file timestamp backup_file

  require_mysqldump_cli || return 1

  backup_dir="${BACKUP_ROOT_DIR}/$(echo "$domain_name" | tr '[:upper:]' '[:lower:]')"
  mkdir -p "$backup_dir"

  temp_file=$(mktemp)
  timestamp=$(date +"%Y%m%d_%H%M%S")
  backup_file="${backup_dir}/nfs_db_backup_${timestamp}.sql.gz"

  if mysqldump_exec >"$temp_file"; then
    gzip -c "$temp_file" >"$backup_file"
    rm -f "$temp_file"
    log_event "BACKUP" "database_backup_created domain=${domain_name} path=${backup_file}"
  else
    rm -f "$temp_file"
    log_error "database_backup_failed domain=${domain_name}"
    return 1
  fi
}

update_all_domain_exports() {
  if [ -f "${OPS_SCRIPT_DIR}/export_users_to_excel.py" ]; then
    python3 "${OPS_SCRIPT_DIR}/export_users_to_excel.py" --domains LAB,FARM
  else
    log_error "export_script_missing path=${OPS_SCRIPT_DIR}/export_users_to_excel.py"
  fi
}
