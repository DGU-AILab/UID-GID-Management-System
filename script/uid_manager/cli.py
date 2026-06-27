from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .config import AppConfig, DEFAULT_CONFIG_PATH, normalize_domain, split_server_id
from .db import MySqlRepository
from .errors import UidManagerError
from .models import CreateContainerRequest, DeleteContainerRequest, ExtendContainerRequest, GroupRequest, PortMapping
from .post_actions import PostActions
from .runners import AnsibleRunner, LocalRunner
from .services.create_container import ContainerCreateService
from .services.delete_container import ContainerDeleteService
from .services.extend_container import ContainerExtendService
from .services.expired_cleanup import ExpiredCleanupService
from .services.manage_group import GroupManagementService
from .services.sync_containers import ContainerSyncService


def add_common_server_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--domain")
    parser.add_argument("--server-number", type=int)
    parser.add_argument("-s", "--server-id")


def resolve_domain_server(args: argparse.Namespace) -> tuple[str, int]:
    if args.server_id:
        return split_server_id(args.server_id)
    if not args.domain or not args.server_number:
        raise UidManagerError("--domain/--server-number or --server-id is required")
    return normalize_domain(args.domain), int(args.server_number)


def parse_fixed_port_mappings(raw: str) -> list[PortMapping]:
    mappings: list[PortMapping] = []
    if not raw.strip():
        return mappings
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        parts = item.split(":", 2)
        if len(parts) not in {2, 3}:
            raise UidManagerError("--fixed-port-mappings entries must be host:container[:purpose]")
        try:
            host_port = int(parts[0])
            container_port = int(parts[1])
        except ValueError as exc:
            raise UidManagerError("--fixed-port-mappings host/container ports must be numeric") from exc
        if len(parts) == 3 and parts[2].strip():
            purpose = parts[2].strip()
        elif container_port == 22:
            purpose = "ssh"
        elif container_port == 8888:
            purpose = "jupyter notebook"
        elif container_port == 6080:
            purpose = "vnc"
        else:
            purpose = f"container port {container_port}"
        mappings.append(PortMapping(host_port, container_port, purpose))
    host_ports = [mapping.host_port for mapping in mappings]
    container_ports = [mapping.container_port for mapping in mappings]
    if len(host_ports) != len(set(host_ports)):
        raise UidManagerError("--fixed-port-mappings contains duplicate host ports")
    if 22 not in container_ports or 8888 not in container_ports:
        raise UidManagerError("--fixed-port-mappings must include container ports 22 and 8888")
    return mappings


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="uidctl")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG_PATH))
    sub = parser.add_subparsers(dest="command", required=True)

    create = sub.add_parser("create-container")
    create.add_argument("-n", "--name", required=True)
    create.add_argument("-u", "--username", required=True)
    create.add_argument("-g", "--group", dest="groupname")
    add_common_server_args(create)
    create.add_argument("-e", "--expiration-date", required=True)
    create.add_argument("-i", "--image", required=True)
    create.add_argument("-v", "--version", required=True)
    create.add_argument("-d", "--container-name")
    create.add_argument("-p", "--container-ports", default="")
    create.add_argument("--fixed-port-mappings", default="", help="Comma-separated host:container[:purpose] mappings; overrides automatic port allocation")
    create.add_argument("--enable-vnc", action="store_true")
    create.add_argument("--enable-kerberos", action="store_true")
    create.add_argument("--ad-username", help="Kerberos/AD username to use when it differs from the container username")
    create.add_argument("--rotate-kerberos-keytab", action="store_true")
    create.add_argument("-c", "--created-by", required=True)
    create.add_argument("--email", required=True)
    create.add_argument("--phone", required=True)
    create.add_argument("-m", "--note", default="")
    create.add_argument("--user-password")
    create.add_argument("--vnc-password")
    create.add_argument("--dry-run", action="store_true")
    create.add_argument("--skip-post-actions", action="store_true")
    create.add_argument("--no-db-record", action="store_true", help="Create the remote container but skip DB user/group/container/port writes")

    delete = sub.add_parser("delete-container")
    add_common_server_args(delete)
    delete.add_argument("-i", "--container-id", default="")
    delete.add_argument("-n", "--container-name", default="")
    delete.add_argument("--name", dest="filter_name", default="")
    delete.add_argument("--username", dest="filter_username", default="")
    delete.add_argument("--port", dest="filter_port", type=int)
    delete.add_argument("-f", "--force", action="store_true")
    delete.add_argument("--dry-run", action="store_true")
    delete.add_argument("--skip-post-actions", action="store_true")

    extend = sub.add_parser("extend-container")
    extend.add_argument("--name", default="")
    extend.add_argument("--username", default="")
    extend.add_argument("--port", type=int)
    extend.add_argument("--expiration-date", required=True)
    extend.add_argument("--domains", default=None)
    extend.add_argument("--apply", action="store_true")
    extend.add_argument("--all-matches", action="store_true")

    cleanup = sub.add_parser("expired-cleanup")
    cleanup.add_argument("--today", required=True)
    cleanup.add_argument("--domains", default=None)
    cleanup.add_argument("--username", default="")
    cleanup.add_argument("--container-name", default="")
    cleanup.add_argument("--apply", action="store_true")
    cleanup.add_argument("--dry-run", action="store_true")

    sync = sub.add_parser("sync-containers")
    sync.add_argument("--domain", required=True)
    sync.add_argument("--dry-run", action="store_true")
    sync.add_argument("--auto-delete", action="store_true")

    group = sub.add_parser("manage-group")
    group_sub = group.add_subparsers(dest="group_action", required=True)
    for action in ["ensure", "add-user", "remove-user", "set-primary", "delete", "show", "list"]:
        gp = group_sub.add_parser(action)
        gp.add_argument("-g", "--group", dest="groupname", default="")
        gp.add_argument("-u", "--user", dest="username", default="")
        gp.add_argument("--users", default="")
        gp.add_argument("--gid", type=int)
        gp.add_argument("--domain", default="FARM")
        gp.add_argument("--ad-host", default="")
        gp.add_argument("--primary", action="store_true")
        gp.add_argument("--force", action="store_true")
        gp.add_argument("--dry-run", action="store_true")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        config = AppConfig.from_file(Path(args.config))
        local_runner = LocalRunner()
        remote = AnsibleRunner(config.ansible_inventory, local_runner)
        post = PostActions(local_runner, config=config)

        if args.command == "create-container":
            domain, number = resolve_domain_server(args)
            repo = MySqlRepository(config, domain)
            try:
                ports = [int(item.strip()) for item in args.container_ports.split(",") if item.strip()]
                fixed_ports = parse_fixed_port_mappings(args.fixed_port_mappings)
                request = CreateContainerRequest(
                    name=args.name,
                    username=args.username,
                    groupname=args.groupname,
                    domain=domain,
                    server_number=number,
                    expiration_date=args.expiration_date,
                    image=args.image,
                    version=args.version,
                    container_name=args.container_name,
                    additional_ports=ports,
                    fixed_ports=fixed_ports,
                    enable_vnc=args.enable_vnc,
                    enable_kerberos=args.enable_kerberos,
                    ad_username=args.ad_username,
                    rotate_kerberos_keytab=args.rotate_kerberos_keytab,
                    created_by=args.created_by,
                    email=args.email,
                    phone=args.phone,
                    note=args.note,
                    user_password=args.user_password,
                    vnc_password=args.vnc_password,
                    dry_run=args.dry_run,
                    skip_post_actions=args.skip_post_actions,
                    no_db_record=args.no_db_record,
                )
                result = ContainerCreateService(config, repo, remote, post).execute(request)
                print(result.plan.render())
                if result.container_id != "DRY-RUN":
                    print(f"created container {result.container_name}: {result.container_id}")
            finally:
                repo.close()
        elif args.command == "delete-container":
            domain, number = resolve_domain_server(args)
            repo = MySqlRepository(config, domain)
            try:
                request = DeleteContainerRequest(domain, number, args.container_id, args.container_name, args.filter_name, args.filter_username, args.filter_port, args.force, args.dry_run, args.skip_post_actions)
                plan = ContainerDeleteService(config, repo, remote, post).execute(request)
                print(plan.render())
            finally:
                repo.close()
        elif args.command == "extend-container":
            domains = args.domains or config.export_domains
            repos = {domain: MySqlRepository(config, domain) for domain in config.domains(domains)}
            try:
                request = ExtendContainerRequest(args.expiration_date, args.name, args.username, args.port, domains, args.apply, args.all_matches)
                print(ContainerExtendService(config, repos, post).execute(request).render())
            finally:
                for repo in repos.values():
                    repo.close()
        elif args.command == "expired-cleanup":
            domains = args.domains or config.export_domains
            repos = {domain: MySqlRepository(config, domain) for domain in config.domains(domains)}
            try:
                apply_changes = args.apply and not args.dry_run
                print(ExpiredCleanupService(config, repos, post, remote).execute(args.today, domains, apply_changes, username=args.username, container_name=args.container_name).render())
            finally:
                for repo in repos.values():
                    repo.close()
        elif args.command == "manage-group":
            domain = normalize_domain(args.domain)
            repo = MySqlRepository(config, domain)
            try:
                request = GroupRequest(
                    action=args.group_action,
                    groupname=args.groupname,
                    username=args.username,
                    users=[item.strip() for item in args.users.split(",") if item.strip()],
                    gid=args.gid,
                    domain=domain,
                    ad_host=args.ad_host or config.farm_kerberos_ad_dc_host,
                    primary=args.primary,
                    force=args.force,
                    dry_run=args.dry_run,
                )
                print(GroupManagementService(config, repo, remote).execute(request).render())
            finally:
                repo.close()
        elif args.command == "sync-containers":
            domain = normalize_domain(args.domain)
            repo = MySqlRepository(config, domain)
            try:
                records = repo.active_containers()
                plan = ContainerSyncService(local_runner).execute(records, dry_run=args.dry_run, auto_delete=args.auto_delete)
                print(plan.render())
            finally:
                repo.close()
        return 0
    except UidManagerError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
