from __future__ import annotations

from typing import Dict, Optional

from ..config import AppConfig, compose_ansible_host_alias, split_server_id
from ..db import Repository
from ..models import OperationPlan
from ..post_actions import PostActions
from ..runners import AnsibleRunner
from ..validation import validate_date


class ExpiredCleanupService:
    def __init__(self, config: AppConfig, repos_by_domain: Dict[str, Repository], post_actions: Optional[PostActions] = None, remote: Optional[AnsibleRunner] = None) -> None:
        self.config = config
        self.repos_by_domain = repos_by_domain
        self.post_actions = post_actions or PostActions()
        self.remote = remote

    def execute(self, today: str, domains: str, apply_changes: bool, username: str = "", container_name: str = "") -> OperationPlan:
        validate_date(today, "today")
        plan = OperationPlan("expired-cleanup plan")
        if username:
            plan.set_fact("username_filter", username)
        if container_name:
            plan.set_fact("container_name_filter", container_name)
        total = 0
        updated_domains = set()
        for domain in self.config.domains(domains):
            repo = self.repos_by_domain[domain]
            rows = [
                row for row in repo.expired_containers(today)
                if (not username or row.username == username)
                and (not container_name or row.container_name == container_name)
            ]
            if not rows:
                plan.add_step(f"{domain}: no expired containers")
                continue
            for row in rows:
                total += 1
                plan.add_step(f"{domain}: expired {row.container_name} {row.container_id} user={row.username} expiring={row.expiring_at}")
                if apply_changes:
                    domain_from_server, number = split_server_id(row.server_id)
                    target_host = compose_ansible_host_alias(domain_from_server, number)
                    repo.begin()
                    try:
                        repo.delete_ports_for_container(row.id)
                        repo.mark_container_deleted(row.id)
                        if self.remote:
                            self.remote.shell(target_host, f"docker rm -f '{row.container_id}' >/dev/null 2>&1 || docker rm -f '{row.container_name}' >/dev/null 2>&1")
                        repo.commit()
                    except Exception:
                        repo.rollback()
                        raise
                    if row.email:
                        self.post_actions.send_deleted_email([
                            "--recipient-email", row.email,
                            "--name", row.name,
                            "--username", row.username,
                            "--server-id", row.server_id,
                            "--container-name", row.container_name,
                            "--allocated-ports", row.ports,
                            "--expiring-date", row.expiring_at,
                        ])
                    updated_domains.add(domain)
        plan.set_fact("expired", total)
        if apply_changes and updated_domains:
            for domain in sorted(updated_domains):
                self.post_actions.backup_database(domain)
            self.post_actions.update_exports()
        return plan
