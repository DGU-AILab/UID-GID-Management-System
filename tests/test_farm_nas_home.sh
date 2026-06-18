#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../script/common_domain_db.sh
source "$ROOT_DIR/script/common_domain_db.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected '$expected', got '$actual'"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label: missing '$needle' in '$haystack'"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    fail "$label: unexpected '$needle' in '$haystack'"
  fi
}

test_shell_quote() {
  assert_eq "'simple'" "$(shell_quote "simple")" "simple quote"
  assert_eq "'a'\''b'" "$(shell_quote "a'b")" "single quote escaping"
}

test_default_home_path() {
  unset FARM_NAS_USER_SHARE_ROOT || true
  assert_eq "/volume1/share/user-share/alice" "$(farm_nas_user_home_dir alice)" "default NAS home path"
}

test_custom_home_path_trims_slash() {
  FARM_NAS_USER_SHARE_ROOT="/srv/user-share/"
  assert_eq "/srv/user-share/alice" "$(farm_nas_user_home_dir alice)" "custom NAS home path"
}

test_prepare_command() {
  FARM_NAS_SUDO="sudo -n"
  local command
  command="$(build_farm_nas_prepare_home_command "/volume1/share/user-share/alice" 10123 10124)"
  assert_contains "$command" "sudo -n mkdir -p '/volume1/share/user-share/alice'" "mkdir command"
  assert_contains "$command" "sudo -n chown '10123:10124' '/volume1/share/user-share/alice'" "chown command"
  assert_contains "$command" "sudo -n chmod 750 '/volume1/share/user-share/alice'" "chmod command"
}

test_prepare_command_without_sudo() {
  FARM_NAS_SUDO=""
  local command
  command="$(build_farm_nas_prepare_home_command "/volume1/share/user-share/alice" 10123 10124)"
  assert_contains "$command" "mkdir -p '/volume1/share/user-share/alice'" "mkdir command without sudo"
  assert_contains "$command" "chown '10123:10124' '/volume1/share/user-share/alice'" "chown command without sudo"
  assert_contains "$command" "chmod 750 '/volume1/share/user-share/alice'" "chmod command without sudo"
  assert_not_contains "$command" "sudo" "no sudo prefix"
}

test_prepare_invokes_raw_ansible() {
  local tmp_dir log output
  tmp_dir="$(mktemp -d)"
  log="$tmp_dir/ansible.args"
  cat > "$tmp_dir/ansible" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$ANSIBLE_STUB_LOG"
EOF
  chmod +x "$tmp_dir/ansible"

  PATH="$tmp_dir:$PATH" \
  ANSIBLE_STUB_LOG="$log" \
  FARM_NAS_HOST="192.0.2.30" \
  FARM_NAS_PORT="6954" \
  FARM_NAS_USER="jy" \
  FARM_NAS_SSH_KEY="/tmp/test-key" \
  FARM_NAS_USER_SHARE_ROOT="/volume1/share/user-share" \
  FARM_NAS_SUDO="sudo -n" \
    prepare_farm_nas_user_home "alice" 10123 10124

  output="$(cat "$log")"
  assert_contains "$output" "192.0.2.30 -i 192.0.2.30," "inline inventory"
  assert_contains "$output" "-u jy" "nas user"
  assert_contains "$output" "ansible_port=6954" "nas port"
  assert_contains "$output" "-m raw" "raw module"
  assert_contains "$output" "--private-key /tmp/test-key" "private key"
  assert_contains "$output" "chown '10123:10124'" "ownership command"
}

test_prepare_invokes_raw_ansible_without_key() {
  local tmp_dir log output
  tmp_dir="$(mktemp -d)"
  log="$tmp_dir/ansible.args"
  cat > "$tmp_dir/ansible" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$ANSIBLE_STUB_LOG"
EOF
  chmod +x "$tmp_dir/ansible"

  PATH="$tmp_dir:$PATH" \
  ANSIBLE_STUB_LOG="$log" \
  FARM_NAS_HOST="192.0.2.31" \
  FARM_NAS_PORT="2222" \
  FARM_NAS_USER="root" \
  FARM_NAS_SSH_KEY="" \
  FARM_NAS_USER_SHARE_ROOT="/share/user-share" \
  FARM_NAS_SUDO="" \
    prepare_farm_nas_user_home "bob" 11000 11000

  output="$(cat "$log")"
  assert_contains "$output" "192.0.2.31 -i 192.0.2.31," "inline inventory without key"
  assert_contains "$output" "-u root" "root nas user"
  assert_contains "$output" "ansible_port=2222" "custom nas port"
  assert_contains "$output" "mkdir -p '/share/user-share/bob'" "mkdir command without key"
  assert_not_contains "$output" "--private-key" "private key omitted"
}

test_shell_quote
test_default_home_path
test_custom_home_path_trims_slash
test_prepare_command
test_prepare_command_without_sudo
test_prepare_invokes_raw_ansible
test_prepare_invokes_raw_ansible_without_key

echo "ok - FARM NAS home tests passed"
