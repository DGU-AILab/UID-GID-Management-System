from __future__ import annotations

import shutil
import random
import re
import secrets
import string
import tempfile
from pathlib import Path
from typing import List, Optional

from ..config import AppConfig, compose_ansible_host_alias, compose_server_id, normalize_domain
from ..db import Repository
from ..errors import RemoteCommandError, ValidationError
from ..kerberos.commands import (
    build_ad_group_command,
    build_ad_identity_command,
    build_ad_identity_metadata_command,
    build_ad_pull_command,
    build_ad_unix_ids_command,
    build_existing_ad_identity_metadata_command,
    build_ccache_dir_command,
    build_host_identity_command,
    build_host_refresh_command,
    build_nas_gss_refresh_command,
    build_nas_lookup_group_gid_command,
    build_nas_lookup_identity_command,
    build_nas_prepare_home_command,
    build_storage_prepare_home_command,
    build_nfs_access_check_command,
    build_nfs_owner_uid_check_command,
    build_nfs_owner_stat_command,
    nas_plain_home,
    storage_plain_home,
)
from ..kerberos.paths import KerberosPaths
from ..models import CreateContainerRequest, CreateContainerResult, GroupRecord, KerberosIdentityRecord, OperationPlan, PortMapping
from ..ports import allocate_ports
from ..post_actions import PostActions
from ..runners import AnsibleRunner
from ..validation import validate_date, validate_identity_name


def generate_password(length: int) -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


class ContainerCreateService:
    def __init__(self, config: AppConfig, repo: Repository, remote: AnsibleRunner, post_actions: Optional[PostActions] = None) -> None:
        self.config = config
        self.repo = repo
        self.remote = remote
        self.post_actions = post_actions or PostActions()

    def prepare(self, request: CreateContainerRequest) -> tuple[OperationPlan, dict]:
        domain = normalize_domain(request.domain)
        if request.enable_kerberos and domain != "FARM":
            raise ValidationError("--enable-kerberos is currently supported only for FARM")
        if request.ad_username and not request.enable_kerberos:
            raise ValidationError("--ad-username requires --enable-kerberos")
        server_number = int(request.server_number)
        server_id = compose_server_id(domain, server_number)
        target_host = compose_ansible_host_alias(domain, server_number)
        validate_identity_name(request.username, "username")
        ad_username = request.ad_username or request.username
        if request.enable_kerberos:
            validate_identity_name(ad_username, "AD username")
        validate_date(request.expiration_date, "expiration date")

        user_password = request.user_password or generate_password(12)
        if not user_password.isalnum():
            raise ValidationError("--user-password must contain only letters and numbers")
        vnc_password = ""
        if request.enable_vnc:
            vnc_password = (request.vnc_password or generate_password(8))[:8]
            if not vnc_password.isalnum():
                raise ValidationError("--vnc-password must contain only letters and numbers")

        self.repo.ensure_group_membership_schema()
        used_ports = set(self.repo.used_ports())
        used_ports.update(self._live_docker_host_ports(target_host))
        if request.fixed_ports:
            ports = list(request.fixed_ports)
            fixed_host_ports = {mapping.host_port for mapping in ports}
            conflicts = sorted(fixed_host_ports & used_ports)
            if conflicts:
                raise ValidationError(f"fixed host port(s) already in use: {', '.join(str(port) for port in conflicts)}")
            if request.additional_ports:
                raise ValidationError("--container-ports cannot be combined with --fixed-port-mappings")
            if request.enable_vnc and not any(mapping.container_port == 6080 for mapping in ports):
                raise ValidationError("--enable-vnc with --fixed-port-mappings requires a 6080 mapping")
        else:
            ports = allocate_ports(server_number, used_ports, list(request.additional_ports), request.enable_vnc)

        ad_unix_ids: set[int] = set()
        existing_ad_identity: tuple[int, int] | None = None
        if request.enable_kerberos and domain == "FARM":
            existing_ad_identity = self._find_existing_ad_unix_identity(ad_username)
        existing_user = self.repo.find_user(request.username)
        if existing_user:
            uid = existing_user.uid
        elif existing_ad_identity:
            uid = existing_ad_identity[0]
        else:
            uid = self.repo.next_available_id()
            if request.enable_kerberos and domain == "FARM":
                ad_unix_ids = self._used_ad_unix_ids()
                while uid in ad_unix_ids:
                    uid += 1

        groupname = request.groupname or request.username
        validate_identity_name(groupname, "group name")
        existing_group = self.repo.find_group(groupname)
        if existing_group:
            gid = existing_group.gid
        elif groupname == request.username and existing_ad_identity:
            gid = existing_ad_identity[1]
        elif groupname == request.username:
            gid = uid
        else:
            gid = self.repo.next_available_id()
            if request.enable_kerberos and domain == "FARM":
                if not ad_unix_ids:
                    ad_unix_ids = self._used_ad_unix_ids()
                while gid in ad_unix_ids or gid == uid:
                    gid += 1

        ad_group_required = bool(request.groupname and groupname != ad_username)
        ad_groupname = groupname if ad_group_required else ad_username
        ad_uid = uid
        ad_gid = gid
        farm_kerberos_mount_root = f"/home/tako{server_number}/share/user-share"
        kerberos_paths = KerberosPaths(ad_username, uid, self.config, farm_kerberos_mount_root, home_username=request.username) if request.enable_kerberos else None
        supplemental_groups = self.repo.supplemental_groups(request.username, gid) if existing_user else []
        container_name = request.container_name or f"{request.username}_by_{request.created_by}"
        if domain == "LAB":
            home_mount_source = self.config.lab_host_user_share_root(server_number).rstrip("/") + "/"
        elif domain == "FARM":
            home_mount_source = self.config.farm_nas_user_share_root.rstrip("/") + "/"
        else:
            home_mount_source = f"/home/tako{server_number}/share/user-share/"
        if request.enable_kerberos and kerberos_paths:
            home_mount_source = kerberos_paths.mount_root.rstrip("/") + "/"

        plan = OperationPlan("create-container plan")
        for key, value in {
            "username": request.username,
            "group": groupname,
            "uid": uid,
            "gid": gid,
            "runtime_gid": gid,
            "domain": domain,
            "server_id": server_id,
            "target_host": target_host,
            "image": f"dguailab/{request.image}:{request.version}",
            "container_name": container_name,
            "kerberos": request.enable_kerberos,
            "db_record": not request.no_db_record,
        }.items():
            plan.set_fact(key, value)
        if request.enable_kerberos and kerberos_paths:
            plan.set_fact("ad_username", ad_username)
            plan.set_fact("kerberos_principal", kerberos_paths.principal)
            plan.set_fact("ad_unix_uid", ad_uid)
            plan.set_fact("ad_unix_gid", ad_gid)
        plan.add_step("ensure Docker image exists on target host")
        if domain == "LAB":
            plan.add_step("prepare LAB storage home for root_squash-safe UID/GID ownership")
        if domain == "FARM" and request.enable_kerberos:
            plan.add_step("ensure Samba AD user/group, export root-only keytab, create host ccache refresh timer")
            plan.add_step("resolve NAS AD UID/GID mapping, prepare Kerberos NAS home, refresh NAS GSS/idmap caches")
            plan.add_step("verify Kerberized NFS write through host rpc.gssd before DB commit")
        elif domain == "FARM":
            plan.add_step("prepare NAS home for root_squash-safe UID/GID ownership")
        plan.add_step("create Docker container")
        if request.no_db_record:
            plan.add_step("skip DB user/group/container/port records (--no-db-record)")
        else:
            plan.add_step("write DB user/group/container/port records in one transaction")
        if not request.skip_post_actions:
            if request.no_db_record:
                plan.add_step("send creation email; skip DB backup/export because no DB record is written")
            else:
                plan.add_step("send email, create DB backup, refresh exports")

        docker_command = self._docker_run_command(
            request,
            uid=uid,
            gid=gid,
            runtime_gid=gid,
            groupname=groupname,
            ports=ports,
            container_name=container_name,
            home_mount_source=home_mount_source,
            user_password=user_password,
            vnc_password=vnc_password,
            supplemental_groups=supplemental_groups,
            kerberos_paths=kerberos_paths,
        )
        plan.add_command(self._redact_docker_command(docker_command))

        context = {
            "domain": domain,
            "server_id": server_id,
            "target_host": target_host,
            "uid": uid,
            "gid": gid,
            "runtime_gid": gid,
            "groupname": groupname,
            "ad_username": ad_username,
            "ad_groupname": ad_groupname,
            "ad_group_required": ad_group_required,
            "ad_uid": ad_uid,
            "ad_gid": ad_gid,
            "existing_user": existing_user,
            "existing_group": existing_group,
            "container_name": container_name,
            "ports": ports,
            "docker_command": docker_command,
            "home_mount_source": home_mount_source,
            "user_password": user_password,
            "vnc_password": vnc_password,
            "kerberos_paths": kerberos_paths,
            "nas_internal_uid": None,
            "nas_internal_gid": None,
            "last_seen_nfs_uid": None,
            "last_seen_nfs_gid": None,
            "kerberos_identity_record": None,
            "supplemental_groups": supplemental_groups,
            "runtime_supplemental_groups": supplemental_groups,
        }
        return plan, context

    def execute(self, request: CreateContainerRequest) -> CreateContainerResult:
        plan, ctx = self.prepare(request)
        if request.dry_run:
            return CreateContainerResult("DRY-RUN", ctx["container_name"], ctx["uid"], ctx["gid"], ctx["runtime_gid"], ctx["server_id"], ctx["target_host"], ctx["ports"], plan)

        self.remote.shell(ctx["target_host"], f"docker image inspect dguailab/{request.image}:{request.version} >/dev/null 2>&1 || docker pull dguailab/{request.image}:{request.version}")
        self._prepare_storage_and_kerberos(request, ctx)
        ctx["docker_command"] = self._docker_run_command(
            request,
            uid=ctx["uid"],
            gid=ctx["gid"],
            runtime_gid=ctx["runtime_gid"],
            groupname=ctx["groupname"],
            ports=ctx["ports"],
            container_name=ctx["container_name"],
            home_mount_source=ctx["home_mount_source"],
            user_password=ctx["user_password"],
            vnc_password=ctx["vnc_password"],
            supplemental_groups=ctx["runtime_supplemental_groups"],
            kerberos_paths=ctx["kerberos_paths"],
        )

        container_id = ""
        try:
            try:
                output = self.remote.shell(ctx["target_host"], ctx["docker_command"]).stdout.strip()
            except RemoteCommandError as exc:
                redacted_error = self._redact_docker_command(str(exc))
                raise RemoteCommandError(f"docker run failed: {self._redact_docker_command(ctx['docker_command'])}\n{redacted_error}") from exc
            container_id = output.splitlines()[-1].strip() if output else ""
            if not container_id:
                raise RemoteCommandError("docker run did not return a container id")
            self.remote.shell(ctx["target_host"], f"docker inspect '{ctx['container_name']}' >/dev/null 2>&1 && docker port '{ctx['container_name']}' >/dev/null")
            if not request.no_db_record:
                self.repo.begin()
                if not ctx["existing_user"]:
                    self.repo.reserve_id(ctx["uid"])
                if not ctx["existing_group"] and ctx["gid"] != ctx["uid"]:
                    self.repo.reserve_id(ctx["gid"])
                if not ctx["existing_group"]:
                    self.repo.insert_group(ctx["groupname"], ctx["gid"])
                self.repo.upsert_user(request.name, request.username, ctx["uid"], ctx["gid"], request.email, request.phone, request.note)
                if request.enable_kerberos and ctx["kerberos_identity_record"]:
                    self.repo.upsert_kerberos_identity(ctx["kerberos_identity_record"])
                for mapping in ctx["ports"]:
                    self.repo.insert_pending_port(mapping.host_port, mapping.purpose)
                db_container_id = self.repo.insert_container(request.image, request.version, container_id, ctx["container_name"], ctx["server_id"], request.expiration_date, request.created_by, request.username)
                self.repo.attach_ports(db_container_id, [mapping.host_port for mapping in ctx["ports"]])
                self.repo.commit()
        except Exception:
            if not request.no_db_record:
                self.repo.rollback()
            if container_id or ctx["container_name"]:
                self.remote.shell(ctx["target_host"], f"docker rm -f '{container_id}' >/dev/null 2>&1 || docker rm -f '{ctx['container_name']}' >/dev/null 2>&1 || true", check=False)
            raise

        if not request.skip_post_actions:
            self._post_create(request, ctx, container_id, db_record=not request.no_db_record)

        return CreateContainerResult(container_id, ctx["container_name"], ctx["uid"], ctx["gid"], ctx["runtime_gid"], ctx["server_id"], ctx["target_host"], ctx["ports"], plan)

    def _prepare_storage_and_kerberos(self, request: CreateContainerRequest, ctx: dict) -> None:
        if ctx["domain"] == "LAB":
            home = storage_plain_home(self.config.lab_storage_user_share_root, request.username)
            self.remote.raw(
                self.config.lab_storage_host,
                build_storage_prepare_home_command(home, ctx["uid"], ctx["gid"], self.config.lab_storage_sudo),
                user=self.config.lab_storage_user,
                port=self.config.lab_storage_port,
                private_key=self.config.lab_storage_ssh_key,
                ssh_common_args=self.config.lab_storage_ssh_common_args,
            )
            return
        if ctx["domain"] != "FARM":
            return
        if not request.enable_kerberos:
            home = nas_plain_home(self.config.farm_nas_user_share_root, request.username)
            self.remote.raw(
                self.config.farm_nas_host,
                build_nas_prepare_home_command(home, ctx["uid"], ctx["gid"], self.config.farm_nas_sudo),
                user=self.config.farm_nas_user,
                port=self.config.farm_nas_port,
                private_key=self.config.farm_nas_ssh_key,
            )
            return

        paths: KerberosPaths = ctx["kerberos_paths"]
        ad_identity_host = ctx["target_host"] if self.config.is_farm_kerberos_ad_dc_host(ctx["target_host"]) else self.config.farm_kerberos_ad_dc_host
        if ctx["ad_group_required"]:
            self.remote.shell(self.config.farm_kerberos_ad_dc_host, build_ad_group_command(self.config, ctx["ad_groupname"], ctx["gid"]))
            if ad_identity_host != self.config.farm_kerberos_ad_dc_host:
                self.remote.shell(ad_identity_host, build_ad_pull_command(self.config, ad_identity_host, self.config.farm_kerberos_ad_dc_host))
        self.remote.shell(ad_identity_host, build_ad_identity_command(self.config, ctx["ad_username"], ctx["ad_uid"], ctx["ad_groupname"], ctx["ad_gid"], paths, request.rotate_kerberos_keytab))
        ad_metadata = self._parse_key_values(
            self.remote.shell(ad_identity_host, build_ad_identity_metadata_command(self.config, ctx["ad_username"])).stdout,
            "AD Kerberos identity metadata",
        )
        kerberos_identity = self._build_kerberos_identity_record(request, ctx, ad_metadata)
        self._validate_kerberos_identity(request.username, kerberos_identity)
        ctx["kerberos_identity_record"] = kerberos_identity
        for dc_host in self.config.farm_kerberos_ad_dc_hosts:
            if dc_host != ad_identity_host:
                self.remote.shell(dc_host, build_ad_pull_command(self.config, dc_host, ad_identity_host))
        if ctx["target_host"] != ad_identity_host:
            self._copy_keytab_to_target(ad_identity_host, ctx["target_host"], paths)
        nas_identity = self.remote.raw(
            self.config.farm_nas_host,
            build_nas_lookup_identity_command(self.config, ctx["ad_username"]),
            user=self.config.farm_nas_user,
            port=self.config.farm_nas_port,
            private_key=self.config.farm_nas_ssh_key,
        ).stdout
        nas_uid, nas_gid = self._parse_two_ints(nas_identity, "NAS AD identity")
        ctx["nas_internal_uid"] = nas_uid
        ctx["nas_internal_gid"] = nas_gid
        if ctx["ad_group_required"]:
            self.remote.raw(
                self.config.farm_nas_host,
                build_nas_lookup_group_gid_command(self.config, ctx["ad_groupname"]),
                user=self.config.farm_nas_user,
                port=self.config.farm_nas_port,
                private_key=self.config.farm_nas_ssh_key,
            )
        ctx["runtime_gid"] = ctx["gid"]
        ctx["runtime_supplemental_groups"] = ctx["supplemental_groups"]
        self.remote.shell(ctx["target_host"], build_host_identity_command(self.config, request.username, ctx["uid"], ctx["groupname"], ctx["gid"]))
        self.remote.raw(
            self.config.farm_nas_host,
            build_nas_prepare_home_command(paths.nas_home, nas_uid, nas_gid, self.config.farm_nas_sudo),
            user=self.config.farm_nas_user,
            port=self.config.farm_nas_port,
            private_key=self.config.farm_nas_ssh_key,
        )
        if self.config.farm_kerberos_nas_restart_gss_services:
            self.remote.raw(
                self.config.farm_nas_host,
                build_nas_gss_refresh_command(self.config),
                user=self.config.farm_nas_user,
                port=self.config.farm_nas_port,
                private_key=self.config.farm_nas_ssh_key,
            )
        self.remote.shell(ctx["target_host"], build_ccache_dir_command(self.config, paths, ctx["gid"]))
        self.remote.shell(ctx["target_host"], build_host_refresh_command(self.config, ctx["ad_username"], ctx["uid"], ctx["gid"], paths))
        self.remote.shell(ctx["target_host"], build_nfs_owner_uid_check_command(self.config, ctx["uid"], paths))
        nfs_uid, nfs_gid = self._parse_two_ints(
            self.remote.shell(ctx["target_host"], build_nfs_owner_stat_command(self.config, paths)).stdout,
            "FARM NFS owner identity",
        )
        ctx["last_seen_nfs_uid"] = nfs_uid
        ctx["last_seen_nfs_gid"] = nfs_gid
        ctx["kerberos_identity_record"] = self._with_last_seen_identity(ctx["kerberos_identity_record"], ctx)
        try:
            self.remote.shell(ctx["target_host"], build_nfs_access_check_command(self.config, request.username, ctx["uid"], ctx["gid"], paths))
        except RemoteCommandError:
            if self.config.farm_kerberos_nas_restart_gss_services:
                self.remote.raw(
                    self.config.farm_nas_host,
                    build_nas_gss_refresh_command(self.config),
                    user=self.config.farm_nas_user,
                    port=self.config.farm_nas_port,
                    private_key=self.config.farm_nas_ssh_key,
            )
            self.remote.shell(ctx["target_host"], build_nfs_owner_uid_check_command(self.config, ctx["uid"], paths))
            nfs_uid, nfs_gid = self._parse_two_ints(
                self.remote.shell(ctx["target_host"], build_nfs_owner_stat_command(self.config, paths)).stdout,
                "FARM NFS owner identity",
            )
            ctx["last_seen_nfs_uid"] = nfs_uid
            ctx["last_seen_nfs_gid"] = nfs_gid
            ctx["kerberos_identity_record"] = self._with_last_seen_identity(ctx["kerberos_identity_record"], ctx)
            self.remote.shell(ctx["target_host"], build_nfs_access_check_command(self.config, request.username, ctx["uid"], ctx["gid"], paths))

    def _copy_keytab_to_target(self, source_host: str, target_host: str, paths: KerberosPaths) -> None:
        scratch_dir = Path(tempfile.mkdtemp(prefix="decs-keytab-"))
        local_keytab = scratch_dir / f"{paths.username}.keytab"
        try:
            self.remote.local_runner.run([
                "ansible",
                source_host,
                "-i",
                self.config.ansible_inventory,
                "-m",
                "fetch",
                "-a",
                f"src={paths.keytab_file} dest={local_keytab} flat=yes",
                "--become",
            ])
            self.remote.shell(
                target_host,
                f"{self.config.kerberos_remote_sudo} install -d -o root -g root -m 0700 {self.config.farm_kerberos_keytab_dir}",
            )
            self.remote.local_runner.run([
                "ansible",
                target_host,
                "-i",
                self.config.ansible_inventory,
                "-m",
                "copy",
                "-a",
                f"src={local_keytab} dest={paths.keytab_file} owner=root group=root mode=0400",
                "--become",
            ])
        finally:
            shutil.rmtree(scratch_dir, ignore_errors=True)

    def _used_ad_unix_ids(self) -> set[int]:
        result = self.remote.shell(self.config.farm_kerberos_ad_dc_host, build_ad_unix_ids_command(self.config))
        ids: set[int] = set()
        for line in result.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) == 2 and parts[0] in {"uid", "gid"} and parts[1].isdigit():
                ids.add(int(parts[1]))
        return ids

    def _find_existing_ad_unix_identity(self, ad_username: str) -> tuple[int, int] | None:
        result = self.remote.shell(
            self.config.farm_kerberos_ad_dc_host,
            build_existing_ad_identity_metadata_command(self.config, ad_username),
            check=False,
        )
        values: dict[str, str] = {}
        for line in result.stdout.splitlines():
            stripped = line.strip()
            if not stripped or "=" not in stripped:
                continue
            key, value = stripped.split("=", 1)
            values[key] = value
        if values.get("ad_username") != ad_username:
            return None
        uid = values.get("ad_uid_number")
        gid = values.get("ad_gid_number")
        if uid and gid and uid.isdigit() and gid.isdigit():
            return int(uid), int(gid)
        return None

    def _docker_run_command(
        self,
        request: CreateContainerRequest,
        *,
        uid: int,
        gid: int,
        runtime_gid: int,
        groupname: str,
        ports: List[PortMapping],
        container_name: str,
        home_mount_source: str,
        user_password: str,
        vnc_password: str,
        supplemental_groups: List[GroupRecord],
        kerberos_paths: Optional[KerberosPaths],
    ) -> str:
        port_params = " ".join(mapping.docker_arg() for mapping in ports)
        supplemental = ""
        if supplemental_groups:
            specs = ",".join(f"{group.name}:{group.gid}" for group in supplemental_groups)
            supplemental = f" -e DECS_SUPPLEMENTAL_GROUPS='{specs}'"
        vnc_env = ""
        if request.enable_vnc:
            vnc_env = f" -e ENABLE_VNC='true' -e VNC_PASSWORD='{vnc_password}'"
        kerberos_params = ""
        if kerberos_paths:
            kerberos_params = (
                f" --mount type=bind,source='{kerberos_paths.ccache_dir}',target='{kerberos_paths.ccache_dir}'"
                f" --mount type=bind,source='{self.config.farm_kerberos_krb5_conf}',target=/etc/krb5.conf,readonly"
                f" -e KRB5CCNAME='FILE:{kerberos_paths.ccache_file}'"
                " -e DECS_KERBEROS_ENABLED='true'"
                " -e DECS_KERBEROS_HOST_KEYTAB='true'"
                " -e DECS_USER_SUDO_MODE='restricted'"
                f" -e DECS_KRB5_PRINCIPAL='{kerberos_paths.principal}'"
                f" -e KRB5_REALM='{self.config.farm_kerberos_realm}'"
            )
        return (
            "docker run -dit --init --gpus device=all --memory=192g --memory-swap=192g "
            f"{port_params} --runtime=nvidia --cap-add=SYS_ADMIN --ipc=host "
            f"--mount type=bind,source='{home_mount_source}',target=/home"
            f"{kerberos_params} --name '{container_name}' "
            f"-e USER_ID='{request.username}' -e GID='{runtime_gid}' -e TARGET_GID='{runtime_gid}' "
            f"-e USER_PW='{user_password}' -e USER_GROUP='{groupname}' -e UID='{uid}' -e TARGET_UID='{uid}'"
            f"{supplemental}{vnc_env} -e NVIDIA_DRIVER_CAPABILITIES='compute,utility,graphics,display' "
            f"dguailab/{request.image}:{request.version}"
        )

    def _live_docker_host_ports(self, target_host: str) -> List[int]:
        result = self.remote.shell(target_host, "docker ps -q | xargs -r -n1 docker port 2>/dev/null", check=False)
        ports: List[int] = []
        for match in re.finditer(r":([0-9]{2,5})(?:\s|$)", result.stdout):
            ports.append(int(match.group(1)))
        return ports

    @staticmethod
    def _redact_docker_command(command: str) -> str:
        parts = []
        for part in command.split():
            if part.startswith("USER_PW=") or part.startswith("VNC_PASSWORD="):
                parts.append(part.split("=", 1)[0] + "=***")
            elif part.startswith("-e") and ("USER_PW=" in part or "VNC_PASSWORD=" in part):
                parts.append(part)
            elif "USER_PW='" in part:
                parts.append("USER_PW='***'")
            elif "VNC_PASSWORD='" in part:
                parts.append("VNC_PASSWORD='***'")
            else:
                parts.append(part)
        redacted = " ".join(parts)
        redacted = redacted.replace("-e USER_PW='", "-e USER_PW='***")
        redacted = redacted.replace("-e VNC_PASSWORD='", "-e VNC_PASSWORD='***")
        return redacted

    def _post_create(self, request: CreateContainerRequest, ctx: dict, container_id: str, *, db_record: bool = True) -> None:
        self._send_create_email(request, ctx)
        if db_record:
            self.post_actions.backup_database(ctx["domain"])
            self.post_actions.update_exports()

    def _send_create_email(self, request: CreateContainerRequest, ctx: dict) -> None:
        ssh_port = next(mapping.host_port for mapping in ctx["ports"] if mapping.container_port == 22)
        jupyter_port = next(mapping.host_port for mapping in ctx["ports"] if mapping.container_port == 8888)
        vnc_port = next((mapping.host_port for mapping in ctx["ports"] if mapping.container_port == 6080), "")
        additional = ",".join(f"{m.host_port}:{m.container_port}" for m in ctx["ports"] if m.container_port not in {22, 8888, 6080})
        self.post_actions.send_created_email([
            "--recipient-email", request.email,
            "--name", request.name,
            "--username", request.username,
            "--server-id", ctx["server_id"],
            "--image", request.image,
            "--version", request.version,
            "--ssh-port", str(ssh_port),
            "--jupyter-port", str(jupyter_port),
            "--additional-port-mappings", additional,
            "--user-password", ctx["user_password"],
            "--vnc-port", str(vnc_port),
            "--vnc-password", ctx["vnc_password"],
        ])

    def _build_kerberos_identity_record(self, request: CreateContainerRequest, ctx: dict, metadata: dict[str, str]) -> KerberosIdentityRecord:
        required = [
            "ad_username",
            "ad_realm",
            "ad_netbios_domain",
            "ad_domain_sid",
            "ad_object_sid",
            "ad_uid_number",
            "ad_gid_number",
        ]
        missing = [key for key in required if not metadata.get(key)]
        if missing:
            raise ValidationError(f"AD Kerberos identity metadata missing: {', '.join(missing)}")
        try:
            ad_uid_number = int(metadata["ad_uid_number"])
            ad_gid_number = int(metadata["ad_gid_number"])
        except ValueError as exc:
            raise ValidationError(f"AD uidNumber/gidNumber must be numeric: {metadata}") from exc
        if ad_uid_number != ctx["uid"] or ad_gid_number != ctx["gid"]:
            raise ValidationError(
                "AD uidNumber/gidNumber mismatch: "
                f"username={request.username} ad_username={ctx['ad_username']} "
                f"db={ctx['uid']}:{ctx['gid']} ad={ad_uid_number}:{ad_gid_number}"
            )
        if metadata["ad_username"] != ctx["ad_username"]:
            raise ValidationError(f"AD sAMAccountName mismatch: expected {ctx['ad_username']}, got {metadata['ad_username']}")
        return KerberosIdentityRecord(
            username=request.username,
            ad_username=metadata["ad_username"],
            ad_realm=metadata["ad_realm"],
            ad_netbios_domain=metadata["ad_netbios_domain"],
            ad_domain_sid=metadata["ad_domain_sid"],
            ad_object_sid=metadata["ad_object_sid"],
            ad_uid_number=ad_uid_number,
            ad_gid_number=ad_gid_number,
        )

    def _validate_kerberos_identity(self, username: str, current: KerberosIdentityRecord) -> None:
        stored = self.repo.find_kerberos_identity(username)
        if not stored:
            return
        checks = {
            "ad_username": (stored.ad_username, current.ad_username),
            "ad_realm": (stored.ad_realm, current.ad_realm),
            "ad_netbios_domain": (stored.ad_netbios_domain, current.ad_netbios_domain),
            "ad_domain_sid": (stored.ad_domain_sid, current.ad_domain_sid),
            "ad_object_sid": (stored.ad_object_sid, current.ad_object_sid),
            "ad_uid_number": (stored.ad_uid_number, current.ad_uid_number),
            "ad_gid_number": (stored.ad_gid_number, current.ad_gid_number),
        }
        mismatches = [
            f"{key}: stored={old} current={new}"
            for key, (old, new) in checks.items()
            if old not in {"", 0, None} and old != new
        ]
        if mismatches:
            raise ValidationError(f"Kerberos identity mismatch for {username}: " + "; ".join(mismatches))

    @staticmethod
    def _with_last_seen_identity(record: KerberosIdentityRecord, ctx: dict) -> KerberosIdentityRecord:
        return KerberosIdentityRecord(
            username=record.username,
            ad_username=record.ad_username,
            ad_realm=record.ad_realm,
            ad_netbios_domain=record.ad_netbios_domain,
            ad_domain_sid=record.ad_domain_sid,
            ad_object_sid=record.ad_object_sid,
            ad_uid_number=record.ad_uid_number,
            ad_gid_number=record.ad_gid_number,
            last_seen_nas_internal_uid=int(ctx["nas_internal_uid"] or 0),
            last_seen_nas_internal_gid=int(ctx["nas_internal_gid"] or 0),
            last_seen_nfs_uid=int(ctx["last_seen_nfs_uid"] or 0),
            last_seen_nfs_gid=int(ctx["last_seen_nfs_gid"] or 0),
            last_verified_at=record.last_verified_at,
        )

    @staticmethod
    def _parse_key_values(output: str, label: str) -> dict[str, str]:
        values: dict[str, str] = {}
        for line in output.splitlines():
            stripped = line.strip()
            if not stripped or "=" not in stripped:
                continue
            key, value = stripped.split("=", 1)
            values[key] = value
        if not values:
            raise ValidationError(f"could not parse {label}: {output}")
        return values

    @staticmethod
    def _parse_two_ints(output: str, label: str) -> tuple[int, int]:
        for line in output.splitlines():
            parts = line.strip().split()
            if len(parts) == 2 and all(part.isdigit() for part in parts):
                return int(parts[0]), int(parts[1])
        raise ValidationError(f"could not parse {label}: {output}")

    @staticmethod
    def _parse_one_int(output: str, label: str) -> int:
        for line in output.splitlines():
            stripped = line.strip()
            if stripped.isdigit():
                return int(stripped)
        raise ValidationError(f"could not parse {label}: {output}")
