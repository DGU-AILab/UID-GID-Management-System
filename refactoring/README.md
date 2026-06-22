# UID Manager Refactoring

This directory is a Python-first replacement track for the UID/container
management shell scripts.

The goal is to keep the existing operational behavior while splitting the work
into testable services:

- container creation, deletion, expiration extension, expired cleanup
- UID/GID, group, supplemental group, and port allocation
- LAB storage root-squash home provisioning
- FARM NAS root-squash home provisioning
- FARM Kerberos AD, keytab, ccache, NFSv4.1, and group sharing preparation
- database backup, export refresh, and email notification hooks
- optional Ansible playbooks for remote state changes

The existing scripts remain in place while this tree is tested.

## Setup

```bash
cd ~/uid/refactoring
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
  --dry-run

uidctl delete-container --server-id FARM2 --username alice --dry-run
uidctl extend-container --username alice --expiration-date 2027-01-31 --apply
uidctl manage-group add-user --group project_a --user alice
uidctl expired-cleanup --domains LAB,FARM --dry-run
uidctl sync-containers --domain FARM --dry-run
```

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
