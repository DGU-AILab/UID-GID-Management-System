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
created_by=""
email=""
phone=""
note=""
server_id_input=""
dry_run=false

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
  echo "  -c, --created-by CREATOR        Username of server manager"
  echo "      --email EMAIL               User email (required)"
  echo "      --phone PHONE               User phone (required)"
  echo "  -m, --note NOTE                 Additional notes"
  echo "      --dry-run                   Show planned actions without changing remote hosts or DB"
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
echo "  Created By: $created_by"
echo "  Email: $email"
echo "  Phone: $phone"
echo "  Note: $note"
echo "  Dry Run: $dry_run"
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
port_mappings+=("${available_ssh_port}:22")
port_mappings+=("${available_jupyter_port}:8888")

if [ -n "$container_ports" ]; then
  IFS=',' read -ra CONTAINER_PORT_LIST <<<"$container_ports"
  for container_port in "${CONTAINER_PORT_LIST[@]}"; do
    if [ ${#available_ports[@]} -gt 0 ]; then
      host_port=${available_ports[0]}
      available_ports=("${available_ports[@]:1}")
      port_params+=" -p ${host_port}:${container_port}"
      all_ports+=($host_port)
      port_mappings+=("${host_port}:${container_port}")
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
  if [ ${#port_mappings[@]} -gt 2 ]; then
    echo "[DRY-RUN] Additional port mappings:"
    for mapping in "${port_mappings[@]:2}"; do
      echo "  - ${mapping}"
    done
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
  echo "[DRY-RUN] Would run remote docker create on ${target_host}"
  echo "[DRY-RUN] Would write user/container/port records to ${db_host}:${DB_PORT}/${DB_NAME}"
  echo "[DRY-RUN] Would create local DB backup for ${domain_name}"
  echo "[DRY-RUN] Would refresh LAB and FARM Excel/Google Sheets exports"
  exit 0
fi

echo "Pulling Docker image dguailab/$container_image:$container_version on ${target_host}..."
if ! run_remote_shell "$target_host" "docker pull dguailab/$container_image:$container_version"; then
  cleanup_and_exit "Failed to pull Docker image on ${target_host}"
fi

mysql_exec -e "START TRANSACTION;" || exit 1

remote_run_command="docker run -dit --gpus device=all --memory=192g --memory-swap=192g ${port_params} --runtime=nvidia --cap-add=SYS_ADMIN --ipc=host --mount type=bind,source='/home/tako${server_number}/share/user-share/',target=/home/ --name '${container_name_param}' -e USER_ID='${username}' -e GID='${available_gid}' -e USER_PW='ailab2260' -e USER_GROUP='${groupname}' -e UID='${available_uid}' dguailab/${container_image}:${container_version}"
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

for port_mapping in "${port_mappings[@]:2}"; do
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

echo "Creating database backup..."
backup_database_locally "$domain_name" || true

echo "Updating Google Sheets and Excel export for LAB and FARM..."
update_all_domain_exports
