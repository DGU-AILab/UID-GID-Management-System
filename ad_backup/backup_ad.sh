#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${AD_BACKUP_CONFIG:-$SCRIPT_DIR/config.local.env}"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
elif [[ -f "$SCRIPT_DIR/config.example.env" ]]; then
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/config.example.env"
fi

AD_BACKUP_INVENTORY="${AD_BACKUP_INVENTORY:-/home/jy/ansible/inventory.ini}"
AD_BACKUP_DCS="${AD_BACKUP_DCS:-farm2 farm6 farm7}"
AD_BACKUP_ROOT="${AD_BACKUP_ROOT:-$SCRIPT_DIR/backups}"
AD_BACKUP_REMOTE_TMP_BASE="${AD_BACKUP_REMOTE_TMP_BASE:-/tmp/decs-ad-backup}"
AD_BACKUP_RETENTION_DAYS="${AD_BACKUP_RETENTION_DAYS:-30}"
AD_BACKUP_SUDO="${AD_BACKUP_SUDO:-sudo -n}"
AD_BACKUP_INCLUDE_KEYTABS="${AD_BACKUP_INCLUDE_KEYTABS:-true}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "required command not found: $1" >&2
    exit 1
  }
}

require_command ansible
require_command sha256sum
require_command tar

timestamp="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$AD_BACKUP_ROOT"

backup_one_dc() {
  local host="$1"
  local local_dir="$AD_BACKUP_ROOT/$host/$timestamp"
  local remote_dir="$AD_BACKUP_REMOTE_TMP_BASE/$timestamp"
  local remote_bundle="$AD_BACKUP_REMOTE_TMP_BASE/decs-ad-backup-${host}-${timestamp}.tar.gz"
  mkdir -p "$local_dir"

  echo "backup_start host=$host timestamp=$timestamp"
  ansible "$host" -i "$AD_BACKUP_INVENTORY" -e ansible_shell_executable=/bin/bash -m shell -a "$(cat <<REMOTE
set -euo pipefail
sudo_cmd=${AD_BACKUP_SUDO@Q}
remote_dir=${remote_dir@Q}
remote_bundle=${remote_bundle@Q}
include_keytabs=${AD_BACKUP_INCLUDE_KEYTABS@Q}
\$sudo_cmd rm -rf "\$remote_dir" "\$remote_bundle"
\$sudo_cmd install -d -m 0700 "\$remote_dir"
\$sudo_cmd sh -c "samba-tool domain info 127.0.0.1 > '\$remote_dir/ad-info.txt' 2>&1 || true"
\$sudo_cmd sh -c "samba-tool drs showrepl > '\$remote_dir/drs-showrepl.txt' 2>&1 || true"
\$sudo_cmd sh -c "samba-tool user list | sort > '\$remote_dir/users.txt' 2>&1 || true"
\$sudo_cmd tar --xattrs --acls -czf "\$remote_dir/samba-private.tar.gz" -C /var/lib/samba private
\$sudo_cmd tar --xattrs --acls -czf "\$remote_dir/samba-sysvol.tar.gz" -C /var/lib/samba sysvol
\$sudo_cmd tar --xattrs --acls -czf "\$remote_dir/etc-samba.tar.gz" -C /etc samba
if [ -f /etc/krb5.conf ]; then
  \$sudo_cmd cp -a /etc/krb5.conf "\$remote_dir/krb5.conf"
fi
if [ "\$include_keytabs" = "true" ] && [ -d /etc/decs-krb/keytabs ]; then
  \$sudo_cmd tar --xattrs --acls -czf "\$remote_dir/decs-krb-keytabs.tar.gz" -C /etc/decs-krb keytabs
fi
\$sudo_cmd sh -c "cd '\$remote_dir' && sha256sum * > manifest.sha256"
\$sudo_cmd tar -czf "\$remote_bundle" -C "\$remote_dir" .
\$sudo_cmd chown "\$(id -u):\$(id -g)" "\$remote_bundle"
echo "remote_bundle=\$remote_bundle"
REMOTE
)"

  ansible "$host" -i "$AD_BACKUP_INVENTORY" -m fetch -a "src=$remote_bundle dest=$local_dir/ flat=yes"
  ansible "$host" -i "$AD_BACKUP_INVENTORY" -e ansible_shell_executable=/bin/bash -m shell -a "${AD_BACKUP_SUDO} rm -rf '$remote_dir' '$remote_bundle'" >/dev/null
  sha256sum "$local_dir/decs-ad-backup-${host}-${timestamp}.tar.gz" > "$local_dir/bundle.sha256"
  echo "backup_done host=$host file=$local_dir/decs-ad-backup-${host}-${timestamp}.tar.gz"
}

for dc in $AD_BACKUP_DCS; do
  backup_one_dc "$dc"
done

find "$AD_BACKUP_ROOT" -type f -name 'decs-ad-backup-*.tar.gz' -mtime +"$AD_BACKUP_RETENTION_DAYS" -print -delete
find "$AD_BACKUP_ROOT" -type f -name 'bundle.sha256' -mtime +"$AD_BACKUP_RETENTION_DAYS" -print -delete
find "$AD_BACKUP_ROOT" -type d -empty -print -delete

echo "backup_all_done timestamp=$timestamp root=$AD_BACKUP_ROOT"
