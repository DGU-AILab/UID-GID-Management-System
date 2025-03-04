#!/bin/bash

# 설정
BACKUP_DIR="/home/tako1/share/mysql_backups"
CONTAINER_NAME="nfs_mysql"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="mysql_backup_$DATE.sql"

# 백업 디렉토리 생성
mkdir -p $BACKUP_DIR

# MySQL 컨테이너에서 백업 실행
echo "MySQL 데이터베이스 백업 시작..."
docker exec $CONTAINER_NAME sh -c 'exec mysqldump --all-databases -uroot -p"$MYSQL_ROOT_PASSWORD"' >"$BACKUP_DIR/$BACKUP_FILE"

# 압축
echo "백업 파일 압축 중..."
gzip "$BACKUP_DIR/$BACKUP_FILE"

echo "백업 완료: $BACKUP_DIR/${BACKUP_FILE}.gz"

# 오래된 백업 정리 (30일 이상된 백업 삭제)
find $BACKUP_DIR -name "mysql_backup_*.sql.gz" -mtime +30 -delete
