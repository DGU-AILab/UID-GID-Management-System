from __future__ import annotations

from typing import Optional

from ..config import AppConfig, normalize_domain
from ..db import Repository
from ..errors import NotFoundError, ValidationError
from ..kerberos.commands import build_ad_identity_command, q
from ..models import GroupRequest, OperationPlan
from ..runners import AnsibleRunner
from ..validation import validate_identity_name


def build_ad_group_command(config: AppConfig, groupname: str, gid: int) -> str:
    sudo = f"{config.kerberos_remote_sudo} " if config.kerberos_remote_sudo else ""
    return "\n".join([
        "set -eu",
        f"groupname={q(groupname)}",
        f"gid={q(gid)}",
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
        "echo kerberos_ad_group_ready group=$groupname gid=$gid",
    ])


def build_ad_group_member_command(config: AppConfig, groupname: str, username: str, add: bool) -> str:
    sudo = f"{config.kerberos_remote_sudo} " if config.kerberos_remote_sudo else ""
    action = "addmembers" if add else "removemembers"
    return "\n".join([
        "set -eu",
        f"groupname={q(groupname)}",
        f"username={q(username)}",
        f"{sudo}samba-tool user show \"$username\" >/dev/null",
        f"{sudo}samba-tool group show \"$groupname\" >/dev/null",
        f"{sudo}samba-tool group {action} \"$groupname\" \"$username\" >/dev/null 2>&1 || true",
        f"{sudo}samba-tool group listmembers \"$groupname\" || true",
    ])


class GroupManagementService:
    def __init__(self, config: AppConfig, repo: Repository, remote: AnsibleRunner) -> None:
        self.config = config
        self.repo = repo
        self.remote = remote

    def ensure_group(self, request: GroupRequest) -> tuple[int, bool]:
        normalize_domain(request.domain)
        validate_identity_name(request.groupname, "group name")
        existing = self.repo.find_group(request.groupname)
        if existing:
            if request.gid is not None and request.gid != existing.gid:
                raise ValidationError(f"group already has gid {existing.gid}")
            return existing.gid, False
        gid = request.gid if request.gid is not None else self.repo.next_available_id()
        if not request.dry_run:
            self.repo.begin()
            try:
                self.repo.reserve_id(gid)
                self.repo.insert_group(request.groupname, gid)
                self.repo.commit()
            except Exception:
                self.repo.rollback()
                raise
        return gid, True

    def execute(self, request: GroupRequest) -> OperationPlan:
        if normalize_domain(request.domain) != "FARM":
            raise ValidationError("Kerberos AD group management is FARM-only")
        plan = OperationPlan(f"manage-group {request.action} plan")
        if request.action == "list":
            for group in self.repo.list_groups():
                plan.add_step(f"{group.name} gid={group.gid}")
            return plan

        validate_identity_name(request.groupname, "group name")
        plan.set_fact("group", request.groupname)
        if request.action in {"ensure", "add-user", "set-primary"}:
            gid, created = self.ensure_group(request)
            plan.set_fact("gid", gid)
            plan.add_step("ensure DB group")
            plan.add_step("ensure FARM AD group")
            if not request.dry_run:
                self.remote.shell(request.ad_host, build_ad_group_command(self.config, request.groupname, gid))
            if request.action == "ensure":
                return plan
            users = list(request.users) or ([request.username] if request.username else [])
            if not users:
                raise ValidationError("--user or --users is required")
            for username in users:
                validate_identity_name(username, "username")
                user = self.repo.find_user(username)
                if not user:
                    raise NotFoundError(f"user not found in DB: {username}")
                if request.action == "set-primary" or request.primary:
                    plan.add_step(f"set primary group {username} -> {request.groupname}")
                    if not request.dry_run:
                        self.repo.set_user_primary_group(username, gid)
                elif user.gid != gid:
                    plan.add_step(f"add supplemental membership {username} -> {request.groupname}")
                    if not request.dry_run:
                        self.repo.add_supplemental_group(username, gid)
                if not request.dry_run:
                    self.remote.shell(request.ad_host, build_ad_group_member_command(self.config, request.groupname, username, True))
            return plan

        group = self.repo.find_group(request.groupname)
        if not group:
            raise NotFoundError(f"group not found in DB: {request.groupname}")
        plan.set_fact("gid", group.gid)
        if request.action == "remove-user":
            users = list(request.users) or ([request.username] if request.username else [])
            if not users:
                raise ValidationError("--user or --users is required")
            for username in users:
                user = self.repo.find_user(username)
                if not user:
                    raise NotFoundError(f"user not found in DB: {username}")
                if user.gid == group.gid:
                    raise ValidationError("cannot remove a user's primary group")
                plan.add_step(f"remove supplemental membership {username} -> {request.groupname}")
                if not request.dry_run:
                    self.remote.shell(request.ad_host, build_ad_group_member_command(self.config, request.groupname, username, False))
                    self.repo.remove_supplemental_group(username, group.gid)
            return plan
        if request.action == "delete":
            primary, supplemental = self.repo.group_usage_counts(group.gid)
            if primary:
                raise ValidationError(f"cannot delete group; {primary} primary user(s) still use it")
            if supplemental and not request.force:
                raise ValidationError("cannot delete group; supplemental memberships exist. Use --force")
            plan.add_step("delete FARM AD group and DB group")
            if not request.dry_run:
                self.remote.shell(request.ad_host, f"sudo -n samba-tool group delete {q(request.groupname)} >/dev/null 2>&1 || true")
                self.repo.delete_group(group.gid, force=request.force)
            return plan
        if request.action == "show":
            plan.add_step(f"show DB group {request.groupname} gid={group.gid}")
            if not request.dry_run:
                self.remote.shell(request.ad_host, f"sudo -n samba-tool group show {q(request.groupname)} && sudo -n samba-tool group listmembers {q(request.groupname)} || true")
            return plan
        raise ValidationError(f"unknown group action: {request.action}")
