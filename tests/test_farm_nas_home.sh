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

test_kerberos_paths() {
  unset FARM_KERBEROS_NAS_USER_SHARE_ROOT || true
  unset FARM_KERBEROS_MOUNT_USER_SHARE_ROOT || true
  unset FARM_KERBEROS_CCACHE_BASE || true
  unset FARM_KERBEROS_REALM || true
  unset FARM_KERBEROS_KEYTAB_DIR || true
  unset FARM_KERBEROS_REFRESH_ENV_DIR || true
  assert_eq "/volume1/test_krb/user-share/alice" "$(farm_kerberos_nas_user_home_dir alice)" "default Kerberos NAS home path"
  assert_eq "/mnt/nas-krb-test-v4/user-share" "$(farm_kerberos_mount_user_share_root)" "default Kerberos mount root"
  assert_eq "/run/user/10123" "$(farm_kerberos_ccache_dir 10123)" "default Kerberos ccache dir"
  assert_eq "/run/user/10123/krb5cc" "$(farm_kerberos_ccache_file 10123)" "default Kerberos ccache file"
  assert_eq "FARM.DECS.INTERNAL" "$(farm_kerberos_realm)" "default Kerberos realm"
  assert_eq "alice@FARM.DECS.INTERNAL" "$(farm_kerberos_principal alice)" "default Kerberos principal"
  assert_eq "/etc/decs-krb/keytabs" "$(farm_kerberos_keytab_dir)" "default Kerberos keytab dir"
  assert_eq "/etc/decs-krb/keytabs/alice.keytab" "$(farm_kerberos_keytab_file alice)" "default Kerberos keytab file"
  assert_eq "/etc/decs-krb/refresh.d/alice.env" "$(farm_kerberos_refresh_env_file alice)" "default Kerberos refresh env file"

  FARM_KERBEROS_NAS_USER_SHARE_ROOT="/volume1/krb/user-share/"
  FARM_KERBEROS_MOUNT_USER_SHARE_ROOT="/mnt/krb/user-share/"
  FARM_KERBEROS_CCACHE_BASE="/run/decs-krb/"
  FARM_KERBEROS_REALM="LAB.EXAMPLE.INTERNAL"
  FARM_KERBEROS_KEYTAB_DIR="/srv/keytabs/"
  FARM_KERBEROS_REFRESH_ENV_DIR="/srv/refresh.d/"
  assert_eq "/volume1/krb/user-share/alice" "$(farm_kerberos_nas_user_home_dir alice)" "custom Kerberos NAS home path"
  assert_eq "/mnt/krb/user-share" "$(farm_kerberos_mount_user_share_root)" "custom Kerberos mount root"
  assert_eq "/run/decs-krb/10123" "$(farm_kerberos_ccache_dir 10123)" "custom Kerberos ccache dir"
  assert_eq "alice@LAB.EXAMPLE.INTERNAL" "$(farm_kerberos_principal alice)" "custom Kerberos principal"
  assert_eq "/srv/keytabs/alice.keytab" "$(farm_kerberos_keytab_file alice)" "custom Kerberos keytab file"
  assert_eq "/srv/refresh.d/alice.env" "$(farm_kerberos_refresh_env_file alice)" "custom Kerberos refresh env file"
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

test_kerberos_prepare_home_command() {
  FARM_NAS_SUDO="sudo -n"
  local command
  command="$(build_farm_kerberos_prepare_home_command "/volume1/test_krb/user-share/alice" 96470099 96469505)"
  assert_contains "$command" "sudo -n mkdir -p '/volume1/test_krb/user-share/alice'" "Kerberos mkdir command"
  assert_contains "$command" "sudo -n chown '96470099:96469505' '/volume1/test_krb/user-share/alice'" "Kerberos chown command"
  assert_contains "$command" "sudo -n chmod 750 '/volume1/test_krb/user-share/alice'" "Kerberos chmod command"
}

test_kerberos_ccache_command() {
  KERBEROS_REMOTE_SUDO="sudo -n"
  local command
  command="$(build_kerberos_ccache_dir_command "/run/user/10123" 10123 10124)"
  assert_contains "$command" "sudo -n install -d -o 10123 -g 10124 -m 0700 '/run/user/10123'" "ccache install command"
  assert_contains "$command" "sudo -n chown '10123:10124' '/run/user/10123'" "ccache chown command"
  assert_contains "$command" "sudo -n chmod 700 '/run/user/10123'" "ccache chmod command"
}

test_kerberos_lookup_command() {
  FARM_KERBEROS_AD_NETBIOS="FARM"
  local command
  command="$(build_farm_nas_lookup_ad_identity_command "alice")"
  assert_contains "$command" "/usr/local/packages/@appstore/SMBService/usr/bin/wbinfo" "wbinfo path"
  assert_contains "$command" "'FARM\\alice'" "AD identity"
  assert_contains "$command" "awk -F:" "parse uid/gid"
}

test_kerberos_nas_gss_service_restart_command() {
  FARM_NAS_SUDO="sudo -n"
  FARM_KERBEROS_NAS_SVCGSSD="/usr/sbin/svcgssd"
  FARM_KERBEROS_NAS_IDMAPD="/usr/sbin/idmapd"
  FARM_KERBEROS_NAS_NFS_PRINCIPAL="nfs/nas.farm.decs.internal@FARM.DECS.INTERNAL"
  local command
  command="$(build_farm_kerberos_nas_gss_service_restart_command)"
  assert_contains "$command" "svcgssd_bin='/usr/sbin/svcgssd'" "uses svcgssd path"
  assert_contains "$command" "idmapd_bin='/usr/sbin/idmapd'" "uses idmapd path"
  assert_contains "$command" "nfs_principal='nfs/nas.farm.decs.internal@FARM.DECS.INTERNAL'" "uses NFS principal"
  assert_contains "$command" "kill \$(pidof svcgssd)" "restarts svcgssd"
  assert_contains "$command" "\"\$svcgssd_bin\" -p \"\$nfs_principal\"" "starts svcgssd with principal"
  assert_contains "$command" "kill \$(pidof idmapd)" "restarts idmapd"
  assert_contains "$command" "\"\$idmapd_bin\"" "starts idmapd"
  assert_contains "$command" "kerberos_nas_gss_services_restarted" "reports success"
}

test_kerberos_keytab_command() {
  KERBEROS_REMOTE_SUDO="sudo -n"
  local command
  command="$(build_farm_kerberos_keytab_command "alice" "alice@FARM.DECS.INTERNAL" "/etc/decs-krb/keytabs/alice.keytab" "false" 10123 10124)"
  assert_contains "$command" "samba-tool user show" "checks existing AD user"
  assert_contains "$command" "samba-tool user create" "creates missing AD user"
  assert_contains "$command" "samba-tool user addunixattrs" "adds RFC2307 attrs"
  assert_contains "$command" "--gid-number=\"\$gid\"" "sets RFC2307 gid"
  assert_contains "$command" "--unix-home='/home/alice'" "sets RFC2307 home"
  assert_contains "$command" "--login-shell=/bin/bash" "sets RFC2307 shell"
  assert_contains "$command" "DECS_KRB_NIS_DOMAIN=\"\$nis_domain\" python3" "sets msSFU attrs through Samba Python"
  assert_contains "$command" 'message["msSFU30NisDomain"]' "sets msSFU NIS domain"
  assert_contains "$command" 'message["msSFU30Name"]' "sets msSFU username"
  assert_contains "$command" "samba-tool domain exportkeytab" "exports keytab"
  assert_contains "$command" "--principal=\"\$principal\"" "exports requested principal"
  assert_contains "$command" "chmod 0400 \"\$keytab_file\"" "locks keytab permissions"
  assert_contains "$command" "klist -kte \"\$keytab_file\"" "validates keytab"

  command="$(build_farm_kerberos_keytab_command "alice" "alice@FARM.DECS.INTERNAL" "/etc/decs-krb/keytabs/alice.keytab" "true" 10123 10124)"
  assert_contains "$command" "samba-tool user setpassword" "rotation resets AD password"
}

test_kerberos_host_refresh_command() {
  KERBEROS_REMOTE_SUDO="sudo -n"
  FARM_KERBEROS_REFRESH_INTERVAL="30min"
  local command
  command="$(build_kerberos_host_refresh_command "alice" 10123 10123 "alice@FARM.DECS.INTERNAL" "/etc/decs-krb/keytabs/alice.keytab" "/run/user/10123" "/run/user/10123/krb5cc" "/etc/decs-krb/refresh.d/alice.env")"
  assert_contains "$command" "tee /usr/local/sbin/decs-krb-refresh" "installs refresh helper"
  assert_contains "$command" "kinit -k -t \"\$DECS_KRB_KEYTAB\" -c \"\$DECS_KRB_CCACHE\" \"\$DECS_KRB_PRINCIPAL\"" "uses keytab for ticket"
  assert_contains "$command" "kinit -R -c \"\$DECS_KRB_CCACHE\"" "renews existing ticket"
  assert_contains "$command" "DECS_KRB_PRINCIPAL='alice@FARM.DECS.INTERNAL'" "writes principal env"
  assert_contains "$command" "DECS_KRB_KEYTAB='/etc/decs-krb/keytabs/alice.keytab'" "writes keytab env"
  assert_contains "$command" "DECS_KRB_CCACHE='FILE:/run/user/10123/krb5cc'" "writes ccache env"
  assert_contains "$command" "OnUnitActiveSec=30min" "uses refresh interval"
  assert_contains "$command" "systemctl enable --now \"decs-krb-refresh@\${instance}.timer\"" "enables timer"
  assert_contains "$command" "systemctl start \"decs-krb-refresh@\${instance}.service\"" "runs initial refresh"
}

test_kerberos_nfs_access_test_command() {
  KERBEROS_REMOTE_SUDO="sudo -n"
  FARM_KERBEROS_NFS_ACCESS_INITIAL_DELAY=7
  FARM_KERBEROS_NFS_ACCESS_RETRIES=3
  FARM_KERBEROS_NFS_ACCESS_RETRY_DELAY=2
  local command
  command="$(build_kerberos_nfs_home_access_test_command "/mnt/nas-krb-test-v4/user-share" "alice" 10123 10123 "/run/user/10123/krb5cc")"
  assert_contains "$command" "command -v setpriv" "requires setpriv"
  assert_contains "$command" "sleep 7" "uses configured initial delay"
  assert_contains "$command" "for attempt in \$(seq 1 3)" "uses configured retry count"
  assert_contains "$command" "sleep 2" "uses configured retry delay"
  assert_contains "$command" "setpriv --reuid=10123 --regid=10123 --clear-groups" "runs as container UID"
  assert_contains "$command" "KRB5CCNAME=\"\$ccache\"" "passes ccache env"
  assert_contains "$command" "printf access-check > \"\$1\" && rm -f \"\$1\"" "uses real write check"
  assert_contains "$command" "kerberos_nfs_access_ok" "reports success"
  assert_contains "$command" "kerberos_nfs_access_failed" "reports failure"
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
test_kerberos_paths
test_prepare_command
test_prepare_command_without_sudo
test_kerberos_prepare_home_command
test_kerberos_ccache_command
test_kerberos_lookup_command
test_kerberos_nas_gss_service_restart_command
test_kerberos_keytab_command
test_kerberos_host_refresh_command
test_kerberos_nfs_access_test_command
test_prepare_invokes_raw_ansible
test_prepare_invokes_raw_ansible_without_key

echo "ok - FARM NAS home tests passed"
