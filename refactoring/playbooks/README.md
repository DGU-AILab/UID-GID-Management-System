# UID Refactoring Playbooks

The Python CLI owns validation, DB transactions, and rollback decisions. These
playbooks are small remote-state helpers that can also be run manually during
debugging.

They should be idempotent where possible and should avoid changing anything
outside the target user/group/share being provisioned.
