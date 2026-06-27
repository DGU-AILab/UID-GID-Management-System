from __future__ import annotations

from typing import Optional

from ..config import AppConfig, compose_ansible_host_alias, compose_server_id, normalize_domain, split_server_id
from ..db import Repository
from ..errors import AmbiguousMatchError, NotFoundError, ValidationError
from ..models import DeleteContainerRequest, OperationPlan
from ..post_actions import PostActions
from ..runners import AnsibleRunner


class ContainerDeleteService:
    def __init__(self, config: AppConfig, repo: Repository, remote: AnsibleRunner, post_actions: Optional[PostActions] = None) -> None:
        self.config = config
        self.repo = repo
        self.remote = remote
        self.post_actions = post_actions or PostActions()

    def plan(self, request: DeleteContainerRequest) -> tuple[OperationPlan, object, str]:
        domain = normalize_domain(request.domain)
        server_id = compose_server_id(domain, request.server_number)
        target_host = compose_ansible_host_alias(domain, request.server_number)
        matches = self.repo.find_container(
            server_id=server_id,
            container_id=request.container_id,
            container_name=request.container_name,
            name=request.filter_name,
            username=request.filter_username,
            port=request.filter_port,
        )
        if not matches:
            raise NotFoundError("container not found in database or already deleted")
        if len(matches) > 1:
            raise AmbiguousMatchError("multiple containers matched the given filters")
        container = matches[0]
        actual_domain, actual_number = split_server_id(container.server_id)
        actual_host = compose_ansible_host_alias(actual_domain, actual_number)
        if container.server_id != server_id and not request.force:
            raise ValidationError(f"requested server {server_id} does not match DB record {container.server_id}")
        plan = OperationPlan("delete-container plan")
        plan.set_fact("container", f"{container.container_name} ({container.container_id})")
        plan.set_fact("server_id", container.server_id)
        plan.set_fact("target_host", actual_host)
        plan.add_step("delete used_ports rows")
        plan.add_step("mark docker_container as deleted")
        plan.add_step("remove remote Docker container")
        if not request.skip_post_actions:
            plan.add_step("create DB backup and refresh exports")
        return plan, container, actual_host

    def execute(self, request: DeleteContainerRequest) -> OperationPlan:
        plan, container, target_host = self.plan(request)
        if request.dry_run:
            return plan
        try:
            self.repo.begin()
            self.repo.delete_ports_for_container(container.id)
            updated = self.repo.mark_container_deleted(container.id)
            if updated != 1 and not request.force:
                raise ValidationError("failed to mark container deleted in DB")
            self.remote.shell(target_host, f"docker rm -f '{container.container_id}' >/dev/null 2>&1 || docker rm -f '{container.container_name}' >/dev/null 2>&1")
            self.repo.commit()
        except Exception:
            self.repo.rollback()
            raise
        if not request.skip_post_actions:
            domain, _ = split_server_id(container.server_id)
            if container.email:
                self.post_actions.send_deleted_email([
                    "--recipient-email", container.email,
                    "--name", container.name,
                    "--username", container.username,
                    "--server-id", container.server_id,
                    "--container-name", container.container_name,
                    "--allocated-ports", container.ports,
                    "--expiring-date", container.expiring_at,
                ])
            self.post_actions.backup_database(domain)
            self.post_actions.update_exports()
        return plan
