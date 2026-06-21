#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_ROOT}/script/common_domain_db.sh"
load_management_config

trap cleanup_mysql_client_config EXIT

name=""
username=""
groupname=""
domain_name=""
server_number=""
server_id=""
container_expiration_date=""
container_image=""
container_version=""
container_name=""
container_ports=""
enable_vnc=false
enable_kerberos=false
rotate_kerberos_keytab=false
created_by=""
email=""
phone=""
note=""
server_id_input=""
dry_run=false
user_password=""
vnc_password=""

generate_password() {
  local length="$1"
  tr -dc A-Za-z0-9 </dev/urandom | head -c "$length"
}

function show_help {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  -h, --help                      Show this help message"
  echo "  -n, --name NAME                 User's actual name"
  echo "  -u, --username USERNAME         Ubuntu username"
  echo "  -g, --group GROUPNAME           Group name"
  echo "      --no-group                  Skip group name (leave empty)"
  echo "      --domain DOMAIN             Domain name (LAB or FARM)"
  echo "      --server-number NUMBER      Server number (e.g., 1, 10)"
  echo "  -s, --server-id SERVER_ID       Server ID (legacy option, e.g., LAB1, FARM3)"
  echo "  -e, --expiration-date DATE      Container expiration date (YYYY-MM-DD)"
  echo "  -i, --image IMAGE               Container image"
  echo "  -v, --version VERSION           Container version"
  echo "  -d, --container-name NAME       Container name"
  echo "      --no-container-name         Skip container name (use default naming)"
  echo "  -p, --container-ports PORTS     Additional container ports (comma-separated)"
  echo "      --no-additional-ports       Skip additional port mappings"
  echo "      --enable-vnc true|false     Enable noVNC GUI access and map container port 6080"
  echo "      --enable_vnc true|false     Alias for --enable-vnc"
  echo "      --enable-kerberos true|false"
  echo "                                    Prepare FARM Kerberos NFS home and ccache mount"
  echo "      --rotate-kerberos-keytab true|false"
  echo "                                    Reset AD password and export a fresh host keytab"
  echo "  -c, --created-by CREATOR        Username of server manager"
  echo "      --email EMAIL               User email (required)"
  echo "      --phone PHONE               User phone (required)"
  echo "  -m, --note NOTE                 Additional notes"
  echo "      --user-password PASSWORD    Initial Ubuntu user password (auto-generated if omitted)"
  echo "      --vnc-password PASSWORD     Initial VNC password, max 8 chars (auto-generated if omitted when VNC is enabled)"
  echo "      --dry-run                   Show planned actions without changing remote hosts or DB"
  echo ""
  echo "FARM NAS home provisioning can be configured with FARM_NAS_HOST,"
  echo "FARM_NAS_PORT, FARM_NAS_USER, FARM_NAS_SSH_KEY, FARM_NAS_USER_SHARE_ROOT,"
  echo "and FARM_NAS_SUDO in config/db_config.local.env."
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    show_help
    ;;
  -n | --name)
    name="$2"
    shift 2
    ;;
  -u | --username)
    username="$2"
    shift 2
    ;;
  -g | --group)
    groupname="$2"
    shift 2
    ;;
  --no-group)
    no_group_flag="true"
    groupname=""
    shift
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
  -e | --expiration-date)
    container_expiration_date="$2"
    shift 2
    ;;
  -i | --image)
    container_image="$2"
    shift 2
    ;;
  -v | --version)
    container_version="$2"
    shift 2
    ;;
  -d | --container-name)
    container_name="$2"
    shift 2
    ;;
  --no-container-name)
    no_container_name_flag="true"
    container_name=""
    shift
    ;;
  -p | --container-ports)
    container_ports="$2"
    shift 2
    ;;
  --no-additional-ports)
    no_additional_ports_flag="true"
    container_ports=""
    shift
    ;;
  --enable-vnc | --enable_vnc)
    case "$2" in
      true | TRUE | 1 | yes | YES | on | ON)
        enable_vnc=true
        ;;
      false | FALSE | 0 | no | NO | off | OFF)
        enable_vnc=false
        ;;
      *)
        echo "Error: $1 must be true or false"
        exit 1
        ;;
    esac
    shift 2
    ;;
  --enable-kerberos | --enable_kerberos)
    case "$2" in
      true | TRUE | 1 | yes | YES | on | ON)
        enable_kerberos=true
        ;;
      false | FALSE | 0 | no | NO | off | OFF)
        enable_kerberos=false
        ;;
      *)
        echo "Error: $1 must be true or false"
        exit 1
        ;;
    esac
    shift 2
    ;;
  --rotate-kerberos-keytab | --rotate_kerberos_keytab)
    case "$2" in
      true | TRUE | 1 | yes | YES | on | ON)
        rotate_kerberos_keytab=true
        ;;
      false | FALSE | 0 | no | NO | off | OFF)
        rotate_kerberos_keytab=false
        ;;
      *)
        echo "Error: $1 must be true or false"
        exit 1
        ;;
    esac
    shift 2
    ;;
  -c | --created-by)
    created_by="$2"
    shift 2
    ;;
  --email)
    email="$2"
    shift 2
    ;;
  --phone)
    phone="$2"
    shift 2
    ;;
  -m | --note)
    note="$2"
    shift 2
    ;;
  --user-password)
    user_password="$2"
    shift 2
    ;;
  --vnc-password)
    vnc_password="$2"
    shift 2
    ;;
  --dry-run)
    dry_run=true
    shift
    ;;
  *)
    echo "Unknown option: $1"
    show_help
    ;;
  esac
done

if [ -z "$name" ]; then
  read -p "User's actual name: " name
fi

if [ -z "$username" ]; then
  read -p "Ubuntu username: " username
fi

if [[ -z "$groupname" && "$no_group_flag" != "true" ]]; then
  read -p "Group name (Press [ENTER] if it doesn't exist): " groupname
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
if [ "$enable_kerberos" = "true" ] && [ "$domain_name" != "FARM" ]; then
  echo "Error: --enable-kerberos is currently supported only for FARM."
  exit 1
fi
server_id="$(compose_server_id "$domain_name" "$server_number")"
target_host="$(compose_ansible_host_alias "$domain_name" "$server_number")"
db_host="$(resolve_db_host_for_domain "$domain_name")" || exit 1

require_mysql_cli || exit 1
require_ansible_cli || exit 1
require_ansible_inventory || exit 1
ensure_ansible_host_exists "$target_host" || exit 1
create_mysql_client_config "$db_host"

if ! mysql_exec -e "SELECT 1;" >/dev/null 2>&1; then
  echo "Error: Failed to connect to database $DB_NAME on $db_host"
  exit 1
fi

if [ -z "$container_expiration_date" ]; then
  read -p "Container expiration date (YYYY-MM-DD): " container_expiration_date
fi

if [ -z "$container_image" ]; then
  read -p "Container image: " container_image
fi

if [ -z "$container_version" ]; then
  read -p "Container version: " container_version
fi

if [[ -z "$container_name" && "$no_container_name_flag" != "true" ]]; then
  read -p "Container name: " container_name
fi

if [[ -z "$container_ports" && "$no_additional_ports_flag" != "true" ]]; then
  read -p "Container ports (comma-separated, e.g., 5678,8888): " container_ports
fi

if [ -z "$created_by" ]; then
  read -p "Created by (Username of server manager): " created_by
fi

while [ -z "$email" ]; do
  read -p "Email (required): " email
  if [ -z "$email" ]; then
    echo "Email is required."
  fi
done

while [ -z "$phone" ]; do
  read -p "Phone (required): " phone
  if [ -z "$phone" ]; then
    echo "Phone is required."
  fi
done

if [ -z "$note" ]; then
  read -p "Note: " note
fi

if [ -z "$user_password" ]; then
  user_password="$(generate_password 12)"
fi

if ! [[ "$user_password" =~ ^[A-Za-z0-9]+$ ]]; then
  echo "Error: --user-password must contain only letters and numbers."
  exit 1
fi

if [ "$enable_vnc" = "true" ] && [ -n "$container_ports" ]; then
  filtered_container_ports=()
  IFS=',' read -ra EXISTING_CONTAINER_PORT_LIST <<<"$container_ports"
  for existing_container_port in "${EXISTING_CONTAINER_PORT_LIST[@]}"; do
    existing_container_port="$(echo "$existing_container_port" | xargs)"
    if [ -n "$existing_container_port" ] && [ "$existing_container_port" != "6080" ]; then
      filtered_container_ports+=("$existing_container_port")
    fi
  done
  container_ports=$(IFS=,; echo "${filtered_container_ports[*]}")
fi

if [ "$enable_vnc" = "true" ]; then
  if [ -z "$vnc_password" ]; then
    vnc_password="$(generate_password 8)"
  fi
  vnc_password="${vnc_password:0:8}"
  if ! [[ "$vnc_password" =~ ^[A-Za-z0-9]+$ ]]; then
    echo "Error: --vnc-password must contain only letters and numbers."
    exit 1
  fi
fi

echo ""
echo ""
echo "Information entered:"
echo "  Name: $name"
echo "  Username: $username"
echo "  Group: $groupname"
echo "  Domain: $domain_name"
echo "  Server Number: $server_number"
echo "  Server ID: $server_id"
echo "  Target Host: $target_host"
echo "  Database Host: $db_host"
echo "  Expiration Date: $container_expiration_date"
echo "  Container Image: $container_image"
echo "  Container Version: $container_version"
echo "  Container Name: $container_name"
echo "  Container Ports: $container_ports"
echo "  Enable VNC: $enable_vnc"
echo "  Enable Kerberos: $enable_kerberos"
if [ "$enable_kerberos" = "true" ]; then
  echo "  Rotate Kerberos keytab: $rotate_kerberos_keytab"
fi
echo "  Created By: $created_by"
echo "  Email: $email"
echo "  Phone: $phone"
echo "  Note: $note"
echo "  Dry Run: $dry_run"
echo "  Initial Ubuntu password: prepared"
if [ "$enable_vnc" = "true" ]; then
  echo "  Initial VNC password: prepared"
fi
echo ""
echo ""

port_base=9000
start_port=$((port_base + 100 * (server_number - 1)))
end_port=$((port_base + 100 * server_number - 1))

used_ports=$(mysql_exec -N -e "SELECT port_number FROM used_ports;")
available_ports=()
for ((port = start_port; port <= end_port; port++)); do
  if ! echo "$used_ports" | grep -q "$port"; then
    available_ports+=($port)
  fi
done

if [ ${#available_ports[@]} -lt 2 ]; then
  echo "Not enough available ports found between $start_port and $end_port"
  exit 1
fi

available_ssh_port=${available_ports[0]}
available_jupyter_port=${available_ports[1]}
echo "Using SSH port: $available_ssh_port"
echo "Using Jupyter port: $available_jupyter_port"
available_ports=("${available_ports[@]:2}")

uid_base=10000
user_info=$(mysql_exec -N -e "SELECT ubuntu_uid FROM user WHERE ubuntu_username='$username';")

if [ -n "$user_info" ]; then
  available_uid=$user_info
  echo "Reusing existing UID: $available_uid for user $username"
else
  max_id=$(mysql_exec -N -e "SELECT COALESCE(MAX(id), $((uid_base - 1))) FROM used_ids;")
  if [ "$max_id" -lt "$uid_base" ]; then
    available_uid=$uid_base
  else
    available_uid=$((max_id + 1))
  fi
  echo "Using new UID: $available_uid for user $username"
fi

if [ -z "$groupname" ]; then
  groupname=$username
fi

group_info=$(mysql_exec -N -e "SELECT ubuntu_gid FROM \`group\` WHERE ubuntu_groupname='$groupname';")

if [ -n "$group_info" ]; then
  available_gid=$group_info
  echo "Reusing existing GID: $available_gid for group $groupname"
else
  if [ "$groupname" != "$username" ]; then
    available_gid=$((available_uid + 1))
    echo "Using new GID: $available_gid for group $groupname"
  else
    available_gid=$available_uid
    echo "Using GID with same value as UID: $available_gid for group $groupname"
  fi
fi

farm_nas_home_dir=""
if [ "$domain_name" = "FARM" ]; then
  if [ "$enable_kerberos" = "true" ]; then
    farm_nas_home_dir="$(farm_kerberos_nas_user_home_dir "$username")"
  else
    farm_nas_home_dir="$(farm_nas_user_home_dir "$username")"
  fi
fi

home_mount_source="/home/tako${server_number}/share/user-share/"
kerberos_ccache_dir=""
kerberos_ccache_file=""
kerberos_principal=""
kerberos_keytab_file=""
kerberos_refresh_env_file=""
kerberos_krb5_conf="${FARM_KERBEROS_KRB5_CONF:-/etc/krb5.conf}"
kerberos_ad_dc_host="${FARM_KERBEROS_AD_DC_HOST:-farm2}"
kerberos_docker_params=""

if [ "$enable_kerberos" = "true" ]; then
  if [ "$kerberos_ad_dc_host" != "$target_host" ]; then
    echo "Error: --enable-kerberos keytab mode currently requires FARM_KERBEROS_AD_DC_HOST (${kerberos_ad_dc_host}) to match target host (${target_host})."
    echo "Hint: for the current PoC, create Kerberos containers on ${kerberos_ad_dc_host}; cross-host keytab transfer is intentionally not automated yet."
    exit 1
  fi
  home_mount_source="$(farm_kerberos_mount_user_share_root)/"
  kerberos_ccache_dir="$(farm_kerberos_ccache_dir "$available_uid")"
  kerberos_ccache_file="$(farm_kerberos_ccache_file "$available_uid")"
  kerberos_principal="$(farm_kerberos_principal "$username")"
  kerberos_keytab_file="$(farm_kerberos_keytab_file "$username")"
  kerberos_refresh_env_file="$(farm_kerberos_refresh_env_file "$username")"
  kerberos_docker_params=" --mount type=bind,source='${kerberos_ccache_dir}',target='${kerberos_ccache_dir}' --mount type=bind,source='${kerberos_krb5_conf}',target=/etc/krb5.conf,readonly -e KRB5CCNAME='FILE:${kerberos_ccache_file}' -e DECS_KERBEROS_ENABLED='true' -e DECS_KERBEROS_HOST_KEYTAB='true' -e DECS_USER_SUDO_MODE='restricted' -e DECS_KRB5_PRINCIPAL='${kerberos_principal}' -e KRB5_REALM='$(farm_kerberos_realm)'"
fi

function cleanup_and_exit {
  echo "Error: $1"

  if [ -n "${target_host:-}" ]; then
    run_remote_shell "$target_host" "docker rm -f '${container_id:-}' >/dev/null 2>&1 || docker rm -f '${container_name_param:-}' >/dev/null 2>&1 || true" >/dev/null 2>&1
  fi

  if [ -n "${MYSQL_CNF_FILE:-}" ] && [ -f "$MYSQL_CNF_FILE" ]; then
    echo "Rolling back database transaction..."
    mysql_exec -e "ROLLBACK;" >/dev/null 2>&1 || true
  fi

  exit 1
}

if [ -n "$container_name" ]; then
  container_name_param="$container_name"
else
  container_name_param="${username}_by_${created_by}"
fi

all_ports=($available_ssh_port $available_jupyter_port)
port_params="-p ${available_ssh_port}:22 -p ${available_jupyter_port}:8888"
port_mappings=()
additional_port_mappings=()
port_mappings+=("${available_ssh_port}:22")
port_mappings+=("${available_jupyter_port}:8888")
vnc_host_port=""

if [ "$enable_vnc" = "true" ]; then
  if [ ${#available_ports[@]} -gt 0 ]; then
    vnc_host_port=${available_ports[0]}
    available_ports=("${available_ports[@]:1}")
    port_params+=" -p ${vnc_host_port}:6080"
    all_ports+=($vnc_host_port)
    port_mappings+=("${vnc_host_port}:6080")
    echo "Using VNC/noVNC port: $vnc_host_port"
  else
    echo "Warning: Not enough available ports for VNC/noVNC port 6080"
  fi
fi

if [ -n "$container_ports" ]; then
  IFS=',' read -ra CONTAINER_PORT_LIST <<<"$container_ports"
  for container_port in "${CONTAINER_PORT_LIST[@]}"; do
    container_port="$(echo "$container_port" | xargs)"
    if [ ${#available_ports[@]} -gt 0 ]; then
      host_port=${available_ports[0]}
      available_ports=("${available_ports[@]:1}")
      port_params+=" -p ${host_port}:${container_port}"
      all_ports+=($host_port)
      port_mappings+=("${host_port}:${container_port}")
      additional_port_mappings+=("${host_port}:${container_port}")
      echo "Mapping host port ${host_port} to container port ${container_port}"
    else
      echo "Warning: Not enough available ports for container port ${container_port}"
    fi
  done
fi

if [ "$dry_run" = "true" ]; then
  echo "[DRY-RUN] Planned remote host: ${target_host}"
  echo "[DRY-RUN] Planned database host: ${db_host}"
  echo "[DRY-RUN] Docker image pull: dguailab/${container_image}:${container_version}"
  echo "[DRY-RUN] Docker container name: ${container_name_param}"
  echo "[DRY-RUN] Primary ports: SSH=${available_ssh_port}, Jupyter=${available_jupyter_port}"
  if [ "$enable_vnc" = "true" ] && [ -n "$vnc_host_port" ]; then
    echo "[DRY-RUN] VNC/noVNC port: ${vnc_host_port}"
  fi
  if [ ${#additional_port_mappings[@]} -gt 0 ]; then
    echo "[DRY-RUN] Additional port mappings:"
    for mapping in "${additional_port_mappings[@]}"; do
      echo "  - ${mapping}"
    done
  fi
  if [ "$enable_vnc" = "true" ]; then
    echo "[DRY-RUN] VNC/noVNC will be enabled with ENABLE_VNC=true"
  fi
  if [ "$enable_kerberos" = "true" ]; then
    echo "[DRY-RUN] Kerberos NFS will be enabled"
    echo "[DRY-RUN] Kerberos home mount source: ${home_mount_source}"
    echo "[DRY-RUN] Kerberos NAS home: ${farm_nas_home_dir} (owner resolved from NAS AD mapping at apply time)"
    echo "[DRY-RUN] Kerberos ccache dir: ${kerberos_ccache_dir}"
    echo "[DRY-RUN] Kerberos ccache file: ${kerberos_ccache_file}"
    echo "[DRY-RUN] Kerberos principal: ${kerberos_principal}"
    echo "[DRY-RUN] Kerberos host keytab: ${kerberos_keytab_file} (root:root 0400 on ${target_host})"
    echo "[DRY-RUN] Kerberos refresh env: ${kerberos_refresh_env_file} (root:root 0600 on ${target_host})"
    echo "[DRY-RUN] Kerberos keytab rotation requested: ${rotate_kerberos_keytab}"
    echo "[DRY-RUN] Kerberos krb5.conf bind source: ${kerberos_krb5_conf}"
    if [ "$groupname" != "$username" ]; then
      echo "[DRY-RUN] Kerberos AD group will be ensured: ${groupname} (gidNumber=${available_gid})"
      echo "[DRY-RUN] Kerberos AD membership will include: ${username} -> ${groupname}"
    fi
  fi
  if [ -n "$user_info" ]; then
    echo "[DRY-RUN] Existing user will be updated: ${username} (UID=${available_uid}, GID=${available_gid})"
  else
    echo "[DRY-RUN] New user will be created: ${username} (UID=${available_uid}, GID=${available_gid})"
  fi
  if [ -n "$group_info" ]; then
    echo "[DRY-RUN] Existing group will be reused: ${groupname} (${available_gid})"
  else
    echo "[DRY-RUN] New group will be created: ${groupname} (${available_gid})"
  fi
  if [ "$domain_name" = "FARM" ] && [ "$enable_kerberos" != "true" ]; then
    echo "[DRY-RUN] Would prepare FARM NAS home: ${farm_nas_home_dir} (${available_uid}:${available_gid})"
  fi
  echo "[DRY-RUN] Would run remote docker create on ${target_host}"
  echo "[DRY-RUN] Would write user/container/port records to ${db_host}:${DB_PORT}/${DB_NAME}"
  echo "[DRY-RUN] Would create local DB backup for ${domain_name}"
  echo "[DRY-RUN] Would refresh LAB and FARM Excel/Google Sheets exports"
  exit 0
fi

echo "Ensuring Docker image dguailab/$container_image:$container_version is available on ${target_host}..."
if ! run_remote_shell "$target_host" "docker image inspect dguailab/$container_image:$container_version >/dev/null 2>&1 || docker pull dguailab/$container_image:$container_version"; then
  cleanup_and_exit "Failed to ensure Docker image on ${target_host}"
fi

if [ "$domain_name" = "FARM" ]; then
  if [ "$enable_kerberos" = "true" ]; then
    farm_nas_identity=""
    echo "Ensuring FARM AD principal and host keytab for ${kerberos_principal} on ${kerberos_ad_dc_host}..."
    if ! ensure_farm_kerberos_keytab "$kerberos_ad_dc_host" "$username" "$kerberos_principal" "$kerberos_keytab_file" "$rotate_kerberos_keytab" "$available_uid" "$available_gid" "$groupname"; then
      cleanup_and_exit "Failed to prepare FARM Kerberos keytab for ${username}"
    fi
    echo "Resolving FARM NAS AD-mapped identity for ${username}..."
    if ! farm_nas_identity="$(lookup_farm_nas_ad_identity_with_retry "$username")"; then
      cleanup_and_exit "Failed to resolve FARM NAS AD identity for ${username}. Create the AD principal before enabling Kerberos."
    fi
    read -r farm_nas_kerberos_uid farm_nas_kerberos_gid <<<"$farm_nas_identity"
    echo "Preparing FARM Kerberos NAS home ${farm_nas_home_dir} for ${username} (${farm_nas_kerberos_uid}:${farm_nas_kerberos_gid})..."
    if ! prepare_farm_kerberos_nas_user_home "$username" "$farm_nas_kerberos_uid" "$farm_nas_kerberos_gid"; then
      cleanup_and_exit "Failed to prepare FARM Kerberos NAS home for ${username}"
    fi
    echo "Refreshing FARM NAS Kerberos NFS identity services..."
    if ! restart_farm_kerberos_nas_gss_services; then
      cleanup_and_exit "Failed to refresh FARM NAS Kerberos NFS identity services for ${username}"
    fi
    echo "Preparing Kerberos credential cache directory ${kerberos_ccache_dir} on ${target_host}..."
    if ! prepare_remote_kerberos_ccache_dir "$target_host" "$available_uid" "$available_gid"; then
      cleanup_and_exit "Failed to prepare Kerberos credential cache directory for ${username}"
    fi
    echo "Installing Kerberos host refresh service for ${username} on ${target_host}..."
    if ! install_farm_kerberos_host_refresh "$target_host" "$username" "$available_uid" "$available_gid" "$kerberos_principal" "$kerberos_keytab_file" "$kerberos_ccache_dir" "$kerberos_ccache_file" "$kerberos_refresh_env_file"; then
      cleanup_and_exit "Failed to install Kerberos host refresh service for ${username}"
    fi
    echo "Verifying Kerberos NFS access for ${username} on ${target_host}..."
    if ! verify_remote_kerberos_nfs_home_access "$target_host" "$(farm_kerberos_mount_user_share_root)" "$username" "$available_uid" "$available_gid" "$kerberos_ccache_file"; then
      cleanup_and_exit "Kerberos NFS access check failed for ${username}. Synology NFS identity mapping may need refresh before container creation."
    fi
  else
    echo "Preparing FARM NAS home ${farm_nas_home_dir} for ${username} (${available_uid}:${available_gid})..."
    if ! prepare_farm_nas_user_home "$username" "$available_uid" "$available_gid"; then
      cleanup_and_exit "Failed to prepare FARM NAS home for ${username}"
    fi
  fi
fi

mysql_exec -e "START TRANSACTION;" || exit 1

vnc_env_params=""
if [ "$enable_vnc" = "true" ]; then
  vnc_env_params=" -e ENABLE_VNC='true' -e VNC_PASSWORD='${vnc_password}'"
fi

remote_run_command="docker run -dit --init --gpus device=all --memory=192g --memory-swap=192g ${port_params} --runtime=nvidia --cap-add=SYS_ADMIN --ipc=host --mount type=bind,source='${home_mount_source}',target=/home/${kerberos_docker_params} --name '${container_name_param}' -e USER_ID='${username}' -e GID='${available_gid}' -e TARGET_GID='${available_gid}' -e USER_PW='${user_password}' -e USER_GROUP='${groupname}' -e UID='${available_uid}' -e TARGET_UID='${available_uid}'${vnc_env_params} -e NVIDIA_DRIVER_CAPABILITIES='compute,utility,graphics,display' dguailab/${container_image}:${container_version}"
container_output=$(run_remote_shell_capture "$target_host" "$remote_run_command") || cleanup_and_exit "Failed to create Docker container on ${target_host}"
container_id=$(printf '%s\n' "$container_output" | tail -n1 | tr -d '\r')

if [[ -z "$container_id" || ! "$container_id" =~ ^[0-9a-f]{12,64}$ ]]; then
  cleanup_and_exit "Unexpected container id returned from ${target_host}: $container_id"
fi

if ! run_remote_shell "$target_host" "docker inspect '${container_name_param}' >/dev/null 2>&1 && docker port '${container_name_param}' | grep -q '${available_ssh_port}'" >/dev/null 2>&1; then
  cleanup_and_exit "Container created but ports not properly bound on ${target_host}"
fi

if [ -z "$user_info" ]; then
  user_id_insert=$(mysql_exec -N -s -e "
    INSERT INTO used_ids (id) VALUES ($available_uid);
    SELECT ROW_COUNT();
  ")

  if [ -z "$user_id_insert" ] || [ "$user_id_insert" -ne 1 ]; then
    cleanup_and_exit "Failed to insert user ID into database"
  fi
fi

if [[ -z "$group_info" && "$available_uid" -ne "$available_gid" ]]; then
  group_id_insert=$(mysql_exec -N -s -e "
    INSERT INTO used_ids (id) VALUES ($available_gid);
    SELECT ROW_COUNT();
  ")

  if [ -z "$group_id_insert" ] || [ "$group_id_insert" -ne 1 ]; then
    cleanup_and_exit "Failed to insert group ID into database"
  fi
fi

if ! mysql_exec -N -e "INSERT INTO used_ports (port_number, purpose_of_use) VALUES ($available_ssh_port, 'ssh');" >/dev/null; then
  cleanup_and_exit "Failed to insert SSH port into database"
fi

if ! mysql_exec -N -e "INSERT INTO used_ports (port_number, purpose_of_use) VALUES ($available_jupyter_port, 'jupyter notebook');" >/dev/null; then
  cleanup_and_exit "Failed to insert Jupyter port into database"
fi

if [ "$enable_vnc" = "true" ] && [ -n "$vnc_host_port" ]; then
  if ! mysql_exec -N -e "INSERT INTO used_ports (port_number, purpose_of_use) VALUES ($vnc_host_port, 'vnc');" >/dev/null; then
    cleanup_and_exit "Failed to insert VNC port into database"
  fi
fi

for port_mapping in "${additional_port_mappings[@]}"; do
  IFS=':' read -ra PORTS <<<"$port_mapping"
  if [[ ${#PORTS[@]} -eq 2 ]]; then
    host_port=${PORTS[0]}
    container_port=${PORTS[1]}
    purpose="container port ${container_port}"
    additional_port_result=$(mysql_exec -N -s -e "
      INSERT INTO used_ports (port_number, purpose_of_use) VALUES (${host_port}, '${purpose}');
      SELECT ROW_COUNT();
    ")

    if [ -z "$additional_port_result" ] || [ "$additional_port_result" -ne 1 ]; then
      cleanup_and_exit "Failed to insert additional port ${host_port} into database"
    fi
  fi
done

if [ -n "$groupname" ] && [ -z "$group_info" ]; then
  group_result=$(mysql_exec -N -s -e "
    INSERT INTO \`group\` (ubuntu_groupname, ubuntu_gid)
    VALUES ('$groupname', $available_gid);
    SELECT ROW_COUNT();")

  if [ -z "$group_result" ] || [ "$group_result" -ne 1 ]; then
    cleanup_and_exit "Failed to insert group record into database"
  fi
fi

if [ -n "$user_info" ]; then
  user_result=$(mysql_exec -N -s -e "
    UPDATE user
    SET name = '$name',
        ubuntu_gid = $available_gid,
        email = '$email',
        phone = '$phone',
        note = '$note'
    WHERE ubuntu_uid = $available_uid;
    SELECT ROW_COUNT();" 2>&1)

  if [ $? -ne 0 ]; then
    cleanup_and_exit "Failed to update user record in database: $user_result"
  fi
else
  user_result=$(mysql_exec -N -s -e "
    INSERT INTO user (name, ubuntu_username, ubuntu_uid, ubuntu_gid, email, phone, note)
    VALUES ('$name', '$username', $available_uid, $available_gid, '$email', '$phone', '$note');
    SELECT ROW_COUNT();")

  if [ -z "$user_result" ] || [ "$user_result" -ne 1 ]; then
    cleanup_and_exit "Failed to insert user record into database"
  fi
fi

container_insert=$(mysql_exec -N -s -e "
INSERT INTO docker_container (
    image,
    image_version,
    container_id,
    container_name,
    server_id,
    expiring_at,
    created_by,
    user_id
) VALUES (
    '$container_image',
    '$container_version',
    '$container_id',
    '${container_name_param}',
    '$server_id',
    '$container_expiration_date',
    '$created_by',
    (SELECT id FROM user WHERE ubuntu_username='$username')
);
SELECT LAST_INSERT_ID();
")

if [ -z "$container_insert" ]; then
  cleanup_and_exit "Failed to insert container record into database"
fi

db_container_id=$container_insert
ports_list=$(IFS=,; echo "${all_ports[*]}")
ports_update_result=$(mysql_exec -N -s -e "
  UPDATE used_ports
  SET docker_container_record_id = $db_container_id
  WHERE port_number IN ($ports_list);
  SELECT ROW_COUNT();
")

mysql_exec -e "COMMIT;"

echo "Successfully added user $username to database host $db_host with container ID $container_id on $target_host"
echo "Port mappings:"
for mapping in "${port_mappings[@]}"; do
  echo "  $mapping"
done

additional_port_mappings_for_email=""
if [ ${#additional_port_mappings[@]} -gt 0 ]; then
  additional_port_mappings_for_email=$(IFS=,; echo "${additional_port_mappings[*]}")
fi

echo "Sending container creation notification email..."
if ! python3 "${PROJECT_ROOT}/script/send_container_created_email.py" \
  --recipient-email "$email" \
  --name "$name" \
  --username "$username" \
  --server-id "$server_id" \
  --image "$container_image" \
  --version "$container_version" \
  --ssh-port "$available_ssh_port" \
  --jupyter-port "$available_jupyter_port" \
  --additional-port-mappings "$additional_port_mappings_for_email" \
  --user-password "$user_password" \
  --vnc-port "$vnc_host_port" \
  --vnc-password "$vnc_password"; then
  log_error "creation_notification_failed username=${username} server=${server_id}"
fi

echo "Creating database backup..."
backup_database_locally "$domain_name" || true

echo "Updating Google Sheets and Excel export for LAB and FARM..."
update_all_domain_exports
