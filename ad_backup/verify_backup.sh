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

AD_BACKUP_ROOT="${AD_BACKUP_ROOT:-$SCRIPT_DIR/backups}"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

found=0
while IFS= read -r bundle; do
  found=1
  work="$tmp_root/$(basename "$bundle" .tar.gz)"
  mkdir -p "$work"
  echo "verify_start file=$bundle"
  tar -tzf "$bundle" >/dev/null
  tar -xzf "$bundle" -C "$work"
  for required in manifest.sha256 samba-private.tar.gz samba-sysvol.tar.gz etc-samba.tar.gz ad-info.txt drs-showrepl.txt users.txt; do
    [[ -e "$work/$required" ]] || {
      echo "missing required backup member: $required in $bundle" >&2
      exit 1
    }
  done
  (cd "$work" && sha256sum -c manifest.sha256 >/dev/null)
  echo "verify_ok file=$bundle"
done < <(find "$AD_BACKUP_ROOT" -type f -name 'decs-ad-backup-*.tar.gz' | sort)

if [[ "$found" -eq 0 ]]; then
  echo "no backup bundles found under $AD_BACKUP_ROOT" >&2
  exit 1
fi

echo "verify_all_ok root=$AD_BACKUP_ROOT"
