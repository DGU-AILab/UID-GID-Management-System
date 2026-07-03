# Legacy create_container.sh Notes

The primary implementation on this branch lives under `script/` as the Python
`uidctl` CLI. This file records legacy shell behavior that is still kept under
`legacy/script/` for rollback, comparison, and operations that have not yet
fully moved to Python.

## LAB Storage Root Squash Provisioning

LAB is not a Synology NAS path. In this repository it is treated as a separate
storage server.

If LAB storage enables root_squash, a container root process cannot create a
new user's home directory on the NFS export. For that case,
`legacy/script/create_container.sh` prepares the directory on the storage server
before creating the Docker container or DB rows.

The LAB flow uses raw Ansible SSH to run:

```bash
mkdir -p /294t/dcloud/share/user-share/<username>
chown <uid>:<gid> /294t/dcloud/share/user-share/<username>
chmod 750 /294t/dcloud/share/user-share/<username>
```

Default settings:

```text
LAB_STORAGE_HOST=192.168.1.20
LAB_STORAGE_PORT=6953
LAB_STORAGE_USER=jy
LAB_STORAGE_USER_SHARE_ROOT=/294t/dcloud/share/user-share
LAB_STORAGE_SUDO="sudo -n"
LAB_HOST_USER_SHARE_ROOT_TEMPLATE=/home/tako{server_number}/share/user-share
```

`LAB_STORAGE_USER_SHARE_ROOT` is the real path on the storage server.
`LAB_HOST_USER_SHARE_ROOT_TEMPLATE` is the NFS mount path seen by each LAB
Docker host and is what gets bind-mounted into the container as `/home`.

If storage SSH must go through a jump host, set:

```text
LAB_STORAGE_SSH_COMMON_ARGS="-o ProxyJump=jy@192.168.1.12:8082"
```

## LAB Kerberos NFS PoC

LAB Kerberos mode is separate from the normal LAB root_squash path above. The
current PoC uses a dedicated storage export instead of the operational LAB
share:

```text
storage path: /294t/share/test-krb/user-share
LAB2 mount:   /mnt/decs-lab-test-krb/user-share
realm:        LAB.DECS.INTERNAL
NFS mode:     NFSv4.1 sec=krb5p root_squash
```

`uidctl create-container --domain LAB --enable-kerberos` performs the following
before Docker/DB finalization:

1. Creates or reuses the Samba AD user/group on the LAB AD DC with the DB
   UID/GID stored as RFC2307 attributes.
2. Exports a user keytab on the LAB AD DC, then installs a root-only copy on
   the target LAB host.
3. Creates or repairs the LAB storage home through storage SSH and sets the
   owner to the selected UID/GID.
4. Verifies that the target LAB host resolves the AD user/group through NSS and
   refreshes NFSv4 idmap/RPC caches.
5. Installs the same host ticket refresh service used by FARM, writing the
   ccache at `/run/user/<uid>/krb5cc`.
6. Runs a real NFS write check through the LAB host mount before creating the
   Docker container or DB rows.

Related settings:

```text
LAB_KERBEROS_REALM=LAB.DECS.INTERNAL
LAB_KERBEROS_AD_NETBIOS=LAB
LAB_KERBEROS_NIS_DOMAIN=lab
LAB_KERBEROS_AD_DC_HOST=lab2
LAB_KERBEROS_STORAGE_USER_SHARE_ROOT=/294t/share/test-krb/user-share
LAB_KERBEROS_MOUNT_USER_SHARE_ROOT=/mnt/decs-lab-test-krb/user-share
LAB_KERBEROS_CCACHE_BASE=/run/user
LAB_KERBEROS_KRB5_CONF=/etc/krb5.conf
LAB_KERBEROS_KEYTAB_DIR=/etc/decs-krb/keytabs
LAB_KERBEROS_REFRESH_ENV_DIR=/etc/decs-krb/refresh.d
```

For `group-dir-share` to work cleanly over LAB NFSv4.1, both LAB storage and
the LAB Docker host must use the same NFSv4 idmap domain:

```ini
[General]
Domain = lab.decs.internal
```

Without this, host-managed Kerberos tickets can still read/write the user home,
but NFSv4 owner/group names may appear as `nobody`/`nogroup`, and user-level
`chgrp` can fail with `Invalid argument`. Because this is a global NFSv4 idmap
setting on the storage server, it should be changed only after checking the
impact on existing LAB NFS clients.

## FARM Kerberos NFS Cache Refresh

FARM Kerberos mode is not only a Docker container creation flow. When a new
Kerberos user or AD group is created, Synology NAS and the NFS kernel can keep
old identity/GSS cache entries for a short time. In that state, the NAS may
already show the user with `id FARM\\<username>`, but NFSv4 `sec=krb5p`
write can still fail with `Permission denied`.

For this reason, the Python `uidctl create-container --enable-kerberos` flow
and the legacy shell flow refresh the NAS-side Kerberos NFS state before the
Docker container and DB rows are finalized.

The refresh does the following through NAS SSH:

```bash
kill $(pidof svcgssd)
/usr/sbin/svcgssd -p nfs/nas.farm.decs.internal@FARM.DECS.INTERNAL

kill $(pidof idmapd)
/usr/sbin/idmapd
```

It also flushes NAS kernel RPC/NFS identity caches by writing the current epoch
timestamp to:

```text
/proc/net/rpc/auth.unix.gid/flush
/proc/net/rpc/nfs4.idtoname/flush
/proc/net/rpc/nfs4.nametoid/flush
/proc/net/rpc/auth.rpcsec.init/flush
/proc/net/rpc/auth.rpcsec.context/flush
```

These are kernel cache-control interfaces, not persistent NAS configuration
files. The operation does not change share permissions, but it can briefly
affect active Kerberos NFS sessions because `svcgssd` and `idmapd` are
restarted.

The create flow then performs a real NFS write check on the target FARM host:

```bash
setpriv --reuid=<uid> --regid=<gid> --clear-groups \
  env KRB5CCNAME=FILE:/run/user/<uid>/krb5cc \
  sh -c 'printf access-check > "$1" && rm -f "$1"' _ \
/home/tako<server_number>/share/user-share/<username>/.decs_kerberos_access_check
```

Current FARM hosts mount:

```text
nas.farm.decs.internal:/volume1/share -> /home/takoN/share
options: vers=4.0,sec=krb5p,addr=100.100.100.120
container home bind root: /home/takoN/share/user-share
NAS home root: /volume1/share/user-share
```

`FARM_KERBEROS_MOUNT_USER_SHARE_ROOT` may use the `{server_number}` placeholder,
for example `/home/tako{server_number}/share/user-share`.

Before the write check, the create flow also verifies that the target FARM host
sees the NFS home owner UID as the same DB/container UID. If the home is still
`nobody` or a different idmap UID, creation is aborted before DB writes.

If the first write check fails, `create_container.sh` refreshes the NAS
GSS/RPC caches one more time and retries. If the second write check also fails,
container creation is aborted before the Docker container and DB transaction
are finalized.

Related environment knobs:

```text
FARM_KERBEROS_NAS_RESTART_GSS_SERVICES=true
FARM_KERBEROS_NAS_SVCGSSD=/usr/sbin/svcgssd
FARM_KERBEROS_NAS_IDMAPD=/usr/sbin/idmapd
FARM_KERBEROS_NAS_NFS_PRINCIPAL=nfs/nas.farm.decs.internal@FARM.DECS.INTERNAL
FARM_KERBEROS_NFS_ACCESS_INITIAL_DELAY=30
FARM_KERBEROS_NFS_ACCESS_RETRIES=12
FARM_KERBEROS_NFS_ACCESS_RETRY_DELAY=5
```

## Kerberos Group Sharing Command

Inside a Kerberos-enabled DECS container, users share a directory under their
own home with an AD group using:

```bash
group-dir-share ~/sharing_dir <group>
```

The command is created by the DECS image entrypoint in Kerberos mode. It
creates the directory if needed, validates that the current user belongs to the
group, then applies group ownership, `2770` permissions, and ACLs for parent
traversal/default group access when `setfacl` is available.

## Kerberos Ticket Secret Storage

`create_container.sh` should not store a user's Kerberos password in the UID DB
or inside the container. The current Samba AD Kerberos flow uses a host-managed
keytab instead.

Flow:

1. `create_container.sh` ensures the AD user/principal exists.
2. A random AD password may be generated or rotated on the Samba AD DC.
3. The script exports a user keytab for the principal.
4. The keytab is stored only on the target Docker host as a root-only file.
5. A systemd refresh service runs `kinit -kt` with that keytab.
6. The service writes a Kerberos credential cache for the container user.
7. The container receives only the ccache bind mount and `KRB5CCNAME`.

The refresh timer runs every 1 hour by default. On each run,
`decs-krb-refresh` checks the existing ccache. If the Kerberos `renew until`
deadline is more than 24 hours away, it uses `kinit -R`; if the deadline is
within 24 hours, missing, or renewal fails, it reissues a fresh ccache from the
root-only keytab. The margin defaults to `86400` seconds and can be overridden
per user with `DECS_KRB_REISSUE_BEFORE_SECONDS` in
`/etc/decs-krb/refresh.d/<username>.env`.

Important paths:

```text
/etc/decs-krb/keytabs/<username>.keytab
/etc/decs-krb/refresh.d/<username>.env
/run/user/<uid>/krb5cc
```

Expected permissions:

```text
/etc/decs-krb/keytabs/<username>.keytab    root:root 0400
/etc/decs-krb/refresh.d/<username>.env     root:root 0600
/run/user/<uid>/                           <uid>:<gid> 0700
/run/user/<uid>/krb5cc                     <uid>:<gid> 0600
```

The DB should only keep non-secret metadata if needed, such as:

```text
kerberos_enabled
kerberos_principal
keytab_rotated_at
```

Do not store:

```text
AD password
Kerberos password
keytab file content
ccache file content
```

Security notes:

- A keytab is effectively a password-equivalent secret for that Kerberos
  principal. If it leaks, rotate the AD password/keytab.
- The container should not receive the keytab. It only needs the ccache.
- The ccache is short-lived ticket material. It is less permanent than a
  keytab, but still sensitive while valid.
- Root on the target FARM host can access keytabs and ccaches. This design
  assumes FARM host root/admin compromise is out of scope for user isolation.
- `DECS_USER_SUDO_MODE=restricted` is used so normal container users cannot
  become root and spoof another UID to make host `rpc.gssd` use another
  user's ccache.

Rotation:

```bash
bash legacy/script/create_container.sh \
  --enable-kerberos true \
  --rotate-kerberos-keytab true \
  ...
```

Rotation resets the AD user password and exports a fresh keytab. Existing
tickets can remain valid until their normal lifetime expires, so incident
response should consider ticket lifetime and renewable lifetime as well.

## DB Record Skip Mode

Both the Python `uidctl create-container` flow and the legacy shell
`legacy/script/create_container.sh` support:

```bash
--no-db-record
```

This mode still reads the DB for existing UID/GID reuse and port planning, then
creates the remote Docker container without inserting or updating `user`,
`group`, `used_ids`, `used_ports`, or `docker_container` rows.

Because no DB state is written, the flow skips DB backup and Excel/Google
Sheets export refresh. It is intended for short-lived tests where a container
must be created without appearing in the UID DB.

The create notification email is still sent in this mode so the test user can
receive SSH/Jupyter/VNC connection details.
