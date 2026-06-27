from __future__ import annotations

import shlex

from ..config import AppConfig
from .paths import KerberosPaths


def q(value: object) -> str:
    return shlex.quote(str(value))


def storage_plain_home(root: str, username: str) -> str:
    return f"{root.rstrip('/')}/{username}"


def nas_plain_home(root: str, username: str) -> str:
    return storage_plain_home(root, username)


def build_storage_prepare_home_command(home_dir: str, uid: int, gid: int, sudo: str) -> str:
    prefix = f"{sudo} " if sudo else ""
    return "\n".join([
        "set -eu",
        f"{prefix}mkdir -p {q(home_dir)}",
        f"{prefix}chown {q(f'{uid}:{gid}')} {q(home_dir)}",
        f"{prefix}chmod 750 {q(home_dir)}",
    ])


def build_nas_prepare_home_command(home_dir: str, uid: int, gid: int, sudo: str) -> str:
    return build_storage_prepare_home_command(home_dir, uid, gid, sudo)


def build_nas_lookup_identity_command(config: AppConfig, username: str) -> str:
    identity = f"{config.farm_kerberos_ad_netbios}\\{username}"
    return "\n".join([
        "set -eu",
        "wbinfo_bin=/usr/local/packages/@appstore/SMBService/usr/bin/wbinfo",
        f"identity={q(identity)}",
        "if entry=$(\"$wbinfo_bin\" -i \"$identity\" 2>/dev/null); then",
        "  printf '%s\\n' \"$entry\" | awk -F: '{ print $3 \" \" $4 }'",
        "  exit 0",
        "fi",
        "uid=$(id -u \"$identity\")",
        "gid=$(id -g \"$identity\")",
        "printf '%s %s\\n' \"$uid\" \"$gid\"",
    ])


def build_nas_lookup_group_gid_command(config: AppConfig, groupname: str) -> str:
    identity = f"{config.farm_kerberos_ad_netbios}\\{groupname}"
    return "\n".join([
        "set -eu",
        "wbinfo_bin=/usr/local/packages/@appstore/SMBService/usr/bin/wbinfo",
        f"if entry=$(\"$wbinfo_bin\" --group-info {q(identity)} 2>/dev/null); then",
        "  printf '%s\\n' \"$entry\" | awk -F: '{ print $3 }'",
        "  exit 0",
        "fi",
        f"sid_line=$(\"$wbinfo_bin\" --name-to-sid {q(identity)})",
        "sid=$(printf '%s\\n' \"$sid_line\" | awk '{ print $1 }')",
        "\"$wbinfo_bin\" --sid-to-gid \"$sid\"",
    ])


def build_nas_gss_refresh_command(config: AppConfig) -> str:
    sudo = f"{config.farm_nas_sudo} " if config.farm_nas_sudo else ""
    flush_paths = [
        "/proc/net/rpc/auth.unix.gid/flush",
        "/proc/net/rpc/nfs4.idtoname/flush",
        "/proc/net/rpc/nfs4.nametoid/flush",
        "/proc/net/rpc/auth.rpcsec.init/flush",
        "/proc/net/rpc/auth.rpcsec.context/flush",
    ]
    flush_block = " ".join(q(path) for path in flush_paths)
    return "\n".join([
        "set -eu",
        f"svcgssd_bin={q(config.farm_kerberos_nas_svcgssd)}",
        f"idmapd_bin={q(config.farm_kerberos_nas_idmapd)}",
        f"nfs_principal={q(config.farm_kerberos_nas_nfs_principal)}",
        "if [ -n \"$(pidof svcgssd 2>/dev/null || true)\" ]; then",
        f"  {sudo}kill $(pidof svcgssd)",
        "  sleep 1",
        "fi",
        f"{sudo}\"$svcgssd_bin\" -p \"$nfs_principal\"",
        "if [ -n \"$(pidof idmapd 2>/dev/null || true)\" ]; then",
        f"  {sudo}kill $(pidof idmapd)",
        "  sleep 1",
        "fi",
        f"{sudo}\"$idmapd_bin\"",
        "flush_epoch=\"$(date +%s)\"",
        f"for cache_flush in {flush_block}; do",
        "  if [ -e \"$cache_flush\" ]; then",
        f"    printf '%s' \"$flush_epoch\" | {sudo}tee \"$cache_flush\" >/dev/null 2>&1 || true",
        "  fi",
        "done",
        "pidof svcgssd >/dev/null",
        "pidof idmapd >/dev/null",
        "echo kerberos_nas_gss_services_restarted_and_rpc_caches_flushed",
    ])


def build_ad_identity_command(config: AppConfig, username: str, uid: int, groupname: str, gid: int, paths: KerberosPaths, rotate: bool) -> str:
    sudo = f"{config.kerberos_remote_sudo} " if config.kerberos_remote_sudo else ""
    return "\n".join([
        "set -eu",
        f"username={q(username)}",
        f"groupname={q(groupname)}",
        f"principal={q(paths.principal)}",
        f"keytab_file={q(paths.keytab_file)}",
        f"uid={uid}",
        f"gid={gid}",
        f"nis_domain={q(config.farm_kerberos_nis_domain)}",
        f"{sudo}install -d -o root -g root -m 0700 {q(config.farm_kerberos_keytab_dir)}",
        "if [ \"$groupname\" != \"$username\" ]; then",
        f"  {sudo}samba-tool group show \"$groupname\" >/dev/null 2>&1 || {sudo}samba-tool group add \"$groupname\" >/dev/null",
        f"{sudo}env DECS_KRB_GROUPNAME=\"$groupname\" DECS_KRB_GROUP_GID=\"$gid\" DECS_KRB_NIS_DOMAIN=\"$nis_domain\" python3 - <<'PY'",
        "import os",
        "from samba.auth import system_session",
        "from samba.param import LoadParm",
        "from samba.samdb import SamDB",
        "from ldb import FLAG_MOD_REPLACE, Message, MessageElement",
        "groupname = os.environ['DECS_KRB_GROUPNAME']",
        "gid_value = os.environ['DECS_KRB_GROUP_GID']",
        "nis_domain = os.environ['DECS_KRB_NIS_DOMAIN']",
        "lp = LoadParm(); lp.load_default()",
        "samdb = SamDB(url='/var/lib/samba/private/sam.ldb', session_info=system_session(), lp=lp)",
        "result = samdb.search(expression=f'(&(sAMAccountName={groupname})(objectClass=group))', attrs=['distinguishedName'])",
        "if not result:",
        "    raise SystemExit(f'AD group not found: {groupname}')",
        "message = Message(result[0].dn)",
        "message['gidNumber'] = MessageElement(gid_value, FLAG_MOD_REPLACE, 'gidNumber')",
        "message['msSFU30NisDomain'] = MessageElement(nis_domain, FLAG_MOD_REPLACE, 'msSFU30NisDomain')",
        "message['msSFU30Name'] = MessageElement(groupname, FLAG_MOD_REPLACE, 'msSFU30Name')",
        "samdb.modify(message)",
        "PY",
        "fi",
        f"if ! {sudo}samba-tool user show \"$username\" >/dev/null 2>&1; then",
        "  new_password=\"Krb$(date +%y%m%d)!$(tr -dc A-Za-z0-9 </dev/urandom | head -c 24)\"",
        f"  {sudo}samba-tool user create \"$username\" \"$new_password\" >/dev/null",
        f"  {sudo}samba-tool user setexpiry \"$username\" --noexpiry >/dev/null 2>&1 || true",
        f"elif [ {q(str(rotate).lower())} = true ]; then",
        "  new_password=\"Krb$(date +%y%m%d)!$(tr -dc A-Za-z0-9 </dev/urandom | head -c 24)\"",
        f"  {sudo}samba-tool user setpassword \"$username\" --newpassword=\"$new_password\" >/dev/null",
        "fi",
        f"if ! {sudo}samba-tool user show \"$username\" | grep -q '^uidNumber:'; then",
        f"  {sudo}samba-tool user addunixattrs \"$username\" \"$uid\" --gid-number=\"$gid\" --unix-home={q('/home/' + username)} --login-shell=/bin/bash --uid=\"$username\" >/dev/null",
        "fi",
        f"{sudo}env DECS_KRB_USERNAME=\"$username\" DECS_KRB_UID=\"$uid\" DECS_KRB_GID=\"$gid\" DECS_KRB_NIS_DOMAIN=\"$nis_domain\" python3 - <<'PY'",
        "import os",
        "from samba.auth import system_session",
        "from samba.param import LoadParm",
        "from samba.samdb import SamDB",
        "from ldb import FLAG_MOD_REPLACE, Message, MessageElement",
        "username = os.environ['DECS_KRB_USERNAME']",
        "uid_value = os.environ['DECS_KRB_UID']",
        "gid_value = os.environ['DECS_KRB_GID']",
        "nis_domain = os.environ['DECS_KRB_NIS_DOMAIN']",
        "home = f'/home/{username}'",
        "lp = LoadParm(); lp.load_default()",
        "samdb = SamDB(url='/var/lib/samba/private/sam.ldb', session_info=system_session(), lp=lp)",
        "result = samdb.search(expression=f'(sAMAccountName={username})', attrs=['distinguishedName'])",
        "if not result:",
        "    raise SystemExit(f'AD user not found: {username}')",
        "message = Message(result[0].dn)",
        "message['uidNumber'] = MessageElement(uid_value, FLAG_MOD_REPLACE, 'uidNumber')",
        "message['gidNumber'] = MessageElement(gid_value, FLAG_MOD_REPLACE, 'gidNumber')",
        "message['unixHomeDirectory'] = MessageElement(home, FLAG_MOD_REPLACE, 'unixHomeDirectory')",
        "message['loginShell'] = MessageElement('/bin/bash', FLAG_MOD_REPLACE, 'loginShell')",
        "message['msSFU30NisDomain'] = MessageElement(nis_domain, FLAG_MOD_REPLACE, 'msSFU30NisDomain')",
        "message['msSFU30Name'] = MessageElement(username, FLAG_MOD_REPLACE, 'msSFU30Name')",
        "samdb.modify(message)",
        "PY",
        "if [ \"$groupname\" != \"$username\" ]; then",
        f"  {sudo}samba-tool group addmembers \"$groupname\" \"$username\" >/dev/null 2>&1 || {sudo}samba-tool group listmembers \"$groupname\" | grep -Fx \"$username\" >/dev/null",
        "fi",
        "tmp_keytab=\"$(mktemp)\"",
        f"{sudo}samba-tool domain exportkeytab \"$tmp_keytab\" --principal=\"$principal\" >/dev/null",
        f"{sudo}chown root:root \"$tmp_keytab\"",
        f"{sudo}chmod 0400 \"$tmp_keytab\"",
        f"{sudo}mv \"$tmp_keytab\" \"$keytab_file\"",
        f"{sudo}klist -kte \"$keytab_file\" >/dev/null",
        "echo kerberos_ad_identity_ready",
    ])


def build_ad_identity_metadata_command(config: AppConfig, username: str) -> str:
    sudo = f"{config.kerberos_remote_sudo} " if config.kerberos_remote_sudo else ""
    return "\n".join([
        "set -eu",
        f"username={q(username)}",
        f"realm={q(config.farm_kerberos_realm)}",
        f"netbios={q(config.farm_kerberos_ad_netbios)}",
        f"user_info=$({sudo}samba-tool user show \"$username\")",
        "field() { printf '%s\\n' \"$user_info\" | awk -F': ' -v key=\"$1\" '$1 == key { print $2; exit }'; }",
        "object_sid=$(field objectSid)",
        "uid_number=$(field uidNumber)",
        "gid_number=$(field gidNumber)",
        "sam_account=$(field sAMAccountName)",
        "domain_sid=${object_sid%-*}",
        "[ -n \"$object_sid\" ]",
        "[ -n \"$uid_number\" ]",
        "[ -n \"$gid_number\" ]",
        "printf 'ad_username=%s\\n' \"$sam_account\"",
        "printf 'ad_realm=%s\\n' \"$realm\"",
        "printf 'ad_netbios_domain=%s\\n' \"$netbios\"",
        "printf 'ad_domain_sid=%s\\n' \"$domain_sid\"",
        "printf 'ad_object_sid=%s\\n' \"$object_sid\"",
        "printf 'ad_uid_number=%s\\n' \"$uid_number\"",
        "printf 'ad_gid_number=%s\\n' \"$gid_number\"",
    ])


def build_existing_ad_identity_metadata_command(config: AppConfig, username: str) -> str:
    sudo = f"{config.kerberos_remote_sudo} " if config.kerberos_remote_sudo else ""
    return "\n".join([
        "set -eu",
        "# decs_ad_existing_identity_lookup",
        f"username={q(username)}",
        f"if ! {sudo}samba-tool user show \"$username\" >/dev/null 2>&1; then",
        "  exit 0",
        "fi",
        *build_ad_identity_metadata_command(config, username).splitlines()[1:],
    ])


def build_ad_unix_ids_command(config: AppConfig) -> str:
    sudo = f"{config.kerberos_remote_sudo} " if config.kerberos_remote_sudo else ""
    return "\n".join([
        "set -eu",
        f"{sudo}python3 - <<'PY'",
        "from samba.auth import system_session",
        "from samba.param import LoadParm",
        "from samba.samdb import SamDB",
        "lp = LoadParm(); lp.load_default()",
        "samdb = SamDB(url='/var/lib/samba/private/sam.ldb', session_info=system_session(), lp=lp)",
        "for attr, label in [('uidNumber', 'uid'), ('gidNumber', 'gid')]:",
        "    for row in samdb.search(expression=f'({attr}=*)', attrs=[attr]):",
        "        value = row.get(attr)",
        "        if value:",
        "            print(f'{label} {value[0]}')",
        "PY",
    ])


def build_ad_group_command(config: AppConfig, groupname: str, gid: int) -> str:
    sudo = f"{config.kerberos_remote_sudo} " if config.kerberos_remote_sudo else ""
    return "\n".join([
        "set -eu",
        f"groupname={q(groupname)}",
        f"gid={gid}",
        f"nis_domain={q(config.farm_kerberos_nis_domain)}",
        f"{sudo}samba-tool group show \"$groupname\" >/dev/null 2>&1 || {sudo}samba-tool group add \"$groupname\" >/dev/null",
        f"{sudo}env DECS_KRB_GROUPNAME=\"$groupname\" DECS_KRB_GROUP_GID=\"$gid\" DECS_KRB_NIS_DOMAIN=\"$nis_domain\" python3 - <<'PY'",
        "import os",
        "from samba.auth import system_session",
        "from samba.param import LoadParm",
        "from samba.samdb import SamDB",
        "from ldb import FLAG_MOD_REPLACE, Message, MessageElement",
        "groupname = os.environ['DECS_KRB_GROUPNAME']",
        "gid_value = os.environ['DECS_KRB_GROUP_GID']",
        "nis_domain = os.environ['DECS_KRB_NIS_DOMAIN']",
        "lp = LoadParm(); lp.load_default()",
        "samdb = SamDB(url='/var/lib/samba/private/sam.ldb', session_info=system_session(), lp=lp)",
        "result = samdb.search(expression=f'(&(sAMAccountName={groupname})(objectClass=group))', attrs=['distinguishedName'])",
        "if not result:",
        "    raise SystemExit(f'AD group not found: {groupname}')",
        "message = Message(result[0].dn)",
        "message['gidNumber'] = MessageElement(gid_value, FLAG_MOD_REPLACE, 'gidNumber')",
        "message['msSFU30NisDomain'] = MessageElement(nis_domain, FLAG_MOD_REPLACE, 'msSFU30NisDomain')",
        "message['msSFU30Name'] = MessageElement(groupname, FLAG_MOD_REPLACE, 'msSFU30Name')",
        "samdb.modify(message)",
        "PY",
        "echo kerberos_ad_group_ready",
    ])


def build_ad_pull_command(config: AppConfig, destination_host: str, source_host: str) -> str:
    sudo = f"{config.kerberos_remote_sudo} " if config.kerberos_remote_sudo else ""
    destination_fqdn = config.farm_kerberos_ad_dc_fqdn(destination_host)
    source_fqdn = config.farm_kerberos_ad_dc_fqdn(source_host)
    domain_dn = config.farm_kerberos_domain_dn()
    return "\n".join([
        "set -eu",
        f"{sudo}samba-tool drs replicate {q(destination_fqdn)} {q(source_fqdn)} {q(domain_dn)} --local --full-sync -P >/dev/null",
        "echo kerberos_ad_primary_dc_synced",
    ])


def build_host_identity_command(config: AppConfig, username: str, uid: int, groupname: str, gid: int) -> str:
    sudo = f"{config.kerberos_remote_sudo} " if config.kerberos_remote_sudo else ""
    host_group = f"{config.farm_kerberos_ad_netbios}\\{groupname}"
    domain_user = f"{config.farm_kerberos_ad_netbios}\\{username}"
    domain_users_group = f"{config.farm_kerberos_ad_netbios}\\Domain Users"
    return "\n".join([
        "set -eu",
        f"username={q(username)}",
        f"uid={uid}",
        f"host_group={q(host_group)}",
        f"gid={gid}",
        f"domain_user={q(domain_user)}",
        f"domain_users_group={q(domain_users_group)}",
        f"nfs_owner_domain={q(config.farm_kerberos_realm.lower())}",
        "nsswitch_backup=",
        "restore_nsswitch() {",
        "  if [ -n \"${nsswitch_backup:-}\" ] && [ -f \"$nsswitch_backup\" ]; then",
        f"    {sudo}cp \"$nsswitch_backup\" /etc/nsswitch.conf",
        "    rm -f \"$nsswitch_backup\"",
        "    nsswitch_backup=",
        "  fi",
        "}",
        "trap restore_nsswitch EXIT",
        "without_winbind() {",
        "  kind=\"$1\"",
        "  nsswitch_backup=$(mktemp)",
        f"  {sudo}cp /etc/nsswitch.conf \"$nsswitch_backup\"",
        f"  {sudo}sed -i -E \"/^${{kind}}:/ s/[[:space:]]+winbind([[:space:]]|$)/ /g; /^${{kind}}:/ s/[[:space:]]+$//\" /etc/nsswitch.conf",
        "}",
        "ensure_domain_aliases() {",
        "  if ! awk -F: -v user=\"$domain_user\" '$1 == user { found=1 } END { exit found ? 0 : 1 }' /etc/passwd; then",
        f"    {sudo}cp -a /etc/passwd /etc/passwd.decs-idmap-alias-$(date +%Y%m%d%H%M%S)",
        "    printf '%s:x:%s:100::/home/%s:/usr/sbin/nologin\\n' \"$domain_user\" \"$uid\" \"$domain_user\" | "
        f"{sudo}tee -a /etc/passwd >/dev/null",
        "  fi",
        "  if ! awk -F: -v group=\"$domain_users_group\" '$1 == group { found=1 } END { exit found ? 0 : 1 }' /etc/group; then",
        f"    {sudo}cp -a /etc/group /etc/group.decs-idmap-alias-$(date +%Y%m%d%H%M%S)",
        "    printf '%s:x:100:\\n' \"$domain_users_group\" | "
        f"{sudo}tee -a /etc/group >/dev/null",
        "  fi",
        f"  {sudo}cp -a /etc/idmapd.conf /etc/idmapd.conf.decs-idmap-alias-$(date +%Y%m%d%H%M%S)",
        f"  if ! {sudo}grep -q '^\\[Translation\\]' /etc/idmapd.conf; then",
        "    printf '\\n[Translation]\\nMethod = static,nsswitch\\n' | "
        f"{sudo}tee -a /etc/idmapd.conf >/dev/null",
        f"  elif {sudo}grep -q '^Method[[:space:]]*=' /etc/idmapd.conf; then",
        f"    {sudo}sed -i -E 's/^Method[[:space:]]*=.*/Method = static,nsswitch/' /etc/idmapd.conf",
        "  else",
        f"    {sudo}sed -i '/^\\[Translation\\]/a Method = static,nsswitch' /etc/idmapd.conf",
        "  fi",
        f"  if ! {sudo}grep -q '^\\[Static\\]' /etc/idmapd.conf; then",
        "    printf '\\n[Static]\\n' | "
        f"{sudo}tee -a /etc/idmapd.conf >/dev/null",
        "  fi",
        "  add_static() { key=\"$1\"; value=\"$2\"; "
        f"if ! {sudo}grep -Fq \"$key =\" /etc/idmapd.conf; then printf '%s = %s\\n' \"$key\" \"$value\" | {sudo}tee -a /etc/idmapd.conf >/dev/null; fi; "
        "}",
        "  add_static \"${domain_user}@localdomain\" \"$username\"",
        "  add_static \"${domain_user}@${nfs_owner_domain}\" \"$username\"",
        "  add_static \"${domain_users_group}@localdomain\" users",
        "  add_static \"${domain_users_group}@${nfs_owner_domain}\" users",
        "  add_static \"${host_group}@localdomain\" \"$host_group\"",
        "  add_static \"${host_group}@${nfs_owner_domain}\" \"$host_group\"",
        "}",
        "ensure_domain_aliases",
        "local_group_gid=$(awk -F: -v group=\"$host_group\" '$1 == group { print $3; exit }' /etc/group)",
        "if [ -n \"$local_group_gid\" ]; then",
        "  current_gid=\"$local_group_gid\"",
        "  if [ \"$current_gid\" != \"$gid\" ]; then",
        f"    {sudo}groupmod -o -g \"$gid\" \"$host_group\"",
        "  fi",
        "elif getent group \"$host_group\" >/dev/null 2>&1; then",
        "  current_gid=$(getent group \"$host_group\" | awk -F: 'NR==1 { print $3 }')",
        "  without_winbind group",
        "  if awk -F: -v group=\"$host_group\" '$1 == group { found=1 } END { exit found ? 0 : 1 }' /etc/group; then",
        f"    {sudo}groupmod -o -g \"$gid\" \"$host_group\"",
        "  else",
        f"    {sudo}groupadd -o -g \"$gid\" \"$host_group\"",
        "  fi",
        "  restore_nsswitch",
        "else",
        f"  {sudo}groupadd -o -g \"$gid\" \"$host_group\"",
        "fi",
        "local_passwd_uid=$(awk -F: -v user=\"$username\" '$1 == user { print $3; exit }' /etc/passwd)",
        "if [ -n \"$local_passwd_uid\" ]; then",
        "  current_uid=\"$local_passwd_uid\"",
        "  if [ \"$current_uid\" = \"$uid\" ]; then",
        f"    {sudo}usermod -g \"$gid\" \"$username\"",
        "  else",
        "    echo \"WARN existing host user '$username' has uid '$current_uid', expected '$uid'; skipping host user modification\" >&2",
        "  fi",
        "elif getent passwd \"$username\" >/dev/null 2>&1; then",
        "  current_uid=$(getent passwd \"$username\" | awk -F: 'NR==1 { print $3 }')",
        "  if [ \"$current_uid\" != \"$uid\" ]; then",
        "    echo \"WARN NSS user '$username' has uid '$current_uid', expected '$uid'; skipping host user creation\" >&2",
        "  else",
        "    without_winbind passwd",
        f"    {sudo}useradd -o -u \"$uid\" -g \"$gid\" -M -N -s /usr/sbin/nologin \"$username\"",
        "    restore_nsswitch",
        "  fi",
        "else",
        f"  {sudo}useradd -o -u \"$uid\" -g \"$gid\" -M -N -s /usr/sbin/nologin \"$username\"",
        "fi",
        f"command -v nfsidmap >/dev/null 2>&1 && {sudo}nfsidmap -c >/dev/null 2>&1 || true",
        "for cache_flush in /proc/net/rpc/nfs4.idtoname/flush /proc/net/rpc/nfs4.nametoid/flush /proc/net/rpc/auth.unix.gid/flush; do",
        f"  [ -e \"$cache_flush\" ] && echo 0 | {sudo}tee \"$cache_flush\" >/dev/null 2>&1 || true",
        "done",
        "echo kerberos_host_nfs_identity_ready",
    ])


def build_ccache_dir_command(config: AppConfig, paths: KerberosPaths, gid: int) -> str:
    sudo = f"{config.kerberos_remote_sudo} " if config.kerberos_remote_sudo else ""
    return "\n".join([
        "set -eu",
        f"{sudo}install -d -o {paths.uid} -g {gid} -m 0700 {q(paths.ccache_dir)}",
        f"{sudo}chown {q(f'{paths.uid}:{gid}')} {q(paths.ccache_dir)}",
        f"{sudo}chmod 700 {q(paths.ccache_dir)}",
    ])


def build_host_refresh_command(config: AppConfig, username: str, uid: int, gid: int, paths: KerberosPaths) -> str:
    sudo = f"{config.kerberos_remote_sudo} " if config.kerberos_remote_sudo else ""
    refresh_dir = config.farm_kerberos_refresh_env_dir.rstrip("/")
    return "\n".join([
        "set -eu",
        f"{sudo}install -d -o root -g root -m 0755 /etc/decs-krb",
        f"{sudo}install -d -o root -g root -m 0700 {q(refresh_dir)}",
        f"{sudo}install -d -o {uid} -g {gid} -m 0700 {q(paths.ccache_dir)}",
        f"{sudo}tee /usr/local/sbin/decs-krb-refresh >/dev/null <<'DECS_KRB_REFRESH'",
        "#!/bin/bash",
        "set -euo pipefail",
        "env_file=\"${1:?refresh env file is required}\"",
        "source \"$env_file\"",
        "if klist -s -c \"$DECS_KRB_CCACHE\" 2>/dev/null && kinit -R -c \"$DECS_KRB_CCACHE\" >/dev/null 2>&1; then",
        "  :",
        "else",
        "  ccache_path=\"${DECS_KRB_CCACHE#FILE:}\"",
        "  install -d -o \"$DECS_KRB_UID\" -g \"$DECS_KRB_GID\" -m 0700 \"$DECS_KRB_CCACHE_DIR\"",
        "  install -o \"$DECS_KRB_UID\" -g \"$DECS_KRB_GID\" -m 0600 /dev/null \"$ccache_path\"",
        "  kinit -k -t \"$DECS_KRB_KEYTAB\" -c \"$DECS_KRB_CCACHE\" \"$DECS_KRB_PRINCIPAL\"",
        "fi",
        "ccache_path=\"${DECS_KRB_CCACHE#FILE:}\"",
        "chown \"$DECS_KRB_UID:$DECS_KRB_GID\" \"$ccache_path\"",
        "chmod 0600 \"$ccache_path\"",
        "DECS_KRB_REFRESH",
        f"{sudo}chmod 0755 /usr/local/sbin/decs-krb-refresh",
        f"{sudo}tee {q(paths.refresh_env_file)} >/dev/null <<DECS_KRB_ENV",
        f"DECS_KRB_PRINCIPAL={q(paths.principal)}",
        f"DECS_KRB_KEYTAB={q(paths.keytab_file)}",
        f"DECS_KRB_CCACHE={q('FILE:' + paths.ccache_file)}",
        f"DECS_KRB_CCACHE_DIR={q(paths.ccache_dir)}",
        f"DECS_KRB_UID={q(uid)}",
        f"DECS_KRB_GID={q(gid)}",
        "DECS_KRB_ENV",
        f"{sudo}chown root:root {q(paths.refresh_env_file)}",
        f"{sudo}chmod 0600 {q(paths.refresh_env_file)}",
        f"{sudo}tee /etc/systemd/system/decs-krb-refresh@.service >/dev/null <<DECS_KRB_SERVICE",
        "[Unit]",
        "Description=Refresh DECS Kerberos credential cache for %i",
        "[Service]",
        "Type=oneshot",
        f"ExecStart=/usr/local/sbin/decs-krb-refresh {refresh_dir}/%i.env",
        "DECS_KRB_SERVICE",
        f"{sudo}tee /etc/systemd/system/decs-krb-refresh@.timer >/dev/null <<DECS_KRB_TIMER",
        "[Unit]",
        "Description=Refresh DECS Kerberos credential cache for %i",
        "[Timer]",
        "OnBootSec=2min",
        f"OnUnitActiveSec={config.farm_kerberos_refresh_interval}",
        "AccuracySec=5min",
        "Persistent=true",
        "[Install]",
        "WantedBy=timers.target",
        "DECS_KRB_TIMER",
        f"{sudo}systemctl daemon-reload",
        f"{sudo}systemctl enable --now decs-krb-refresh@{username}.timer >/dev/null",
        f"{sudo}systemctl start decs-krb-refresh@{username}.service",
    ])


def build_nfs_access_check_command(config: AppConfig, username: str, uid: int, gid: int, paths: KerberosPaths) -> str:
    sudo = f"{config.kerberos_remote_sudo} " if config.kerberos_remote_sudo else ""
    test_file = f"{paths.host_home}/.decs_kerberos_access_check"
    return "\n".join([
        "set -eu",
        "command -v setpriv >/dev/null",
        f"sleep {config.farm_kerberos_nfs_access_initial_delay}",
        f"for attempt in $(seq 1 {config.farm_kerberos_nfs_access_retries}); do",
        f"  if {sudo}setpriv --reuid={uid} --regid={gid} --clear-groups env KRB5CCNAME={q('FILE:' + paths.ccache_file)} sh -c 'printf access-check > \"$1\" && rm -f \"$1\"' _ {q(test_file)}; then",
        "    echo kerberos_nfs_access_ok attempt=${attempt}",
        "    exit 0",
        "  fi",
        f"  sleep {config.farm_kerberos_nfs_access_retry_delay}",
        "done",
        "echo kerberos_nfs_access_failed >&2",
        "exit 1",
    ])


def build_nfs_owner_uid_check_command(config: AppConfig, uid: int, paths: KerberosPaths) -> str:
    sudo = f"{config.kerberos_remote_sudo} " if config.kerberos_remote_sudo else ""
    return "\n".join([
        "set -eu",
        f"home={q(paths.host_home)}",
        f"expected_uid={uid}",
        "actual_uid=$(" + sudo + "stat -c %u \"$home\")",
        "actual_owner=$(" + sudo + "stat -c '%U:%G' \"$home\" 2>/dev/null || true)",
        "if [ \"$actual_uid\" != \"$expected_uid\" ]; then",
        "  echo \"kerberos_nfs_owner_uid_mismatch home=$home expected_uid=$expected_uid actual_uid=$actual_uid owner=$actual_owner\" >&2",
        "  echo \"FARM host NSS/idmap must map the AD uidNumber to the same DB/container UID before creating this container.\" >&2",
        "  exit 1",
        "fi",
        "echo kerberos_nfs_owner_uid_ok uid=${actual_uid} owner=${actual_owner}",
    ])


def build_nfs_owner_stat_command(config: AppConfig, paths: KerberosPaths) -> str:
    sudo = f"{config.kerberos_remote_sudo} " if config.kerberos_remote_sudo else ""
    return "\n".join([
        "set -eu",
        f"{sudo}stat -c '%u %g' {q(paths.host_home)}",
    ])
