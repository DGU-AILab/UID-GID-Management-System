from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence


@dataclass(frozen=True)
class UserRecord:
    id: int
    name: str
    username: str
    uid: int
    gid: int
    email: str = ""
    phone: str = ""
    note: str = ""


@dataclass(frozen=True)
class GroupRecord:
    id: int
    name: str
    gid: int


@dataclass(frozen=True)
class KerberosIdentityRecord:
    username: str
    ad_username: str
    ad_realm: str
    ad_netbios_domain: str
    ad_domain_sid: str
    ad_object_sid: str
    ad_uid_number: int
    ad_gid_number: int
    last_seen_nas_internal_uid: int = 0
    last_seen_nas_internal_gid: int = 0
    last_seen_nfs_uid: int = 0
    last_seen_nfs_gid: int = 0
    last_verified_at: str = ""


@dataclass(frozen=True)
class ContainerRecord:
    id: int
    container_id: str
    container_name: str
    server_id: str
    image: str = ""
    image_version: str = ""
    username: str = ""
    name: str = ""
    email: str = ""
    expiring_at: str = ""
    ports: str = ""
    uid: int = 0
    gid: int = 0
    port_specs: str = ""


@dataclass(frozen=True)
class PortMapping:
    host_port: int
    container_port: int
    purpose: str

    def docker_arg(self) -> str:
        return f"-p {self.host_port}:{self.container_port}"


@dataclass
class OperationPlan:
    title: str
    facts: Dict[str, str] = field(default_factory=dict)
    steps: List[str] = field(default_factory=list)
    commands: List[str] = field(default_factory=list)

    def add_step(self, step: str) -> None:
        self.steps.append(step)

    def add_command(self, command: str) -> None:
        self.commands.append(command)

    def set_fact(self, key: str, value: object) -> None:
        self.facts[key] = str(value)

    def render(self) -> str:
        lines = [self.title]
        if self.facts:
            lines.append("")
            lines.append("Facts:")
            for key, value in self.facts.items():
                lines.append(f"  {key}: {value}")
        if self.steps:
            lines.append("")
            lines.append("Steps:")
            for index, step in enumerate(self.steps, start=1):
                lines.append(f"  {index}. {step}")
        if self.commands:
            lines.append("")
            lines.append("Commands:")
            for command in self.commands:
                lines.append(f"  $ {command}")
        return "\n".join(lines)


@dataclass
class CreateContainerRequest:
    name: str
    username: str
    groupname: Optional[str]
    domain: str
    server_number: int
    expiration_date: str
    image: str
    version: str
    container_name: Optional[str]
    additional_ports: Sequence[int] = field(default_factory=list)
    fixed_ports: Sequence[PortMapping] = field(default_factory=list)
    enable_vnc: bool = False
    enable_kerberos: bool = False
    ad_username: Optional[str] = None
    rotate_kerberos_keytab: bool = False
    created_by: str = ""
    email: str = ""
    phone: str = ""
    note: str = ""
    user_password: Optional[str] = None
    vnc_password: Optional[str] = None
    dry_run: bool = False
    skip_post_actions: bool = False
    no_db_record: bool = False


@dataclass
class CreateContainerResult:
    container_id: str
    container_name: str
    uid: int
    gid: int
    runtime_gid: int
    server_id: str
    target_host: str
    ports: List[PortMapping]
    plan: OperationPlan


@dataclass
class DeleteContainerRequest:
    domain: str
    server_number: int
    container_id: str = ""
    container_name: str = ""
    filter_name: str = ""
    filter_username: str = ""
    filter_port: Optional[int] = None
    force: bool = False
    dry_run: bool = False
    skip_post_actions: bool = False


@dataclass
class ExtendContainerRequest:
    expiration_date: str
    name: str = ""
    username: str = ""
    port: Optional[int] = None
    domains: str = "LAB,FARM"
    apply_changes: bool = False
    all_matches: bool = False


@dataclass
class GroupRequest:
    action: str
    groupname: str = ""
    username: str = ""
    users: Sequence[str] = field(default_factory=list)
    gid: Optional[int] = None
    domain: str = "FARM"
    ad_host: str = "farm2"
    primary: bool = False
    force: bool = False
    dry_run: bool = False
