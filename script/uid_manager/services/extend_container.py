from __future__ import annotations

from datetime import datetime
from typing import Dict, List, Optional

from ..config import AppConfig
from ..db import Repository
from ..errors import AmbiguousMatchError, ValidationError
from ..models import ContainerRecord, ExtendContainerRequest, OperationPlan
from ..post_actions import PostActions
from ..validation import validate_date


class ContainerExtendService:
    def __init__(self, config: AppConfig, repos_by_domain: Dict[str, Repository], post_actions: Optional[PostActions] = None) -> None:
        self.config = config
        self.repos_by_domain = repos_by_domain
        self.post_actions = post_actions or PostActions()

    def find_matches(self, request: ExtendContainerRequest) -> List[tuple[str, ContainerRecord]]:
        validate_date(request.expiration_date, "expiration date")
        if not request.name and not request.username and request.port is None:
            raise ValidationError("provide at least one filter: name, username, or port")
        matches: List[tuple[str, ContainerRecord]] = []
        for domain in self.config.domains(request.domains):
            repo = self.repos_by_domain[domain]
            for row in repo.matching_active_containers(name=request.name, username=request.username, port=request.port):
                matches.append((domain, row))
        return matches

    def execute(self, request: ExtendContainerRequest) -> OperationPlan:
        matches = self.find_matches(request)
        plan = OperationPlan("extend-container plan")
        plan.set_fact("matches", len(matches))
        plan.set_fact("new_expiration_date", request.expiration_date)
        invalid = [row for _, row in matches if row.expiring_at and request.expiration_date <= row.expiring_at]
        if invalid:
            raise ValidationError("new expiration date must be later than current expiration date")
        if not request.apply_changes:
            for domain, row in matches:
                plan.add_step(f"would update {domain} {row.container_name}: {row.expiring_at} -> {request.expiration_date}")
            return plan
        if len(matches) > 1 and not request.all_matches:
            raise AmbiguousMatchError("multiple containers matched; use all_matches to update all")
        updated_domains = set()
        for domain, row in matches:
            repo = self.repos_by_domain[domain]
            if repo.update_expiration(row.id, request.expiration_date) != 1:
                raise ValidationError(f"failed to update {row.container_name}")
            updated_domains.add(domain)
            plan.add_step(f"updated {domain} {row.container_name}: {row.expiring_at} -> {request.expiration_date}")
            if row.email:
                self.post_actions.send_extended_email([
                    "--recipient-email", row.email,
                    "--name", row.name,
                    "--username", row.username,
                    "--server-id", row.server_id,
                    "--container-name", row.container_name,
                    "--current-expiration", row.expiring_at,
                    "--new-expiration", request.expiration_date,
                    "--allocated-ports", row.ports,
                ])
        for domain in sorted(updated_domains):
            self.post_actions.backup_database(domain)
        if updated_domains:
            self.post_actions.update_exports()
        return plan
