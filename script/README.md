# UID Manager Python CLI

This directory is the Python-first operational track for UID/container
management.

The goal is to keep the existing operational behavior while splitting the work
into testable services:

- container creation, deletion, expiration extension, expired cleanup
- UID/GID, group, supplemental group, and port allocation
- LAB storage root-squash home provisioning
- FARM NAS root-squash home provisioning
- FARM Kerberos AD, keytab, ccache, NFSv4.1, and group sharing preparation
- database backup, export refresh, and email notification hooks
- optional Ansible playbooks for remote state changes

Legacy shell scripts are kept under `legacy/` for rollback and comparison.

## Setup

```bash
cd ~/uid/script
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
pip install -e .
```

## CLI Shape

```bash
uidctl create-container \
  --name "Alice" \
  --username alice \
  --ad-username alice \
  --group project_a \
  --domain FARM \
  --server-number 2 \
  --expiration-date 2026-12-31 \
  --image decs \
  --version krb-e2e-260621 \
  --created-by jy \
  --email alice@example.com \
  --phone 010-0000-0000 \
  --enable-kerberos \
  --enable-vnc \
  --no-db-record \
  --dry-run

uidctl delete-container --server-id FARM2 --username alice --dry-run
uidctl extend-container --username alice --expiration-date 2027-01-31 --apply
uidctl manage-group add-user --group project_a --user alice
uidctl expired-cleanup --domains LAB,FARM --dry-run
uidctl sync-containers --domain FARM --dry-run
```

`--no-db-record` still reads the DB for UID/GID reuse and port planning, then
creates the remote Docker container without writing `user`, `group`,
`used_ids`, `used_ports`, or `docker_container` rows. Creation email is still
sent unless post actions are skipped, but DB backup and export refresh are
omitted because no DB state changed.

`--ad-username` is only valid with `--enable-kerberos`. It changes only the
Kerberos principal/account name; UID/GID remain canonical:

- container identity: `--username`, DB `user.ubuntu_username`,
  `user.ubuntu_uid`, `user.ubuntu_gid`
- Kerberos identity: `--ad-username`, principal
  `<ad_username>@FARM.DECS.INTERNAL`
- AD unix identity: `uidNumber=user.ubuntu_uid`,
  `gidNumber=user.ubuntu_gid`
- FARM NFS identity: the target host must resolve the NFS owner UID to the
  same DB/container UID before DB commit
- home path: still `/volume1/share/user-share/<username>` on NAS and
  `/home/<username>` inside the container

If `--ad-username` is omitted, it defaults to `--username`, which is the normal
case. Use an alias only for exceptional cases such as a NAS-local account name
colliding with an AD username.

Canonical Kerberos UID policy:

```text
DB user.ubuntu_uid == AD uidNumber == FARM NFS returned UID == container UID
```

The script may still look up Synology's internal winbind UID/GID for
`FARM\<ad_username>` while preparing NAS ownership, but that value is not stored
in the DB and is not passed to Docker. If the target FARM host still sees the
home as `nobody` or as a different UID, creation fails before DB writes. Fix the
host/NAS idmap/NSS configuration first, then rerun create-container.

## Why Ansible Still Belongs Here

Python owns validation, DB transactions, planning, and rollback decisions.
Ansible remains useful for remote host state:

- LAB storage and FARM NAS directory provisioning
- FARM NAS GSS/idmap cache refresh
- FARM host shadow identity and ccache directory preparation
- Docker image/container operations through the configured inventory

The playbooks in `playbooks/` are intentionally small. They are reusable
building blocks, not the main business logic.

## Test Strategy

The default tests do not touch LAB storage, FARM/NAS, or Docker. They use fake repositories and
fake remote runners to verify scenarios that previously required risky manual
testing:

- new user, new group, and first container allocation
- existing user with an existing home/container path
- VNC and additional port allocation
- Kerberos ccache/keytab/NAS/NFS plan generation
- same AD group users sharing group metadata
- UID spoofing guardrails through restricted sudo environment generation
- delete, extend, expired cleanup, and sync planning

Real LAB storage and FARM/NAS integration should stay opt-in until the Python path is accepted
as the primary workflow.
