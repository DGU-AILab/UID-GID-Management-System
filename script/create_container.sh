#!/bin/bash

# ==============================

# MySQL Connection
# MySQL 연결 정보
# Load database configuration from db_config.local.env or db_config.env
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/db_config.local.env" ]; then
  DB_CONFIG_FILE="${SCRIPT_DIR}/db_config.local.env"
elif [ -f "${SCRIPT_DIR}/db_config.env" ]; then
  DB_CONFIG_FILE="${SCRIPT_DIR}/db_config.env"
else
  echo "Error: db_config.local.env or db_config.env not found"
  echo "Hint: copy script/db_config.example.env to script/db_config.local.env"
  exit 1
fi

source "${DB_CONFIG_FILE}"
DB_ADDRESS=$DB_HOST

# ==============================

# Create a ~/.my.cnf file
# ~/.my.cnf 파일 생성
echo "[client]
user=$DB_USER
password=$DB_PASSWORD
host=$DB_ADDRESS
port=$DB_PORT" >~/.my.cnf

chmod 600 ~/.my.cnf

# Initialize variables
# 변수 초기화
name=""
username=""
groupname=""
server_id=""
container_expiration_date=""
container_image=""
container_version=""
container_name=""
container_ports=""
created_by=""
note=""

# Display help function
# 도움말 표시 함수
function show_help {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  -h, --help                      Show this help message"
  echo "  -n, --name NAME                 User's actual name"
  echo "  -u, --username USERNAME         Ubuntu username"
  echo "  -g, --group GROUPNAME           Group name"
  echo "      --no-group                  Skip group name (leave empty)"
  echo "  -s, --server-id SERVER_ID       Server ID (e.g., LAB1, FARM3)"
  echo "  -e, --expiration-date DATE      Container expiration date (YYYY-MM-DD)"
  echo "  -i, --image IMAGE               Container image"
  echo "  -v, --version VERSION           Container version"
  echo "  -d, --container-name NAME       Container name"
  echo "      --no-container-name          Skip container name (use default naming)"
  echo "  -p, --container-ports PORTS     Additional container ports that need mapping from host"
  echo "                                  (comma-separated, e.g., 5678,8888) except ssh and jupyter ports"
  echo "      --no-additional-ports        Skip additional port mappings"
  echo "  -c, --created-by CREATOR        Username of server manager"
  echo "  -m, --note NOTE                 Additional notes"
  exit 0
}

# Parse command line options
# 명령줄 옵션 파싱
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
  -s | --server-id)
    server_id="$2"
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
  -m | --note)
    note="$2"
    shift 2
    ;;
  *)
    echo "Unknown option: $1"
    show_help
    ;;
  esac
done

# Prompt for any values not provided via command line
# 명령줄로 제공되지 않은 값에 대해 사용자 입력 요청
if [ -z "$name" ]; then
  read -p "User's actual name: " name
fi

if [ -z "$username" ]; then
  read -p "Ubuntu username: " username
fi

if [[ -z "$groupname" && "$no_group_flag" != "true" ]]; then
  read -p "Group name (Press [ENTER] if it doesn't exist): " groupname
fi

if [ -z "$server_id" ]; then
  read -p "Server id (e.g., LAB1, FARM3): " server_id
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

if [ -z "$note" ]; then
  read -p "Note: " note
fi

# Display entered information
# 입력된 정보 표시
echo ""
echo ""
echo "Information entered:"
echo "  Name: $name"
echo "  Username: $username"
echo "  Group: $groupname"
echo "  Server ID: $server_id"
echo "  Expiration Date: $container_expiration_date"
echo "  Container Image: $container_image"
echo "  Container Version: $container_version"
echo "  Container Name: $container_name"
echo "  Container Ports: $container_ports"
echo "  Created By: $created_by"
echo "  Note: $note"
echo ""
echo ""

# Extract server name and number from server_id
# server_id에서 서버 이름과 번호 추출
server_name=$(echo "$server_id" | grep -o '[A-Za-z]\+')
server_number=$(echo "$server_id" | grep -o '[0-9]\+')

if [ -z "$server_name" ] || [ -z "$server_number" ]; then
  echo "Error: Server ID must be in format [NAME][NUMBER] (e.g., LAB1, FARM3)"
  exit 1
fi

# Define port range based on server name
# 서버 이름에 따라 포트 범위 정의
port_base=9000
start_port=$((port_base + 100 * (server_number - 1)))
end_port=$((port_base + 100 * server_number - 1))

# Get used ports from the used_ports table
# used_ports 테이블에서 사용 중인 포트 가져오기
used_ports=$(mysql -D "$DB_NAME" -N -e "
    SELECT port_number FROM used_ports;
")

# Initialize ports
# 포트 초기화
available_ports=()

# Find available ports
# 사용 가능한 포트 찾기
for ((port = start_port; port <= end_port; port++)); do
  if ! echo "$used_ports" | grep -q "$port"; then
    available_ports+=($port)
  fi
done

if [ ${#available_ports[@]} -lt 2 ]; then
  echo "Not enough available ports found between $start_port and $end_port"
  exit 1
else
  # Allocate first two ports for SSH and Jupyter
  # SSH와 Jupyter를 위해 처음 두 개의 포트 할당
  available_ssh_port=${available_ports[0]}
  available_jupyter_port=${available_ports[1]}
  echo "Using SSH port: $available_ssh_port"
  echo "Using Jupyter port: $available_jupyter_port"

  # Remove the first two ports from the available ports array
  # 사용 가능한 포트 배열에서 처음 두 개의 포트 제거
  available_ports=("${available_ports[@]:2}")
fi

# Define unified UID/GID base for all servers
# 모든 서버에 대한 통합 UID/GID 기준값 정의
uid_base=10000

# Check if user already exists in the database
# 사용자가 데이터베이스에 이미 존재하는지 확인
user_info=$(mysql -D "$DB_NAME" -N -e "SELECT ubuntu_uid FROM user WHERE ubuntu_username='$username';")

if [ -n "$user_info" ]; then
  # Reuse existing UID for existing user
  # 기존 사용자에 대해 기존 UID 재사용
  available_uid=$user_info
  echo "Reusing existing UID: $available_uid for user $username"
else
  # Find the maximum ID from used_ids table
  # used_ids 테이블에서 최대 ID 찾기
  max_id=$(mysql -D "$DB_NAME" -N -e "
    SELECT COALESCE(MAX(id), $((uid_base - 1)))
    FROM used_ids;
  ")

  # If no existing IDs, start from base
  # 기존 ID가 없으면 기준값부터 시작
  if [ "$max_id" -lt "$uid_base" ]; then
    available_uid=$uid_base
  else
    available_uid=$((max_id + 1))
  fi

  echo "Using new UID: $available_uid for user $username"
fi

# Available GID searching
# 사용 가능한 GID 검색
if [ -z "$groupname" ]; then
  groupname=$username
fi

# Check if group already exists in the database
# 그룹이 데이터베이스에 이미 존재하는지 확인
group_info=$(mysql -D "$DB_NAME" -N -e "
    SELECT ubuntu_gid
    FROM \`group\`
    WHERE ubuntu_groupname='$groupname';
")

if [ -n "$group_info" ]; then
  # Reuse existing GID for existing group
  # 기존 그룹에 대해 기존 GID 재사용
  available_gid=$group_info
  echo "Reusing existing GID: $available_gid for group $groupname"
else
  # Calculate new GID
  # 새 GID 계산
  if [ "$groupname" != "$username" ]; then
    available_gid=$((available_uid + 1))
    echo "Using new GID: $available_gid for group $groupname"
  else
    available_gid=$available_uid
    echo "Using GID with same value as UID: $available_gid for group $groupname"
  fi
fi

echo "Pulling Docker image dguailab/$container_image:$container_version..."
docker pull dguailab/$container_image:$container_version

if [ $? -ne 0 ]; then
  echo "Failed to pull Docker image dguailab/$container_image:$container_version"
  exit 1
fi

# Set container name based on input
# 입력에 따라 컨테이너 이름 설정
if [ -n "$container_name" ]; then
  container_name_param="$container_name"
else
  container_name_param="${username}_by_${created_by}"
fi

# Initialize all_ports array with SSH and Jupyter ports
# SSH 및 Jupyter 포트로 all_ports 배열 초기화
all_ports=($available_ssh_port $available_jupyter_port)

# Initialize port_params with SSH and Jupyter ports
# SSH 및 Jupyter 포트로 port_params 초기화
port_params="-p ${available_ssh_port}:22 -p ${available_jupyter_port}:8888"

# Create a port mapping array to store the host:container port pairs
# 호스트:컨테이너 포트 쌍을 저장할 포트 매핑 배열 생성
port_mappings=()
port_mappings+=("${available_ssh_port}:22")
port_mappings+=("${available_jupyter_port}:8888")

# Add additional ports if specified
# 추가 포트가 지정된 경우 추가
if [ -n "$container_ports" ]; then
  IFS=',' read -ra CONTAINER_PORT_LIST <<<"$container_ports"
  for container_port in "${CONTAINER_PORT_LIST[@]}"; do
    # If we have available ports
    # 사용 가능한 포트가 있는 경우
    if [ ${#available_ports[@]} -gt 0 ]; then
      # Get the next available port
      # 다음으로 사용 가능한 포트 가져오기
      host_port=${available_ports[0]}

      # Remove the used port from available ports
      # 사용한 포트를 사용 가능한 포트에서 제거
      available_ports=("${available_ports[@]:1}")

      # Add to port_params
      # port_params에 추가
      port_params+=" -p ${host_port}:${container_port}"

      # Add to all_ports array
      # all_ports 배열에 추가
      all_ports+=($host_port)

      # Add to port_mappings
      # port_mappings에 추가
      port_mappings+=("${host_port}:${container_port}")

      echo "Mapping host port ${host_port} to container port ${container_port}"
    else
      echo "Warning: Not enough available ports for container port ${container_port}"
    fi
  done
fi

function cleanup_and_exit {
  echo "Error: $1"

  # If container was created, delete it
  # 컨테이너가 생성된 경우 삭제
  if [ -n "$container_id" ] && docker ps -a | grep -q "$container_id"; then
    echo "Removing Docker container..."
    docker rm -f "$container_id" 2>/dev/null
  fi

  # Rollback transaction
  # 트랜잭션 롤백
  echo "Rolling back database transaction..."
  mysql -D "$DB_NAME" -e "ROLLBACK;"

  exit 1
}

if ! mysql -D "$DB_NAME" -e "SELECT 1;" >/dev/null 2>&1; then
  echo "Error: Failed to connect to database $DB_NAME"
  exit 1
fi

mysql -D "$DB_NAME" -e "START TRANSACTION;" || exit 1

# Run the container
# 컨테이너 실행
container_id=$(docker run -dit --gpus device=all --memory=192g --memory-swap=192g \
  ${port_params} --runtime=nvidia --cap-add=SYS_ADMIN --ipc=host \
  --mount type=bind,source="/home/tako${server_number}/share/user-share/",target=/home/ \
  --name "$container_name_param" -e USER_ID=${username} -e GID=${available_gid} -e USER_PW=ailab2260 -e USER_GROUP=${groupname} -e UID=${available_uid} \
  dguailab/${container_image}:${container_version} 2>&1)

# Verify container was created successfully
# 컨테이너가 성공적으로 생성되었는지 확인
if [[ -z "$container_id" || "$container_id" == *"Error"* ]]; then
  cleanup_and_exit "Failed to create Docker container: $container_id"
fi

if ! docker ps | grep -q "${container_name_param}" ||
  ! docker port "${container_name_param}" | grep -q "$available_ssh_port"; then
  cleanup_and_exit "Container created but ports not properly bound"
fi

# Insert new user ID into used_ids table only if it's a new user
# 새 사용자인 경우에만 used_ids 테이블에 새 사용자 ID 삽입
if [ -z "$user_info" ]; then
  user_id_insert=$(mysql -D "$DB_NAME" -N -s -e "
    INSERT INTO used_ids (id) VALUES ($available_uid);
    SELECT ROW_COUNT();
  ")

  if [ -z "$user_id_insert" ] || [ "$user_id_insert" -ne 1 ]; then
    cleanup_and_exit "Failed to insert user ID into database"
  fi
fi

# Insert new group ID into used_ids table only if it's a new group
# 새 그룹인 경우에만 used_ids 테이블에 새 그룹 ID 삽입
if [[ -z "$group_info" && "$available_uid" -ne "$available_gid" ]]; then
  group_id_insert=$(mysql -D "$DB_NAME" -N -s -e "
    INSERT INTO used_ids (id) VALUES ($available_gid);
    SELECT ROW_COUNT();
  ")

  if [ -z "$group_id_insert" ] || [ "$group_id_insert" -ne 1 ]; then
    cleanup_and_exit "Failed to insert group ID into database"
  fi
fi

if ! mysql -D "$DB_NAME" -N -e "INSERT INTO used_ports (port_number, purpose_of_use) VALUES ($available_ssh_port, 'ssh');" >/dev/null; then
  cleanup_and_exit "Failed to insert SSH port into database"
fi

if ! mysql -D "$DB_NAME" -N -e "INSERT INTO used_ports (port_number, purpose_of_use) VALUES ($available_jupyter_port, 'jupyter notebook');" >/dev/null; then
  cleanup_and_exit "Failed to insert Jupyter port into database"
fi

# Insert additional ports
# 추가 포트 삽입
for port_mapping in "${port_mappings[@]:2}"; do # Skip the first two (SSH and Jupyter)
  IFS=':' read -ra PORTS <<<"$port_mapping"
  if [[ ${#PORTS[@]} -eq 2 ]]; then
    host_port=${PORTS[0]}
    container_port=${PORTS[1]}

    purpose="container port ${container_port}"

    # Insert the port into database
    # 데이터베이스에 포트 삽입
    additional_port_result=$(mysql -D "$DB_NAME" -N -s -e "
      INSERT INTO used_ports (port_number, purpose_of_use) VALUES (${host_port}, '${purpose}');
      SELECT ROW_COUNT();
    ")

    if [ -z "$additional_port_result" ] || [ "$additional_port_result" -ne 1 ]; then
      cleanup_and_exit "Failed to insert additional port ${host_port} into database"
    fi
  fi
done

# If a new group was created, insert it into the group table
# 새 그룹이 생성된 경우 그룹 테이블에 삽입
if [ ! -z "$groupname" ] && [ -z "$group_info" ]; then
  group_result=$(mysql -D "$DB_NAME" -N -s -e "
    INSERT INTO \`group\` (
        ubuntu_groupname,
        ubuntu_gid
    ) VALUES (
        '$groupname',
        $available_gid
    );
    SELECT ROW_COUNT();")

  if [ -z "$group_result" ] || [ "$group_result" -ne 1 ]; then
    cleanup_and_exit "Failed to insert group record into database"
  fi
fi

# User table insert or update
# 사용자 테이블 삽입 또는 업데이트
if [ -n "$user_info" ]; then
  user_result=$(mysql -D "$DB_NAME" -N -s -e "
    UPDATE user
    SET ubuntu_gid = $available_gid,
    note = '$note'
    WHERE ubuntu_uid = $available_uid;
    SELECT ROW_COUNT();" 2>&1)

  if [ $? -ne 0 ]; then
    cleanup_and_exit "Failed to update user record in database: $user_result"
  fi
else
  user_result=$(mysql -D "$DB_NAME" -N -s -e "
    INSERT INTO user (name, ubuntu_username, ubuntu_uid, ubuntu_gid, note)
    VALUES ('$name', '$username', $available_uid, $available_gid, '$note');
    SELECT ROW_COUNT();")

  if [ -z "$user_result" ] || [ "$user_result" -ne 1 ]; then
    cleanup_and_exit "Failed to insert user record into database"
  fi
fi

# Insert container info
# 컨테이너 정보 삽입
container_insert=$(mysql -D "$DB_NAME" -N -s -e "
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

# Convert array to comma-separated string for SQL query
# SQL 쿼리를 위해 배열을 쉼표로 구분된 문자열로 변환
ports_list=$(
  IFS=,
  echo "${all_ports[*]}"
)

# Update ports with container reference
# 컨테이너 참조로 포트 업데이트
ports_update_result=$(mysql -D "$DB_NAME" -N -s -e "
  UPDATE used_ports 
  SET docker_container_record_id = $db_container_id
  WHERE port_number IN ($ports_list);
  SELECT ROW_COUNT();
")

mysql -D "$DB_NAME" -e "COMMIT;"

echo "Successfully added user $username to database with container ID $container_id"
echo "Port mappings:"
for mapping in "${port_mappings[@]}"; do
  echo "  $mapping"
done

# 데이터베이스 백업
echo "Creating database backup..."

# 호스트명에서 서버 번호 추출
hostname=$(hostname)
server_number=$(echo "$hostname" | grep -o '[0-9]\+')

# 백업 파일 경로
backup_dir="/home/tako${server_number}/share/mysql_backups"
if [ ! -d "$backup_dir" ]; then
  sudo mkdir -p "$backup_dir"
  sudo chmod 775 "$backup_dir"
fi

# 임시 파일 생성 (svmanager 권한으로 접근 가능한 위치)
temp_file="/tmp/nfs_db_backup_$(date +"%Y%m%d_%H%M%S").sql"

# 백업 파일 이름 만들기
timestamp=$(date +"%Y%m%d_%H%M%S")
backup_file="${backup_dir}/nfs_db_backup_${timestamp}.sql.gz"

# 먼저 SQL 덤프를 생성하고 임시 파일에 저장
if mysqldump --defaults-file=~/.my.cnf --no-tablespaces "$DB_NAME" >"$temp_file"; then
  # gzip으로 압축하고 대상 위치로 이동
  gzip -c "$temp_file" | sudo tee "$backup_file" >/dev/null
  sudo chown svmanager:svmanager "$backup_file"
  rm -f "$temp_file" # 임시 파일 삭제
  echo "Database backup created successfully: $backup_file"
else
  rm -f "$temp_file" # 임시 파일 삭제
  echo "Error: Database backup failed"
fi

# Google Sheets 및 Excel 업데이트
echo "Updating Google Sheets and Excel export..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/export_users_to_excel.py" ]; then
  python3 "${SCRIPT_DIR}/export_users_to_excel.py"
else
  echo "Warning: export_users_to_excel.py not found"
fi
