#!/bin/bash

# ==============================

# MySQL Connection
DB_ADDRESS=127.0.0.1
DB_PORT=3306
DB_NAME="nfs_db"
DB_USER="nfs_user"
DB_PASSWORD="nfs_password"

# ==============================

# Create a ~/.my.cnf file
echo "[client]
user=nfs_user
password=nfs_password
host=$DB_ADDRESS
port=$DB_PORT" >~/.my.cnf

chmod 600 ~/.my.cnf

# Initialize variables
container_id=""
container_name=""
force=false

# Display help function
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
if [ -z "$container_id" ] && [ -z "$container_name" ]; then
  read -p "Enter container ID or name: " container_input

  # Check if input looks like a container ID (hexadecimal string)
  if [[ $container_input =~ ^[0-9a-f]{12}$ ]] || [[ $container_input =~ ^[0-9a-f]{64}$ ]]; then
    container_id=$container_input
  else
    container_name=$container_input
  fi
fi

# Start transaction
mysql -D "$DB_NAME" -e "START TRANSACTION;"

# Look up container in database
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
read db_container_id actual_container_id actual_container_name <<<$(echo "$db_container" | awk '{print $1, $2, $3}')

echo "Found container in database: $actual_container_name ($actual_container_id)"

# Delete port records associated with this container
ports_update=$(mysql -D "$DB_NAME" -N -e "
  DELETE FROM used_ports
  WHERE docker_container_record_id = $db_container_id;
  SELECT ROW_COUNT();")

echo "Deleted $ports_update port records associated with the container."

# Mark container as deleted in database
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
mysql -D "$DB_NAME" -e "COMMIT;"

echo "Container deletion completed successfully."
