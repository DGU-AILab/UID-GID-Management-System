from __future__ import annotations

import gzip
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Sequence

from .config import PROJECT_ROOT, AppConfig
from .runners import LocalRunner


class PostActions:
    def __init__(self, runner: LocalRunner | None = None, project_root: Path = PROJECT_ROOT, config: AppConfig | None = None) -> None:
        self.runner = runner or LocalRunner()
        self.project_root = project_root
        self.config = config

    def _print_result_output(self, stdout: str, stderr: str) -> None:
        if stdout:
            print(stdout, end="" if stdout.endswith("\n") else "\n")
        if stderr:
            print(stderr, end="" if stderr.endswith("\n") else "\n")

    def backup_database(self, domain: str) -> None:
        if self.config is None:
            print(f"database_backup_skipped domain={domain} reason=config_unavailable")
            return
        backup_dir = Path(self.config.backup_root_dir) / domain.lower()
        backup_dir.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        backup_file = backup_dir / f"nfs_db_backup_{timestamp}.sql.gz"
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as cnf:
            cnf.write("[client]\n")
            cnf.write(f"user={self.config.db_user}\n")
            cnf.write(f"password={self.config.db_password}\n")
            cnf.write(f"host={self.config.db_host_for_domain(domain)}\n")
            cnf.write(f"port={self.config.db_port}\n")
            cnf_path = Path(cnf.name)
        try:
            result = self.runner.run(["mysqldump", f"--defaults-extra-file={cnf_path}", "--no-tablespaces", self.config.db_name], check=False)
            if result.returncode != 0:
                self._print_result_output(result.stdout, result.stderr)
                print(f"database_backup_failed domain={domain} path={backup_file}")
                return
            with gzip.open(backup_file, "wt", encoding="utf-8") as handle:
                handle.write(result.stdout)
            print(f"database_backup_created domain={domain} path={backup_file}")
        finally:
            cnf_path.unlink(missing_ok=True)

    def update_exports(self) -> None:
        script = self.project_root / "script" / "export_users_to_excel.py"
        if script.exists():
            result = self.runner.run(["python3", str(script), "--domains", "LAB,FARM"], check=False)
            self._print_result_output(result.stdout, result.stderr)

    def send_created_email(self, args: Sequence[str]) -> None:
        script = self.project_root / "script" / "send_container_created_email.py"
        if script.exists():
            result = self.runner.run(["python3", str(script), *args], check=False)
            self._print_result_output(result.stdout, result.stderr)

    def send_deleted_email(self, args: Sequence[str]) -> None:
        script = self.project_root / "script" / "send_container_deleted_email.py"
        if script.exists():
            result = self.runner.run(["python3", str(script), *args], check=False)
            self._print_result_output(result.stdout, result.stderr)

    def send_extended_email(self, args: Sequence[str]) -> None:
        script = self.project_root / "script" / "send_container_extended_email.py"
        if script.exists():
            result = self.runner.run(["python3", str(script), *args], check=False)
            self._print_result_output(result.stdout, result.stderr)
