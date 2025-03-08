#!/bin/bash

# ==============================

# MySQL Connection
# MySQL 연결 정보
DB_ADDRESS=192.168.2.11
DB_PORT=3307
DB_NAME="nfs_db"
DB_USER="nfs_user"
DB_PASSWORD="nfs_password"

# ==============================

# Create a ~/.my.cnf file
# ~/.my.cnf 파일 생성
echo "[client]
user=nfs_user
password=nfs_password
host=$DB_ADDRESS
port=$DB_PORT" >~/.my.cnf

chmod 600 ~/.my.cnf

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
