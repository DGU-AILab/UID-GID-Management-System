from __future__ import annotations

from typing import Iterable, List, Optional

from uid_manager.models import ContainerRecord, GroupRecord, UserRecord
from uid_manager.runners import CommandResult


class FakeRepository:
    def __init__(self) -> None:
        self.users: dict[str, UserRecord] = {}
        self.groups: dict[str, GroupRecord] = {}
        self.supplemental: dict[str, list[int]] = {}
        self.used_id_values: set[int] = set()
        self.used_port_values: set[int] = set()
        self.containers: list[ContainerRecord] = []
        self.pending_ports: dict[int, str] = {}
        self.in_transaction = False
        self.commits = 0
        self.rollbacks = 0

    def ensure_group_membership_schema(self) -> None:
        pass

    def begin(self) -> None:
        self.in_transaction = True

    def commit(self) -> None:
        self.in_transaction = False
        self.commits += 1

    def rollback(self) -> None:
        self.in_transaction = False
        self.rollbacks += 1

    def used_ports(self) -> List[int]:
        return sorted(self.used_port_values)

    def find_user(self, username: str) -> Optional[UserRecord]:
        return self.users.get(username)

    def find_group(self, groupname: str) -> Optional[GroupRecord]:
        return self.groups.get(groupname)

    def next_available_id(self, minimum: int = 10000) -> int:
        values = self.used_id_values | {u.uid for u in self.users.values()} | {g.gid for g in self.groups.values()}
        current = max(values | {minimum - 1})
        return minimum if current < minimum else current + 1

    def reserve_id(self, value: int) -> None:
        self.used_id_values.add(value)

    def insert_group(self, groupname: str, gid: int) -> None:
        self.groups[groupname] = GroupRecord(len(self.groups) + 1, groupname, gid)

    def upsert_user(self, name: str, username: str, uid: int, gid: int, email: str, phone: str, note: str) -> None:
        user_id = self.users[username].id if username in self.users else len(self.users) + 1
        self.users[username] = UserRecord(user_id, name, username, uid, gid, email, phone, note)

    def supplemental_groups(self, username: str, primary_gid: int) -> List[GroupRecord]:
        gids = self.supplemental.get(username, [])
        by_gid = {group.gid: group for group in self.groups.values()}
        return [by_gid[gid] for gid in gids if gid != primary_gid and gid in by_gid]

    def insert_pending_port(self, port: int, purpose: str) -> None:
        self.used_port_values.add(port)
        self.pending_ports[port] = purpose

    def insert_container(self, image: str, version: str, container_id: str, container_name: str, server_id: str, expiring_at: str, created_by: str, username: str) -> int:
        row = ContainerRecord(
            id=len(self.containers) + 1,
            container_id=container_id,
            container_name=container_name,
            server_id=server_id,
            image=image,
            image_version=version,
            username=username,
            name=self.users.get(username, UserRecord(0, "", username, 0, 0)).name,
            email=self.users.get(username, UserRecord(0, "", username, 0, 0)).email,
            expiring_at=expiring_at,
            ports=", ".join(str(port) for port in sorted(self.pending_ports)),
        )
        self.containers.append(row)
        return row.id

    def attach_ports(self, container_db_id: int, ports: Iterable[int]) -> int:
        return len(list(ports))

    def find_container(self, *, server_id: str, container_id: str = "", container_name: str = "", name: str = "", username: str = "", port: Optional[int] = None) -> List[ContainerRecord]:
        rows = [row for row in self.containers if row.server_id == server_id]
        if container_id:
            rows = [row for row in rows if row.container_id.startswith(container_id)]
        if container_name:
            rows = [row for row in rows if row.container_name == container_name]
        if name:
            rows = [row for row in rows if row.name == name]
        if username:
            rows = [row for row in rows if row.username == username]
        if port is not None:
            rows = [row for row in rows if str(port) in row.ports.split(", ")]
        return rows

    def mark_container_deleted(self, container_db_id: int) -> int:
        self.containers = [row for row in self.containers if row.id != container_db_id]
        return 1

    def delete_ports_for_container(self, container_db_id: int) -> int:
        count = len(self.pending_ports)
        self.pending_ports.clear()
        self.used_port_values.clear()
        return count

    def matching_active_containers(self, *, name: str = "", username: str = "", port: Optional[int] = None) -> List[ContainerRecord]:
        rows = list(self.containers)
        if name:
            rows = [row for row in rows if row.name == name]
        if username:
            rows = [row for row in rows if row.username == username]
        if port is not None:
            rows = [row for row in rows if str(port) in row.ports.split(", ")]
        return rows

    def update_expiration(self, container_db_id: int, expiration_date: str) -> int:
        updated = []
        found = False
        for row in self.containers:
            if row.id == container_db_id:
                found = True
                updated.append(ContainerRecord(row.id, row.container_id, row.container_name, row.server_id, row.image, row.image_version, row.username, row.name, row.email, expiration_date, row.ports))
            else:
                updated.append(row)
        self.containers = updated
        return 1 if found else 0

    def expired_containers(self, today: str) -> List[ContainerRecord]:
        return [row for row in self.containers if row.expiring_at < today]

    def active_containers(self) -> List[ContainerRecord]:
        return list(self.containers)

    def list_groups(self) -> List[GroupRecord]:
        return sorted(self.groups.values(), key=lambda group: group.name)

    def set_user_primary_group(self, username: str, gid: int) -> None:
        user = self.users[username]
        self.users[username] = UserRecord(user.id, user.name, user.username, user.uid, gid, user.email, user.phone, user.note)
        self.supplemental[username] = [value for value in self.supplemental.get(username, []) if value != gid]

    def add_supplemental_group(self, username: str, gid: int) -> None:
        self.supplemental.setdefault(username, [])
        if gid not in self.supplemental[username]:
            self.supplemental[username].append(gid)

    def remove_supplemental_group(self, username: str, gid: int) -> None:
        self.supplemental[username] = [value for value in self.supplemental.get(username, []) if value != gid]

    def group_usage_counts(self, gid: int) -> tuple[int, int]:
        primary = sum(1 for user in self.users.values() if user.gid == gid)
        supplemental = sum(1 for gids in self.supplemental.values() if gid in gids)
        return primary, supplemental

    def delete_group(self, gid: int, force: bool = False) -> None:
        if force:
            for username in list(self.supplemental):
                self.supplemental[username] = [value for value in self.supplemental[username] if value != gid]
        for name, group in list(self.groups.items()):
            if group.gid == gid:
                del self.groups[name]


class FakeAnsibleRunner:
    def __init__(self) -> None:
        self.shell_calls: list[tuple[str, str]] = []
        self.raw_calls: list[tuple[str, str]] = []
        self.shell_outputs: list[str] = []
        self.raw_outputs: list[str] = []

    def shell(self, host: str, command: str, check: bool = True) -> CommandResult:
        self.shell_calls.append((host, command))
        stdout = self.shell_outputs.pop(0) if self.shell_outputs else ""
        if "docker run" in command and not stdout:
            stdout = "abc123def4567890\n"
        return CommandResult(["ansible", host], stdout=stdout)

    def raw(self, host: str, command: str, *, user: str, port: int, private_key: str = "", ssh_common_args: str = "", check: bool = True) -> CommandResult:
        self.raw_calls.append((host, command))
        stdout = self.raw_outputs.pop(0) if self.raw_outputs else ""
        return CommandResult(["ansible", host], stdout=stdout)


class FakePostActions:
    def __init__(self) -> None:
        self.created = []
        self.deleted = []
        self.extended = []
        self.backups = []
        self.exports = 0

    def backup_database(self, domain: str) -> None:
        self.backups.append(domain)

    def update_exports(self) -> None:
        self.exports += 1

    def send_created_email(self, args) -> None:
        self.created.append(list(args))

    def send_deleted_email(self, args) -> None:
        self.deleted.append(list(args))

    def send_extended_email(self, args) -> None:
        self.extended.append(list(args))
