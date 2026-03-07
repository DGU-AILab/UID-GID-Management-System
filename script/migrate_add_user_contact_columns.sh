#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "${SCRIPT_DIR}/db_config.local.env" ]; then
  DB_CONFIG_FILE="${SCRIPT_DIR}/db_config.local.env"
else
  echo "Error: db_config.local.env not found"
  echo "Hint: copy script/db_config.example.env to script/db_config.local.env"
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

if [ ${#alter_clauses[@]} -eq 0 ]; then
  echo "No schema changes needed. user table already has email and phone columns."
  exit 0
fi

alter_sql=$(
  IFS=", "
  echo "${alter_clauses[*]}"
)

echo "Applying schema changes to ${DB_NAME}.user..."
mysql --defaults-extra-file="$MY_CNF_FILE" -D "$DB_NAME" -e "
  ALTER TABLE user
  ${alter_sql};
"

echo "Migration completed successfully."
mysql --defaults-extra-file="$MY_CNF_FILE" -D "$DB_NAME" -e "DESCRIBE user;"
