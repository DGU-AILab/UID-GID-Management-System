#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common_domain_db.sh
source "${PROJECT_ROOT}/script/common_domain_db.sh"
load_management_config

trap cleanup_mysql_client_config EXIT

action=""
domain_name="FARM"
groupname=""
username=""
users_csv=""
requested_gid=""
ad_host="$(farm_kerberos_default_ad_dc_host)"
primary=false
force=false
dry_run=false

show_help() {
  cat <<'EOF'
Usage: manage_group.sh ACTION [options]

Actions:
  ensure        Ensure a DB group and FARM AD group exist
  add-user      Add a user to a group as supplemental membership
  remove-user   Remove a user's supplemental membership from a group
  set-primary   Change a user's primary DB/container group and add AD membership
  delete        Delete an unused group from DB and FARM AD
  show          Show DB and AD group details
  list          List DB groups

Options:
  -g, --group GROUP          Group name
  -u, --user USER            Username
      --users u1,u2          Comma-separated users for repeated add/remove
      --gid GID              Explicit GID when creating a group
      --domain FARM          Domain. Kerberos AD group management is FARM-only
      --ad-host HOST         Ansible host alias for Samba AD DC, default first FARM_KERBEROS_AD_DC_HOSTS entry
      --primary              With add-user, also set the user's primary group
      --force                Delete supplemental memberships before deleting group
      --dry-run              Print the plan without changing DB or AD
  -h, --help                 Show this help

Examples:
  manage_group.sh ensure --group project_a
  manage_group.sh add-user --group project_a --user alice
  manage_group.sh add-user --group project_a --users alice,bob
  manage_group.sh set-primary --group project_a --user alice
  manage_group.sh remove-user --group project_a --user alice
  manage_group.sh delete --group project_a --force
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  ensure | add-user | remove-user | set-primary | delete | show | list)
    if [[ -n "$action" ]]; then
      fail "Only one action can be specified."
    fi
    action="$1"
    shift
    ;;
  -g | --group)
    groupname="$2"
    shift 2
    ;;
  -u | --user)
    username="$2"
    shift 2
    ;;
  --users)
    users_csv="$2"
    shift 2
    ;;
  --gid)
    requested_gid="$2"
    shift 2
    ;;
  --domain)
    domain_name="$2"
    shift 2
    ;;
  --ad-host)
    ad_host="$2"
    shift 2
    ;;
  --primary)
    primary=true
    shift
    ;;
  --force)
    force=true
    shift
    ;;
  --dry-run)
    dry_run=true
    shift
    ;;
  -h | --help)
    show_help
    exit 0
    ;;
  *)
    fail "Unknown option: $1"
    ;;
  esac
done

[[ -n "$action" ]] || {
  show_help
  exit 1
}

domain_name="$(normalize_domain_name "$domain_name")" || exit 1
if [[ "$domain_name" != "FARM" ]]; then
  fail "Kerberos AD group management is currently supported only for FARM."
fi

require_mysql_cli || exit 1
require_ansible_cli || exit 1
require_ansible_inventory || exit 1
ensure_ansible_host_exists "$ad_host" || exit 1
db_host="$(resolve_db_host_for_domain "$domain_name")" || exit 1
create_mysql_client_config "$db_host"

if ! mysql_exec -e "SELECT 1;" >/dev/null 2>&1; then
  fail "Failed to connect to database $DB_NAME on $db_host"
fi

ensure_group_membership_schema || exit 1

if [[ "$action" != "list" ]]; then
  [[ -n "$groupname" ]] || fail "--group is required for action: $action"
  validate_identity_name "$groupname" "group name" || exit 1
fi

if [[ -n "$username" ]]; then
  validate_identity_name "$username" "username" || exit 1
fi

if [[ -n "$users_csv" ]]; then
  IFS=',' read -ra users <<<"$users_csv"
  for candidate_user in "${users[@]}"; do
    candidate_user="$(echo "$candidate_user" | xargs)"
    [[ -n "$candidate_user" ]] || continue
    validate_identity_name "$candidate_user" "username" || exit 1
  done
else
  users=()
fi

if [[ -n "$requested_gid" ]] && ! [[ "$requested_gid" =~ ^[0-9]+$ ]]; then
  fail "--gid must be numeric."
fi

sql_groupname="$(sql_escape "$groupname")"

db_group_gid() {
  local name="$1"
  local sql_name rows count
  sql_name="$(sql_escape "$name")"
  rows="$(mysql_exec -N -B -e "SELECT ubuntu_gid FROM \`group\` WHERE ubuntu_groupname='${sql_name}';")"
  [[ -n "$rows" ]] || return 1
  count="$(printf '%s\n' "$rows" | sed '/^[[:space:]]*$/d' | wc -l)"
  [[ "$count" -eq 1 ]] || fail "Group name is ambiguous in DB: $name"
  printf '%s\n' "$rows" | head -n1
}

db_user_uid() {
  local name="$1"
  local sql_name rows count
  sql_name="$(sql_escape "$name")"
  rows="$(mysql_exec -N -B -e "SELECT ubuntu_uid FROM user WHERE ubuntu_username='${sql_name}';")"
  [[ -n "$rows" ]] || return 1
  count="$(printf '%s\n' "$rows" | sed '/^[[:space:]]*$/d' | wc -l)"
  [[ "$count" -eq 1 ]] || fail "Username is ambiguous in DB: $name"
  printf '%s\n' "$rows" | head -n1
}

db_user_primary_gid() {
  local name="$1"
  local sql_name
  sql_name="$(sql_escape "$name")"
  mysql_exec -N -B -e "SELECT ubuntu_gid FROM user WHERE ubuntu_username='${sql_name}';" | head -n1
}

next_available_gid() {
  local uid_base=10000
  local max_id
  max_id="$(mysql_exec -N -e "SELECT COALESCE(MAX(id), $((uid_base - 1))) FROM used_ids;")"
  if [[ "$max_id" -lt "$uid_base" ]]; then
    printf '%s\n' "$uid_base"
  else
    printf '%s\n' "$((max_id + 1))"
  fi
}

ensure_db_group() {
  local existing_gid gid_for_group gid_owner

  if existing_gid="$(db_group_gid "$groupname")"; then
    if [[ -n "$requested_gid" && "$requested_gid" != "$existing_gid" ]]; then
      fail "Group $groupname already has gid $existing_gid; refusing to change it to $requested_gid."
    fi
    printf '%s\n' "$existing_gid"
    return 0
  fi

  gid_for_group="${requested_gid:-$(next_available_gid)}"
  gid_owner="$(mysql_exec -N -B -e "SELECT ubuntu_groupname FROM \`group\` WHERE ubuntu_gid=${gid_for_group};" | head -n1)"
  if [[ -n "$gid_owner" && "$gid_owner" != "$groupname" ]]; then
    fail "GID $gid_for_group is already used by group $gid_owner."
  fi

  if [[ "$dry_run" == "true" ]]; then
    echo "[DRY-RUN] Would insert DB group ${groupname} gid=${gid_for_group}" >&2
    printf '%s\n' "$gid_for_group"
    return 0
  fi

  mysql_exec -e "START TRANSACTION;"
  mysql_exec -e "INSERT INTO used_ids (id) VALUES (${gid_for_group});" || {
    mysql_exec -e "ROLLBACK;" >/dev/null 2>&1 || true
    fail "Failed to reserve gid ${gid_for_group}."
  }
  mysql_exec -e "INSERT INTO \`group\` (ubuntu_groupname, ubuntu_gid) VALUES ('${sql_groupname}', ${gid_for_group});" || {
    mysql_exec -e "ROLLBACK;" >/dev/null 2>&1 || true
    fail "Failed to insert DB group ${groupname}."
  }
  mysql_exec -e "COMMIT;"
  printf '%s\n' "$gid_for_group"
}

ensure_ad_group() {
  local gid="$1"
  if [[ "$dry_run" == "true" ]]; then
    echo "[DRY-RUN] Would ensure FARM AD group ${groupname} gidNumber=${gid}"
    return 0
  fi
  ensure_farm_kerberos_ad_group "$ad_host" "$groupname" "$gid"
}

add_user_to_group() {
  local member="$1"
  local gid="$2"
  local uid primary_gid sql_member

  uid="$(db_user_uid "$member")" || fail "User not found in DB: $member"
  primary_gid="$(db_user_primary_gid "$member")"
  sql_member="$(sql_escape "$member")"

  if [[ "$dry_run" == "true" ]]; then
    echo "[DRY-RUN] Would add AD member ${member} -> ${groupname}"
  else
    add_farm_kerberos_group_member "$ad_host" "$groupname" "$member"
  fi

  if [[ "$primary" == "true" ]]; then
    if [[ "$dry_run" == "true" ]]; then
      echo "[DRY-RUN] Would set DB primary group ${member} -> ${groupname} (${gid})"
    else
      mysql_exec -e "UPDATE user SET ubuntu_gid=${gid} WHERE ubuntu_username='${sql_member}';"
      mysql_exec -e "DELETE FROM user_group_membership WHERE ubuntu_uid=${uid} AND ubuntu_gid=${gid};"
    fi
    return 0
  fi

  if [[ "$primary_gid" == "$gid" ]]; then
    echo "User ${member} already has ${groupname} as primary group."
    return 0
  fi

  if [[ "$dry_run" == "true" ]]; then
    echo "[DRY-RUN] Would insert supplemental DB membership ${member} -> ${groupname}"
  else
    mysql_exec -e "INSERT IGNORE INTO user_group_membership (ubuntu_uid, ubuntu_gid) VALUES (${uid}, ${gid});"
  fi
}

remove_user_from_group() {
  local member="$1"
  local gid="$2"
  local uid primary_gid

  uid="$(db_user_uid "$member")" || fail "User not found in DB: $member"
  primary_gid="$(db_user_primary_gid "$member")"
  if [[ "$primary_gid" == "$gid" ]]; then
    fail "User ${member} has ${groupname} as primary group. Run set-primary to another group before removing it."
  fi

  if [[ "$dry_run" == "true" ]]; then
    echo "[DRY-RUN] Would remove AD member ${member} from ${groupname}"
    echo "[DRY-RUN] Would delete supplemental DB membership ${member} -> ${groupname}"
  else
    remove_farm_kerberos_group_member "$ad_host" "$groupname" "$member"
    mysql_exec -e "DELETE FROM user_group_membership WHERE ubuntu_uid=${uid} AND ubuntu_gid=${gid};"
  fi
}

delete_group() {
  local gid="$1"
  local primary_count supplemental_count

  primary_count="$(mysql_exec -N -B -e "SELECT COUNT(*) FROM user WHERE ubuntu_gid=${gid};")"
  supplemental_count="$(mysql_exec -N -B -e "SELECT COUNT(*) FROM user_group_membership WHERE ubuntu_gid=${gid};")"

  if [[ "$primary_count" != "0" ]]; then
    fail "Cannot delete ${groupname}; ${primary_count} user(s) still use it as primary group."
  fi

  if [[ "$supplemental_count" != "0" && "$force" != "true" ]]; then
    fail "Cannot delete ${groupname}; ${supplemental_count} supplemental membership(s) exist. Use --force to remove them."
  fi

  if [[ "$dry_run" == "true" ]]; then
    echo "[DRY-RUN] Would delete AD group ${groupname}"
    echo "[DRY-RUN] Would delete DB group ${groupname} gid=${gid}"
    return 0
  fi

  delete_farm_kerberos_ad_group "$ad_host" "$groupname"
  mysql_exec -e "START TRANSACTION;"
  mysql_exec -e "DELETE FROM user_group_membership WHERE ubuntu_gid=${gid};"
  mysql_exec -e "DELETE FROM \`group\` WHERE ubuntu_gid=${gid};"
  mysql_exec -e "COMMIT;"
}

show_group() {
  local gid="$1"
  echo "DB group: ${groupname} (${gid})"
  echo "Primary users:"
  mysql_exec -N -B -e "
    SELECT ubuntu_username
    FROM user
    WHERE ubuntu_gid=${gid}
    ORDER BY ubuntu_username;
  " | sed 's/^/  /'
  echo "Supplemental users:"
  mysql_exec -N -B -e "
    SELECT u.ubuntu_username
    FROM user_group_membership ugm
    JOIN user u ON u.ubuntu_uid = ugm.ubuntu_uid
    WHERE ugm.ubuntu_gid=${gid}
    ORDER BY u.ubuntu_username;
  " | sed 's/^/  /'

  if [[ "$dry_run" == "true" ]]; then
    echo "[DRY-RUN] Would show FARM AD group ${groupname}"
  else
    show_farm_kerberos_ad_group "$ad_host" "$groupname"
  fi
}

list_groups() {
  mysql_exec -t -e "
    SELECT
      g.ubuntu_groupname,
      g.ubuntu_gid,
      (SELECT COUNT(*) FROM user u WHERE u.ubuntu_gid = g.ubuntu_gid) AS primary_users,
      (SELECT COUNT(*) FROM user_group_membership ugm WHERE ugm.ubuntu_gid = g.ubuntu_gid) AS supplemental_users
    FROM \`group\` g
    ORDER BY g.ubuntu_groupname;
  "
}

gid=""
case "$action" in
ensure)
  gid="$(ensure_db_group)"
  ensure_ad_group "$gid"
  ;;
add-user)
  gid="$(ensure_db_group)"
  ensure_ad_group "$gid"
  if [[ ${#users[@]} -eq 0 ]]; then
    [[ -n "$username" ]] || fail "--user or --users is required."
    users=("$username")
  fi
  for member in "${users[@]}"; do
    member="$(echo "$member" | xargs)"
    [[ -n "$member" ]] || continue
    add_user_to_group "$member" "$gid"
  done
  ;;
remove-user)
  gid="$(db_group_gid "$groupname")" || fail "Group not found in DB: $groupname"
  if [[ ${#users[@]} -eq 0 ]]; then
    [[ -n "$username" ]] || fail "--user or --users is required."
    users=("$username")
  fi
  for member in "${users[@]}"; do
    member="$(echo "$member" | xargs)"
    [[ -n "$member" ]] || continue
    remove_user_from_group "$member" "$gid"
  done
  ;;
set-primary)
  primary=true
  gid="$(ensure_db_group)"
  ensure_ad_group "$gid"
  [[ -n "$username" ]] || fail "--user is required."
  add_user_to_group "$username" "$gid"
  ;;
delete)
  gid="$(db_group_gid "$groupname")" || fail "Group not found in DB: $groupname"
  delete_group "$gid"
  ;;
show)
  gid="$(db_group_gid "$groupname")" || fail "Group not found in DB: $groupname"
  show_group "$gid"
  ;;
list)
  list_groups
  ;;
*)
  fail "Unknown action: $action"
  ;;
esac
