from __future__ import annotations

from typing import Dict, Iterable, List, Mapping

from ..models import ContainerRecord, OperationPlan
from ..runners import LocalRunner


class ContainerSyncService:
    def __init__(self, runner: LocalRunner | None = None) -> None:
        self.runner = runner or LocalRunner()

    def plan_from_records(self, records: Iterable[ContainerRecord], running_names: Iterable[str] | Mapping[str, str], dry_run: bool = True, auto_delete: bool = False) -> OperationPlan:
        records = list(records)
        db_names = {record.container_name for record in records}
        states = dict(running_names) if isinstance(running_names, Mapping) else {name: "running" for name in running_names}
        running = set(states)
        plan = OperationPlan("sync-containers plan")
        for record in records:
            if record.container_name not in running:
                plan.add_step(f"CREATE {record.container_name} image=dguailab/{record.image}:{record.image_version} user={record.username}")
            elif states.get(record.container_name) == "exited":
                plan.add_step(f"RESTART {record.container_name}")
            else:
                plan.add_step(f"OK {record.container_name}")
        for name in sorted(running - db_names):
            if auto_delete:
                plan.add_step(f"DELETE {name} not in DB")
            else:
                plan.add_step(f"WARN {name} exists on server but not DB")
        return plan

    def list_local_container_states(self) -> dict[str, str]:
        result = self.runner.run(["docker", "ps", "-a", "--format", "{{.Names}} {{.State}}"], check=True)
        states: dict[str, str] = {}
        for line in result.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 2:
                states[parts[0]] = parts[1]
        return states

    def execute(self, records: Iterable[ContainerRecord], dry_run: bool = True, auto_delete: bool = False) -> OperationPlan:
        records = list(records)
        states = self.list_local_container_states()
        plan = self.plan_from_records(records, states, dry_run=dry_run, auto_delete=auto_delete)
        if dry_run:
            return plan
        by_name = {record.container_name: record for record in records}
        for step in plan.steps:
            if step.startswith("DELETE ") and auto_delete:
                name = step.split()[1]
                self.runner.run(["docker", "rm", "-f", name], check=False)
            elif step.startswith("CREATE "):
                name = step.split()[1]
                self.runner.run(self.build_create_command(by_name[name]), check=True)
            elif step.startswith("RESTART "):
                name = step.split()[1]
                self.runner.run(["docker", "start", name], check=True)
        return plan

    def build_create_command(self, record: ContainerRecord) -> list[str]:
        port_args: list[str] = []
        for host_port, purpose in self._parse_port_specs(record):
            container_port = self._container_port_for_purpose(host_port, purpose)
            port_args.extend(["-p", f"{host_port}:{container_port}"])
        return [
            "docker",
            "run",
            "-dit",
            "--init",
            "--name",
            record.container_name,
            *port_args,
            "-e",
            f"USER_ID={record.username}",
            "-e",
            f"UID={record.uid}",
            "-e",
            f"GID={record.gid}",
            f"dguailab/{record.image}:{record.image_version}",
        ]

    @staticmethod
    def _parse_port_specs(record: ContainerRecord) -> list[tuple[int, str]]:
        if record.port_specs:
            specs = []
            for raw in record.port_specs.split("|"):
                if not raw:
                    continue
                host_port, purpose = raw.split(":", 1)
                specs.append((int(host_port), purpose))
            return specs
        return [(int(port.strip()), "") for port in record.ports.split(",") if port.strip()]

    @staticmethod
    def _container_port_for_purpose(host_port: int, purpose: str) -> int:
        if purpose == "ssh":
            return 22
        if purpose == "jupyter notebook":
            return 8888
        if purpose == "vnc":
            return 6080
        prefix = "container port "
        if purpose.startswith(prefix):
            return int(purpose[len(prefix):])
        return host_port
