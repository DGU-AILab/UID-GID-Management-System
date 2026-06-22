from __future__ import annotations

from contextlib import contextmanager
from typing import Iterable, List, Optional, Protocol

from .config import AppConfig
from .models import ContainerRecord, GroupRecord, UserRecord


class Repository(Protocol):
    def ensure_group_membership_schema(self) -> None: ...
    def begin(self) -> None: ...
    def commit(self) -> None: ...
    def rollback(self) -> None: ...
    def used_ports(self) -> List[int]: ...
    def find_user(self, username: str) -> Optional[UserRecord]: ...
    def find_group(self, groupname: str) -> Optional[GroupRecord]: ...
    def next_available_id(self, minimum: int = 10000) -> int: ...
    def reserve_id(self, value: int) -> None: ...
    def insert_group(self, groupname: str, gid: int) -> None: ...
    def upsert_user(self, name: str, username: str, uid: int, gid: int, email: str, phone: str, note: str) -> None: ...
    def supplemental_groups(self, username: str, primary_gid: int) -> List[GroupRecord]: ...
    def insert_pending_port(self, port: int, purpose: str) -> None: ...
    def insert_container(self, image: str, version: str, container_id: str, container_name: str, server_id: str, expiring_at: str, created_by: str, username: str) -> int: ...
    def attach_ports(self, container_db_id: int, ports: Iterable[int]) -> int: ...
    def find_container(self, *, server_id: str, container_id: str = "", container_name: str = "", name: str = "", username: str = "", port: Optional[int] = None) -> List[ContainerRecord]: ...
    def mark_container_deleted(self, container_db_id: int) -> int: ...
    def delete_ports_for_container(self, container_db_id: int) -> int: ...
    def matching_active_containers(self, *, name: str = "", username: str = "", port: Optional[int] = None) -> List[ContainerRecord]: ...
    def update_expiration(self, container_db_id: int, expiration_date: str) -> int: ...
    def expired_containers(self, today: str) -> List[ContainerRecord]: ...
    def active_containers(self) -> List[ContainerRecord]: ...
    def list_groups(self) -> List[GroupRecord]: ...
    def set_user_primary_group(self, username: str, gid: int) -> None: ...
    def add_supplemental_group(self, username: str, gid: int) -> None: ...
    def remove_supplemental_group(self, username: str, gid: int) -> None: ...
    def group_usage_counts(self, gid: int) -> tuple[int, int]: ...
    def delete_group(self, gid: int, force: bool = False) -> None: ...


class MySqlRepository:
    def __init__(self, config: AppConfig, domain: str) -> None:
        import pymysql

        self.config = config
        self.domain = domain
        self.connection = pymysql.connect(
            host=config.db_host_for_domain(domain),
            port=config.db_port,
            user=config.db_user,
            password=config.db_password,
            database=config.db_name,
            charset=config.db_charset,
            autocommit=True,
            cursorclass=pymysql.cursors.DictCursor,
        )

    def close(self) -> None:
        self.connection.close()

    @contextmanager
    def cursor(self):
        with self.connection.cursor() as cursor:
            yield cursor

    def begin(self) -> None:
        self.connection.autocommit(False)
        with self.cursor() as cursor:
            cursor.execute("START TRANSACTION")

    def commit(self) -> None:
        self.connection.commit()
        self.connection.autocommit(True)

    def rollback(self) -> None:
        self.connection.rollback()
        self.connection.autocommit(True)

    def ensure_group_membership_schema(self) -> None:
        with self.cursor() as cursor:
            cursor.execute(
                """
                CREATE TABLE IF NOT EXISTS user_group_membership (
                  id INT PRIMARY KEY AUTO_INCREMENT,
                  ubuntu_uid INT NOT NULL,
                  ubuntu_gid INT NOT NULL,
                  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                  UNIQUE KEY unique_user_group_membership (ubuntu_uid, ubuntu_gid),
                  FOREIGN KEY (ubuntu_uid) REFERENCES user (ubuntu_uid),
                  FOREIGN KEY (ubuntu_gid) REFERENCES `group` (ubuntu_gid)
                ) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci
                """
            )

    def used_ports(self) -> List[int]:
        with self.cursor() as cursor:
            cursor.execute("SELECT port_number FROM used_ports")
            return [int(row["port_number"]) for row in cursor.fetchall()]

    def find_user(self, username: str) -> Optional[UserRecord]:
        with self.cursor() as cursor:
            cursor.execute("SELECT * FROM user WHERE ubuntu_username=%s", [username])
            row = cursor.fetchone()
        if not row:
            return None
        return UserRecord(row["id"], row["name"], row["ubuntu_username"], row["ubuntu_uid"], row["ubuntu_gid"], row.get("email") or "", row.get("phone") or "", row.get("note") or "")

    def find_group(self, groupname: str) -> Optional[GroupRecord]:
        with self.cursor() as cursor:
            cursor.execute("SELECT * FROM `group` WHERE ubuntu_groupname=%s", [groupname])
            row = cursor.fetchone()
        if not row:
            return None
        return GroupRecord(row["id"], row["ubuntu_groupname"], row["ubuntu_gid"])

    def next_available_id(self, minimum: int = 10000) -> int:
        with self.cursor() as cursor:
            cursor.execute("SELECT COALESCE(MAX(id), %s) AS max_id FROM used_ids", [minimum - 1])
            max_id = int(cursor.fetchone()["max_id"])
        return minimum if max_id < minimum else max_id + 1

    def reserve_id(self, value: int) -> None:
        with self.cursor() as cursor:
            cursor.execute("INSERT INTO used_ids (id) VALUES (%s)", [value])

    def insert_group(self, groupname: str, gid: int) -> None:
        with self.cursor() as cursor:
            cursor.execute("INSERT INTO `group` (ubuntu_groupname, ubuntu_gid) VALUES (%s, %s)", [groupname, gid])

    def upsert_user(self, name: str, username: str, uid: int, gid: int, email: str, phone: str, note: str) -> None:
        if self.find_user(username):
            with self.cursor() as cursor:
                cursor.execute(
                    "UPDATE user SET name=%s, ubuntu_gid=%s, email=%s, phone=%s, note=%s WHERE ubuntu_uid=%s",
                    [name, gid, email, phone, note, uid],
                )
        else:
            with self.cursor() as cursor:
                cursor.execute(
                    "INSERT INTO user (name, ubuntu_username, ubuntu_uid, ubuntu_gid, email, phone, note) VALUES (%s, %s, %s, %s, %s, %s, %s)",
                    [name, username, uid, gid, email, phone, note],
                )

    def supplemental_groups(self, username: str, primary_gid: int) -> List[GroupRecord]:
        with self.cursor() as cursor:
            cursor.execute(
                """
                SELECT g.id, g.ubuntu_groupname, g.ubuntu_gid
                FROM user_group_membership ugm
                JOIN user u ON u.ubuntu_uid = ugm.ubuntu_uid
                JOIN `group` g ON g.ubuntu_gid = ugm.ubuntu_gid
                WHERE u.ubuntu_username=%s AND g.ubuntu_gid <> %s
                ORDER BY g.ubuntu_groupname
                """,
                [username, primary_gid],
            )
            rows = cursor.fetchall()
        return [GroupRecord(row["id"], row["ubuntu_groupname"], row["ubuntu_gid"]) for row in rows]

    def insert_pending_port(self, port: int, purpose: str) -> None:
        with self.cursor() as cursor:
            cursor.execute("INSERT INTO used_ports (port_number, purpose_of_use) VALUES (%s, %s)", [port, purpose])

    def insert_container(self, image: str, version: str, container_id: str, container_name: str, server_id: str, expiring_at: str, created_by: str, username: str) -> int:
        with self.cursor() as cursor:
            cursor.execute(
                """
                INSERT INTO docker_container (image, image_version, container_id, container_name, server_id, expiring_at, created_by, user_id)
                VALUES (%s, %s, %s, %s, %s, %s, %s, (SELECT id FROM user WHERE ubuntu_username=%s))
                """,
                [image, version, container_id, container_name, server_id, expiring_at, created_by, username],
            )
            return int(cursor.lastrowid)

    def attach_ports(self, container_db_id: int, ports: Iterable[int]) -> int:
        ports = list(ports)
        if not ports:
            return 0
        placeholders = ",".join(["%s"] * len(ports))
        with self.cursor() as cursor:
            cursor.execute(f"UPDATE used_ports SET docker_container_record_id=%s WHERE port_number IN ({placeholders})", [container_db_id, *ports])
            return int(cursor.rowcount)

    def find_container(self, *, server_id: str, container_id: str = "", container_name: str = "", name: str = "", username: str = "", port: Optional[int] = None) -> List[ContainerRecord]:
        where = ["dc.existing = 1", "dc.server_id = %s"]
        params: List[object] = [server_id]
        if container_id:
            where.append("dc.container_id LIKE %s")
            params.append(f"{container_id}%")
        if container_name:
            where.append("dc.container_name = %s")
            params.append(container_name)
        if name:
            where.append("u.name = %s")
            params.append(name)
        if username:
            where.append("u.ubuntu_username = %s")
            params.append(username)
        if port is not None:
            where.append("EXISTS (SELECT 1 FROM used_ports up_filter WHERE up_filter.docker_container_record_id=dc.id AND up_filter.port_number=%s)")
            params.append(port)
        return self._container_query(where, params)

    def matching_active_containers(self, *, name: str = "", username: str = "", port: Optional[int] = None) -> List[ContainerRecord]:
        where = ["dc.existing = 1"]
        params: List[object] = []
        if name:
            where.append("u.name = %s")
            params.append(name)
        if username:
            where.append("u.ubuntu_username = %s")
            params.append(username)
        if port is not None:
            where.append("EXISTS (SELECT 1 FROM used_ports up_filter WHERE up_filter.docker_container_record_id=dc.id AND up_filter.port_number=%s)")
            params.append(port)
        return self._container_query(where, params)

    def _container_query(self, where: List[str], params: List[object]) -> List[ContainerRecord]:
        with self.cursor() as cursor:
            cursor.execute(
                f"""
                SELECT dc.id, dc.container_id, dc.container_name, dc.server_id, dc.image, dc.image_version,
                       DATE_FORMAT(dc.expiring_at, '%%Y-%%m-%%d') AS expiring_at,
                       u.name, u.ubuntu_username, u.ubuntu_uid, u.ubuntu_gid, COALESCE(u.email, '') AS email,
                       IFNULL(GROUP_CONCAT(up.port_number ORDER BY up.port_number SEPARATOR ', '), '') AS ports,
                       IFNULL(GROUP_CONCAT(CONCAT(up.port_number, ':', up.purpose_of_use) ORDER BY up.port_number SEPARATOR '|'), '') AS port_specs
                FROM docker_container dc
                JOIN user u ON u.id = dc.user_id
                LEFT JOIN used_ports up ON up.docker_container_record_id = dc.id
                WHERE {" AND ".join(where)}
                GROUP BY dc.id, dc.container_id, dc.container_name, dc.server_id, dc.image, dc.image_version, dc.expiring_at, u.name, u.ubuntu_username, u.ubuntu_uid, u.ubuntu_gid, u.email
                ORDER BY dc.container_name ASC
                """,
                params,
            )
            rows = cursor.fetchall()
        return [
            ContainerRecord(row["id"], row["container_id"], row["container_name"], row["server_id"], row["image"], row["image_version"], row["ubuntu_username"], row["name"], row["email"], row["expiring_at"], row["ports"], row["ubuntu_uid"], row["ubuntu_gid"], row["port_specs"])
            for row in rows
        ]

    def mark_container_deleted(self, container_db_id: int) -> int:
        with self.cursor() as cursor:
            cursor.execute("UPDATE docker_container SET existing=0, deleted_at=NOW() WHERE id=%s", [container_db_id])
            return int(cursor.rowcount)

    def delete_ports_for_container(self, container_db_id: int) -> int:
        with self.cursor() as cursor:
            cursor.execute("DELETE FROM used_ports WHERE docker_container_record_id=%s", [container_db_id])
            return int(cursor.rowcount)

    def update_expiration(self, container_db_id: int, expiration_date: str) -> int:
        with self.cursor() as cursor:
            cursor.execute("UPDATE docker_container SET expiring_at=%s WHERE id=%s", [expiration_date, container_db_id])
            return int(cursor.rowcount)

    def expired_containers(self, today: str) -> List[ContainerRecord]:
        where = ["dc.existing = 1", "DATE(dc.expiring_at) < DATE(%s)"]
        return self._container_query(where, [today])

    def active_containers(self) -> List[ContainerRecord]:
        return self._container_query(["dc.existing = 1"], [])

    def list_groups(self) -> List[GroupRecord]:
        with self.cursor() as cursor:
            cursor.execute("SELECT id, ubuntu_groupname, ubuntu_gid FROM `group` ORDER BY ubuntu_groupname")
            rows = cursor.fetchall()
        return [GroupRecord(row["id"], row["ubuntu_groupname"], row["ubuntu_gid"]) for row in rows]

    def set_user_primary_group(self, username: str, gid: int) -> None:
        user = self.find_user(username)
        if not user:
            raise ValueError(f"user not found: {username}")
        with self.cursor() as cursor:
            cursor.execute("UPDATE user SET ubuntu_gid=%s WHERE ubuntu_username=%s", [gid, username])
            cursor.execute("DELETE FROM user_group_membership WHERE ubuntu_uid=%s AND ubuntu_gid=%s", [user.uid, gid])

    def add_supplemental_group(self, username: str, gid: int) -> None:
        user = self.find_user(username)
        if not user:
            raise ValueError(f"user not found: {username}")
        with self.cursor() as cursor:
            cursor.execute("INSERT IGNORE INTO user_group_membership (ubuntu_uid, ubuntu_gid) VALUES (%s, %s)", [user.uid, gid])

    def remove_supplemental_group(self, username: str, gid: int) -> None:
        user = self.find_user(username)
        if not user:
            raise ValueError(f"user not found: {username}")
        with self.cursor() as cursor:
            cursor.execute("DELETE FROM user_group_membership WHERE ubuntu_uid=%s AND ubuntu_gid=%s", [user.uid, gid])

    def group_usage_counts(self, gid: int) -> tuple[int, int]:
        with self.cursor() as cursor:
            cursor.execute("SELECT COUNT(*) AS count FROM user WHERE ubuntu_gid=%s", [gid])
            primary = int(cursor.fetchone()["count"])
            cursor.execute("SELECT COUNT(*) AS count FROM user_group_membership WHERE ubuntu_gid=%s", [gid])
            supplemental = int(cursor.fetchone()["count"])
        return primary, supplemental

    def delete_group(self, gid: int, force: bool = False) -> None:
        with self.cursor() as cursor:
            if force:
                cursor.execute("DELETE FROM user_group_membership WHERE ubuntu_gid=%s", [gid])
            cursor.execute("DELETE FROM `group` WHERE ubuntu_gid=%s", [gid])
