#!/bin/bash

# ==============================

# MySQL Connection
# MySQL 연결 정보
# Load database configuration from db_config.local.env
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/db_config.local.env" ]; then
  DB_CONFIG_FILE="${SCRIPT_DIR}/db_config.local.env"
else
  echo "Error: db_config.local.env not found"
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
container_id=""
container_name=""
force=false

# Display help function
# 도움말 표시 함수
function show_help {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  -h, --help                      Show this help message"
  echo "  -i, --container-id ID           Docker container ID"
  echo "  -n, --container-name NAME       Docker container name"
  echo "  -f, --force                     Force deletion even if database update fails"
  exit 0
}

# Parse command line options
# 명령줄 옵션 파싱
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
  -f | --force)
    force=true
    shift
    ;;
  *)
    echo "Unknown option: $1"
    show_help
    ;;
  esac
done

# Validate input
# 입력값 검증
if [ -z "$container_id" ] && [ -z "$container_name" ]; then
  read -p "Enter container ID or name: " container_input

  # Check if input looks like a container ID (hexadecimal string)
  # 입력값이 컨테이너 ID(16진수 문자열)인지 확인
  if [[ $container_input =~ ^[0-9a-f]{12}$ ]] || [[ $container_input =~ ^[0-9a-f]{64}$ ]]; then
    container_id=$container_input
  else
    container_name=$container_input
  fi
fi

# Start transaction
# 트랜잭션 시작
mysql -D "$DB_NAME" -e "START TRANSACTION;"

# Look up container in database
# 데이터베이스에서 컨테이너 조회
if [ -n "$container_id" ]; then
  db_container=$(mysql -D "$DB_NAME" -N -e "
    SELECT id, container_id, container_name
    FROM docker_container
    WHERE container_id LIKE '$container_id%' AND existing = 1;")
elif [ -n "$container_name" ]; then
  db_container=$(mysql -D "$DB_NAME" -N -e "
    SELECT id, container_id, container_name
    FROM docker_container
    WHERE container_name = '$container_name' AND existing = 1;")
fi

if [ -z "$db_container" ]; then
  echo "Container not found in database or already marked as deleted."

  # Check if the container exists in Docker but not in the database
  # Docker에는 존재하지만 데이터베이스에는 없는 컨테이너인지 확인
  if [ -n "$container_name" ] && docker ps -a | grep -q "$container_name"; then
    echo "Container exists in Docker but not in database (or marked as deleted)."
    read -p "Do you want to force remove the Docker container? (y/n): " force_remove
    if [[ "$force_remove" == "y" ]]; then
      docker rm -f "$container_name"
      echo "Container removed from Docker."
    fi
  elif [ -n "$container_id" ] && docker ps -a | grep -q "$container_id"; then
    echo "Container exists in Docker but not in database (or marked as deleted)."
    read -p "Do you want to force remove the Docker container? (y/n): " force_remove
    if [[ "$force_remove" == "y" ]]; then
      docker rm -f "$container_id"
      echo "Container removed from Docker."
    fi
  fi

  mysql -D "$DB_NAME" -e "ROLLBACK;"
  exit 1
fi

# Extract container info
# 컨테이너 정보 추출
read db_container_id actual_container_id actual_container_name <<<$(echo "$db_container" | awk '{print $1, $2, $3}')

echo "Found container in database: $actual_container_name ($actual_container_id)"

# Delete port records associated with this container
# 이 컨테이너와 연관된 포트 레코드 삭제
ports_update=$(mysql -D "$DB_NAME" -N -e "
  DELETE FROM used_ports
  WHERE docker_container_record_id = $db_container_id;
  SELECT ROW_COUNT();")

echo "Deleted $ports_update port records associated with the container."

# Mark container as deleted in database
# 데이터베이스에서 컨테이너를 삭제된 것으로 표시
container_update=$(mysql -D "$DB_NAME" -N -e "
  UPDATE docker_container
  SET existing = 0, deleted_at = NOW()
  WHERE id = $db_container_id;
  SELECT ROW_COUNT();")

if [ "$container_update" -ne 1 ]; then
  echo "Failed to update container record in database: $container_update"
  if [ "$force" != "true" ]; then
    mysql -D "$DB_NAME" -e "ROLLBACK;"
    exit 1
  fi
else
  echo "Container marked as deleted in database."
fi

# Try to remove the Docker container
# Docker 컨테이너 제거 시도
if docker ps -a | grep -q "$actual_container_id" || docker ps -a | grep -q "$actual_container_name"; then
  if docker rm -f "$actual_container_id" 2>/dev/null || docker rm -f "$actual_container_name" 2>/dev/null; then
    echo "Container successfully removed from Docker."
  else
    echo "Failed to remove container from Docker."
    if [ "$force" != "true" ]; then
      mysql -D "$DB_NAME" -e "ROLLBACK;"
      exit 1
    fi
  fi
else
  echo "Container not found in Docker, but database updated successfully."
fi

# Commit the transaction
# 트랜잭션 커밋
mysql -D "$DB_NAME" -e "COMMIT;"

echo "Container deletion completed successfully."

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
