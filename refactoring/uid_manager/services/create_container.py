from __future__ import annotations

import random
import re
import secrets
import string
from typing import List, Optional

from ..config import AppConfig, compose_ansible_host_alias, compose_server_id, normalize_domain
from ..db import Repository
from ..errors import RemoteCommandError, ValidationError
from ..kerberos.commands import (
    build_ad_group_command,
    build_ad_identity_command,
    build_ad_pull_command,
    build_ccache_dir_command,
    build_host_identity_command,
    build_host_refresh_command,
    build_nas_gss_refresh_command,
    build_nas_lookup_group_gid_command,
    build_nas_lookup_identity_command,
    build_nas_prepare_home_command,
    build_storage_prepare_home_command,
    build_nfs_access_check_command,
    nas_plain_home,
    storage_plain_home,
)
from ..kerberos.paths import KerberosPaths
from ..models import CreateContainerRequest, CreateContainerResult, GroupRecord, OperationPlan, PortMapping
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
        server_number = int(request.server_number)
        server_id = compose_server_id(domain, server_number)
        target_host = compose_ansible_host_alias(domain, server_number)
        validate_identity_name(request.username, "username")
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
        ports = allocate_ports(server_number, used_ports, list(request.additional_ports), request.enable_vnc)

        existing_user = self.repo.find_user(request.username)
        if existing_user:
            uid = existing_user.uid
        else:
            uid = self.repo.next_available_id()

        groupname = request.groupname or request.username
        validate_identity_name(groupname, "group name")
        existing_group = self.repo.find_group(groupname)
        if existing_group:
            gid = existing_group.gid
        elif groupname == request.username:
            gid = uid
        else:
            gid = self.repo.next_available_id()
            if gid == uid:
                gid += 1

        runtime_gid = gid
        kerberos_paths = KerberosPaths(request.username, uid, self.config) if request.enable_kerberos else None
        supplemental_groups = self.repo.supplemental_groups(request.username, gid) if existing_user else []
        container_name = request.container_name or f"{request.username}_by_{request.created_by}"
        if domain == "LAB":
            home_mount_source = self.config.lab_host_user_share_root(server_number).rstrip("/") + "/"
        elif domain == "FARM":
            home_mount_source = self.config.farm_nas_user_share_root.rstrip("/") + "/"
        else:
            home_mount_source = f"/home/tako{server_number}/share/user-share/"
        if request.enable_kerberos:
            home_mount_source = self.config.farm_kerberos_mount_user_share_root.rstrip("/") + "/"

        plan = OperationPlan("create-container plan")
        for key, value in {
            "username": request.username,
            "group": groupname,
            "uid": uid,
            "gid": gid,
            "runtime_gid": runtime_gid,
            "domain": domain,
            "server_id": server_id,
            "target_host": target_host,
            "image": f"dguailab/{request.image}:{request.version}",
            "container_name": container_name,
            "kerberos": request.enable_kerberos,
        }.items():
            plan.set_fact(key, value)
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
        plan.add_step("write DB user/group/container/port records in one transaction")
        if not request.skip_post_actions:
            plan.add_step("send email, create DB backup, refresh exports")

        docker_command = self._docker_run_command(
            request,
            uid=uid,
            gid=gid,
            runtime_gid=runtime_gid,
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
            "runtime_gid": runtime_gid,
            "groupname": groupname,
            "existing_user": existing_user,
            "existing_group": existing_group,
            "container_name": container_name,
            "ports": ports,
            "docker_command": docker_command,
            "home_mount_source": home_mount_source,
            "user_password": user_password,
            "vnc_password": vnc_password,
            "kerberos_paths": kerberos_paths,
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
            self.repo.begin()
            try:
                output = self.remote.shell(ctx["target_host"], ctx["docker_command"]).stdout.strip()
            except RemoteCommandError as exc:
                redacted_error = self._redact_docker_command(str(exc))
                raise RemoteCommandError(f"docker run failed: {self._redact_docker_command(ctx['docker_command'])}\n{redacted_error}") from exc
            container_id = output.splitlines()[-1].strip() if output else ""
            if not container_id:
                raise RemoteCommandError("docker run did not return a container id")
            self.remote.shell(ctx["target_host"], f"docker inspect '{ctx['container_name']}' >/dev/null 2>&1 && docker port '{ctx['container_name']}' >/dev/null")
            if not ctx["existing_user"]:
                self.repo.reserve_id(ctx["uid"])
            if not ctx["existing_group"] and ctx["gid"] != ctx["uid"]:
                self.repo.reserve_id(ctx["gid"])
            if not ctx["existing_group"]:
                self.repo.insert_group(ctx["groupname"], ctx["gid"])
            self.repo.upsert_user(request.name, request.username, ctx["uid"], ctx["gid"], request.email, request.phone, request.note)
            for mapping in ctx["ports"]:
                self.repo.insert_pending_port(mapping.host_port, mapping.purpose)
            db_container_id = self.repo.insert_container(request.image, request.version, container_id, ctx["container_name"], ctx["server_id"], request.expiration_date, request.created_by, request.username)
            self.repo.attach_ports(db_container_id, [mapping.host_port for mapping in ctx["ports"]])
            self.repo.commit()
        except Exception:
            self.repo.rollback()
            if container_id or ctx["container_name"]:
                self.remote.shell(ctx["target_host"], f"docker rm -f '{container_id}' >/dev/null 2>&1 || docker rm -f '{ctx['container_name']}' >/dev/null 2>&1 || true", check=False)
            raise

        if not request.skip_post_actions:
            self._post_create(request, ctx, container_id)

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
        if not self.config.is_farm_kerberos_ad_dc_host(ctx["target_host"]):
            raise ValidationError(
                "Kerberos keytab mode requires target host "
                f"{ctx['target_host']} to be one of FARM_KERBEROS_AD_DC_HOSTS "
                f"({self.config.farm_kerberos_ad_dc_hosts_csv()})"
            )
        if ctx["groupname"] != request.username:
            self.remote.shell(self.config.farm_kerberos_ad_dc_host, build_ad_group_command(self.config, ctx["groupname"], ctx["gid"]))
            if ctx["target_host"] != self.config.farm_kerberos_ad_dc_host:
                self.remote.shell(ctx["target_host"], build_ad_pull_command(self.config, ctx["target_host"], self.config.farm_kerberos_ad_dc_host))
        self.remote.shell(ctx["target_host"], build_ad_identity_command(self.config, request.username, ctx["uid"], ctx["groupname"], ctx["gid"], paths, request.rotate_kerberos_keytab))
        if ctx["target_host"] != self.config.farm_kerberos_ad_dc_host:
            self.remote.shell(self.config.farm_kerberos_ad_dc_host, build_ad_pull_command(self.config, self.config.farm_kerberos_ad_dc_host, ctx["target_host"]))
        nas_identity = self.remote.raw(
            self.config.farm_nas_host,
            build_nas_lookup_identity_command(self.config, request.username),
            user=self.config.farm_nas_user,
            port=self.config.farm_nas_port,
            private_key=self.config.farm_nas_ssh_key,
        ).stdout
        nas_uid, nas_gid = self._parse_two_ints(nas_identity, "NAS AD identity")
        runtime_gid = nas_gid
        if ctx["groupname"] != request.username:
            group_gid_out = self.remote.raw(
                self.config.farm_nas_host,
                build_nas_lookup_group_gid_command(self.config, ctx["groupname"]),
                user=self.config.farm_nas_user,
                port=self.config.farm_nas_port,
                private_key=self.config.farm_nas_ssh_key,
            ).stdout
            runtime_gid = self._parse_one_int(group_gid_out, "NAS AD group gid")
        runtime_supplemental_groups: list[GroupRecord] = []
        for group in ctx["supplemental_groups"]:
            group_gid_out = self.remote.raw(
                self.config.farm_nas_host,
                build_nas_lookup_group_gid_command(self.config, group.name),
                user=self.config.farm_nas_user,
                port=self.config.farm_nas_port,
                private_key=self.config.farm_nas_ssh_key,
            ).stdout
            runtime_supplemental_groups.append(GroupRecord(group.id, group.name, self._parse_one_int(group_gid_out, f"NAS AD supplemental group gid for {group.name}")))
        ctx["runtime_gid"] = runtime_gid
        ctx["runtime_supplemental_groups"] = runtime_supplemental_groups
        self.remote.shell(ctx["target_host"], build_host_identity_command(self.config, request.username, ctx["uid"], ctx["groupname"], runtime_gid))
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
        self.remote.shell(ctx["target_host"], build_ccache_dir_command(self.config, paths, runtime_gid))
        self.remote.shell(ctx["target_host"], build_host_refresh_command(self.config, request.username, ctx["uid"], runtime_gid, paths))
        try:
            self.remote.shell(ctx["target_host"], build_nfs_access_check_command(self.config, request.username, ctx["uid"], runtime_gid, paths))
        except RemoteCommandError:
            if self.config.farm_kerberos_nas_restart_gss_services:
                self.remote.raw(
                    self.config.farm_nas_host,
                    build_nas_gss_refresh_command(self.config),
                    user=self.config.farm_nas_user,
                    port=self.config.farm_nas_port,
                    private_key=self.config.farm_nas_ssh_key,
                )
            self.remote.shell(ctx["target_host"], build_nfs_access_check_command(self.config, request.username, ctx["uid"], runtime_gid, paths))

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

    def _post_create(self, request: CreateContainerRequest, ctx: dict, container_id: str) -> None:
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
        self.post_actions.backup_database(ctx["domain"])
        self.post_actions.update_exports()

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
