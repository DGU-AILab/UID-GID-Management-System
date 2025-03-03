#!/bin/bash

# MySQL Connection
DB_ADDRESS=192.168.2.11
DB_PORT=3307
DB_NAME="nfs_db"
DB_USER="nfs_user"
DB_PASSWORD="nfs_password"

# Create a ~/.my.cnf file
echo "[client]
user=nfs_user
password=nfs_password
host=$DB_ADDRESS
port=$DB_PORT" >~/.my.cnf

chmod 600 ~/.my.cnf

# Initialize variables
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
server_name=$(echo "$server_id" | grep -o '[A-Za-z]\+')
server_number=$(echo "$server_id" | grep -o '[0-9]\+')

if [ -z "$server_name" ] || [ -z "$server_number" ]; then
  echo "Error: Server ID must be in format [NAME][NUMBER] (e.g., LAB1, FARM3)"
  exit 1
fi

# Define port range based on server name
port_base=9000
start_port=$((port_base + 100 * (server_number - 1)))
end_port=$((port_base + 100 * server_number - 1))

# Get used ports from the used_ports table
used_ports=$(mysql -D "$DB_NAME" -N -e "
    SELECT port_number FROM used_ports;
")

# Initialize ports
available_ports=()

# Find available ports
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
  available_ssh_port=${available_ports[0]}
  available_jupyter_port=${available_ports[1]}
  echo "Using SSH port: $available_ssh_port"
  echo "Using Jupyter port: $available_jupyter_port"

  # Remove the first two ports from the available ports array
  available_ports=("${available_ports[@]:2}")
fi

# Define unified UID/GID base for all servers
uid_base=10000

# Check if user already exists in the database
user_info=$(mysql -D "$DB_NAME" -N -e "SELECT ubuntu_uid FROM user WHERE ubuntu_username='$username';")

if [ -n "$user_info" ]; then
  # Reuse existing UID for existing user
  available_uid=$user_info
  echo "Reusing existing UID: $available_uid for user $username"
else
  # Find the maximum ID from used_ids table
  max_id=$(mysql -D "$DB_NAME" -N -e "
    SELECT COALESCE(MAX(id), $((uid_base - 1)))
    FROM used_ids;
  ")

  # If no existing IDs, start from base
  if [ "$max_id" -lt "$uid_base" ]; then
    available_uid=$uid_base
  else
    available_uid=$((max_id + 1))
  fi

  echo "Using new UID: $available_uid for user $username"
fi

# Available GID searching
if [ -z "$groupname" ]; then
  groupname=$username
fi

# Check if group already exists in the database
group_info=$(mysql -D "$DB_NAME" -N -e "
    SELECT ubuntu_gid
    FROM \`group\`
    WHERE ubuntu_groupname='$groupname';
")

if [ -n "$group_info" ]; then
  # Reuse existing GID for existing group
  available_gid=$group_info
  echo "Reusing existing GID: $available_gid for group $groupname"
else
  # Calculate new GID
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
if [ -n "$container_name" ]; then
  container_name_param="$container_name"
else
  container_name_param="${username}_by_${created_by}"
fi

# Initialize all_ports array with SSH and Jupyter ports
all_ports=($available_ssh_port $available_jupyter_port)

# Initialize port_params with SSH and Jupyter ports
port_params="-p ${available_ssh_port}:22 -p ${available_jupyter_port}:8888"

# Create a port mapping array to store the host:container port pairs
port_mappings=()
port_mappings+=("${available_ssh_port}:22")
port_mappings+=("${available_jupyter_port}:8888")

# Add additional ports if specified
if [ -n "$container_ports" ]; then
  IFS=',' read -ra CONTAINER_PORT_LIST <<<"$container_ports"
  for container_port in "${CONTAINER_PORT_LIST[@]}"; do
    # If we have available ports
    if [ ${#available_ports[@]} -gt 0 ]; then
      # Get the next available port
      host_port=${available_ports[0]}

      # Remove the used port from available ports
      available_ports=("${available_ports[@]:1}")

      # Add to port_params
      port_params+=" -p ${host_port}:${container_port}"

      # Add to all_ports array
      all_ports+=($host_port)

      # Add to port_mappings
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
  if [ -n "$container_id" ] && docker ps -a | grep -q "$container_id"; then
    echo "Removing Docker container..."
    docker rm -f "$container_id" 2>/dev/null
  fi

  # Rollback transaction
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
container_id=$(docker run -dit --gpus device=all --memory=192g --memory-swap=192g \
  ${port_params} --runtime=nvidia --cap-add=SYS_ADMIN --ipc=host \
  --mount type=bind,source="/home/tako${server_number}/share/user-share/",target=/home/ \
  --name "$container_name_param" -e USER_ID=${username} -e USER_PW=ailab2260 -e USER_GROUP=${groupname} -e UID=${available_uid} \
  dguailab/${container_image}:${container_version} 2>&1)

# Verify container was created successfully
if [[ -z "$container_id" || "$container_id" == *"Error"* ]]; then
  cleanup_and_exit "Failed to create Docker container: $container_id"
fi

if ! docker ps | grep -q "${container_name_param}" ||
  ! docker port "${container_name_param}" | grep -q "$available_ssh_port"; then
  cleanup_and_exit "Container created but ports not properly bound"
fi

# Insert new user ID into used_ids table only if it's a new user
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
for port_mapping in "${port_mappings[@]:2}"; do # Skip the first two (SSH and Jupyter)
  IFS=':' read -ra PORTS <<<"$port_mapping"
  if [[ ${#PORTS[@]} -eq 2 ]]; then
    host_port=${PORTS[0]}
    container_port=${PORTS[1]}

    purpose="container port ${container_port}"

    # Insert the port into database
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
ports_list=$(
  IFS=,
  echo "${all_ports[*]}"
)

# Update ports with container reference
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
