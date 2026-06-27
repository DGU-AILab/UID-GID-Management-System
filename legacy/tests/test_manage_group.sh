#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANAGE_GROUP="$ROOT_DIR/legacy/script/manage_group.sh"
CREATE_CONTAINER="$ROOT_DIR/legacy/script/create_container.sh"
COMMON="$ROOT_DIR/legacy/script/common_domain_db.sh"
INIT_SQL="$ROOT_DIR/nfs_mysql/init.sql"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  grep -qF -- "$pattern" "$file" || fail "$label: missing '$pattern'"
}

bash -n "$MANAGE_GROUP"
bash -n "$CREATE_CONTAINER"
bash -n "$COMMON"

assert_contains "$INIT_SQL" "CREATE TABLE" "schema creates tables"
assert_contains "$INIT_SQL" "user_group_membership" "schema includes supplemental membership table"
assert_contains "$COMMON" "ensure_group_membership_schema" "common migration helper"
assert_contains "$COMMON" "CREATE TABLE IF NOT EXISTS user_group_membership" "runtime migration creates membership table"
assert_contains "$COMMON" "build_farm_kerberos_ensure_group_command" "AD group ensure builder"
assert_contains "$COMMON" "build_farm_kerberos_add_group_member_command" "AD add member builder"
assert_contains "$COMMON" "build_farm_kerberos_remove_group_member_command" "AD remove member builder"
assert_contains "$COMMON" "build_farm_kerberos_delete_group_command" "AD delete group builder"

assert_contains "$CREATE_CONTAINER" "ensure_group_membership_schema" "create_container migrates membership schema"
assert_contains "$CREATE_CONTAINER" "DECS_SUPPLEMENTAL_GROUPS" "create_container passes supplemental groups"
assert_contains "$CREATE_CONTAINER" "user_group_membership ugm" "create_container reads supplemental memberships"
assert_contains "$CREATE_CONTAINER" "Kerberos AD group will be ensured" "create_container dry-run reports AD group"
assert_contains "$CREATE_CONTAINER" "ensure_farm_kerberos_keytab" "create_container ensures AD user/group during Kerberos setup"
assert_contains "$CREATE_CONTAINER" "--no-db-record" "create_container supports no DB record mode"
assert_contains "$CREATE_CONTAINER" "db_transaction_started" "create_container tracks DB transaction state"
assert_contains "$CREATE_CONTAINER" "Skipping DB backup and export refresh because no DB record was written" "create_container skips post DB actions in no DB record mode"

assert_contains "$MANAGE_GROUP" "ensure | add-user | remove-user | set-primary | delete | show | list" "manage_group actions"
assert_contains "$MANAGE_GROUP" "ensure_farm_kerberos_ad_group" "manage_group ensures AD group"
assert_contains "$MANAGE_GROUP" "add_farm_kerberos_group_member" "manage_group adds AD member"
assert_contains "$MANAGE_GROUP" "remove_farm_kerberos_group_member" "manage_group removes AD member"
assert_contains "$MANAGE_GROUP" "delete_farm_kerberos_ad_group" "manage_group deletes AD group"
assert_contains "$MANAGE_GROUP" "INSERT IGNORE INTO user_group_membership" "manage_group inserts supplemental DB membership"
assert_contains "$MANAGE_GROUP" "UPDATE user SET ubuntu_gid" "manage_group can set primary group"
assert_contains "$MANAGE_GROUP" "Cannot delete" "manage_group protects active groups"

echo "ok - manage_group tests passed"
