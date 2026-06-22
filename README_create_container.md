# create_container.sh Notes

## LAB Storage Root Squash Provisioning

LAB is not a Synology NAS path. In this repository it is treated as a separate
storage server.

If LAB storage enables root_squash, a container root process cannot create a
new user's home directory on the NFS export. For that case,
`script/create_container.sh` prepares the directory on the storage server
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

## FARM Kerberos NFS Cache Refresh

FARM Kerberos mode is not only a Docker container creation flow. When a new
Kerberos user or AD group is created, Synology NAS and the NFS kernel can keep
old identity/GSS cache entries for a short time. In that state, the NAS may
already show the user with `id FARM\\<username>`, but NFSv4.1 `sec=krb5p`
write can still fail with `Permission denied`.

For this reason, `script/create_container.sh` calls helper code in
`script/common_domain_db.sh` to refresh the NAS-side Kerberos NFS state before
the Docker container and DB rows are finalized.

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
setpriv --reuid=<uid> --regid=<runtime_gid> --clear-groups \
  env KRB5CCNAME=FILE:/run/user/<uid>/krb5cc \
  sh -c 'printf access-check > "$1" && rm -f "$1"' _ \
  /mnt/nas-krb-test-v4/user-share/<username>/.decs_kerberos_access_check
```

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
or inside the container. The current FARM Kerberos flow uses a host-managed
keytab instead.

Flow:

1. `create_container.sh` ensures the AD user/principal exists.
2. A random AD password may be generated or rotated on the Samba AD DC.
3. The script exports a user keytab for the principal.
4. The keytab is stored only on the target FARM host as a root-only file.
5. A systemd refresh service runs `kinit -kt` with that keytab.
6. The service writes a Kerberos credential cache for the container user.
7. The container receives only the ccache bind mount and `KRB5CCNAME`.

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
/run/user/<uid>/                           <uid>:<runtime_gid> 0700
/run/user/<uid>/krb5cc                     <uid>:<runtime_gid> 0600
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
bash script/create_container.sh \
  --enable-kerberos true \
  --rotate-kerberos-keytab true \
  ...
```

Rotation resets the AD user password and exports a fresh keytab. Existing
tickets can remain valid until their normal lifetime expires, so incident
response should consider ticket lifetime and renewable lifetime as well.
