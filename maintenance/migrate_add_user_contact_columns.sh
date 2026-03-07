#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${PROJECT_ROOT}/config"

if [ -f "${CONFIG_DIR}/db_config.local.env" ]; then
  DB_CONFIG_FILE="${CONFIG_DIR}/db_config.local.env"
else
  echo "Error: db_config.local.env not found"
  echo "Hint: copy config/db_config.example.env to config/db_config.local.env"
  exit 1
fi

source "${DB_CONFIG_FILE}"

MY_CNF_FILE=$(mktemp)
trap 'rm -f "$MY_CNF_FILE"' EXIT

cat >"$MY_CNF_FILE" <<EOF
[client]
user=$DB_USER
password=$DB_PASSWORD
host=$DB_HOST
port=$DB_PORT
EOF

chmod 600 "$MY_CNF_FILE"

email_exists=$(mysql --defaults-extra-file="$MY_CNF_FILE" -N -s -D "$DB_NAME" -e "
  SELECT COUNT(*)
  FROM information_schema.columns
  WHERE table_schema = '$DB_NAME'
    AND table_name = 'user'
    AND column_name = 'email';
")

phone_exists=$(mysql --defaults-extra-file="$MY_CNF_FILE" -N -s -D "$DB_NAME" -e "
  SELECT COUNT(*)
  FROM information_schema.columns
  WHERE table_schema = '$DB_NAME'
    AND table_name = 'user'
    AND column_name = 'phone';
")

alter_clauses=()

if [ "$email_exists" -eq 0 ]; then
  alter_clauses+=("ADD COLUMN email VARCHAR(255) NULL AFTER ubuntu_gid")
fi

if [ "$phone_exists" -eq 0 ]; then
  if [ "$email_exists" -eq 0 ]; then
    alter_clauses+=("ADD COLUMN phone VARCHAR(32) NULL AFTER email")
  else
    alter_clauses+=("ADD COLUMN phone VARCHAR(32) NULL AFTER ubuntu_gid")
  fi
fi

if [ ${#alter_clauses[@]} -gt 0 ]; then
  alter_sql=$(
    IFS=", "
    echo "${alter_clauses[*]}"
  )

  echo "Applying schema changes to ${DB_NAME}.user..."
  mysql --defaults-extra-file="$MY_CNF_FILE" -D "$DB_NAME" -e "
    ALTER TABLE user
    ${alter_sql};
  "
else
  echo "No schema changes needed. user table already has email and phone columns."
fi

echo "Refreshing user_container_info view..."
mysql --defaults-extra-file="$MY_CNF_FILE" -D "$DB_NAME" -e "
  CREATE OR REPLACE VIEW user_container_info AS
  SELECT
      u.name AS '사용자 이름',
      u.ubuntu_username AS '우분투 아이디',
      u.email AS '이메일',
      u.phone AS '전화번호',
      g.ubuntu_groupname AS '우분투 그룹 이름',
      dc.server_id AS '배정된 서버',
      (
          SELECT
              up.port_number
          FROM
              used_ports up
          WHERE
              up.docker_container_record_id = dc.id
              AND up.purpose_of_use = 'ssh'
      ) AS 'ssh 포트',
      (
          SELECT
              up.port_number
          FROM
              used_ports up
          WHERE
              up.docker_container_record_id = dc.id
              AND up.purpose_of_use = 'jupyter notebook'
      ) AS 'jupyter 포트',
      (
          SELECT
              GROUP_CONCAT(
                  up.port_number
                  ORDER BY
                      up.port_number SEPARATOR ', '
              )
          FROM
              used_ports up
          WHERE
              up.docker_container_record_id = dc.id
              AND up.purpose_of_use != 'ssh'
              AND up.purpose_of_use != 'jupyter notebook'
      ) AS '기타 할당 포트',
      dc.expiring_at AS '사용 만료일',
      dc.created_by AS '컨테이너 생성한 관리자',
      dc.created_at AS '컨테이너 생성 일자',
      dc.image AS '컨테이너 이미지',
      dc.image_version AS '컨테이너 버전',
      dc.container_name AS '컨테이너 이름',
      u.note AS '노트'
  FROM
      user u
      LEFT JOIN \`group\` g ON u.ubuntu_gid = g.ubuntu_gid
      JOIN docker_container dc ON u.id = dc.user_id
  WHERE
      dc.existing = TRUE
  ORDER BY
      dc.server_id ASC,
      u.name ASC;
"

echo "Migration completed successfully."
mysql --defaults-extra-file="$MY_CNF_FILE" -D "$DB_NAME" -e "DESCRIBE user;"
