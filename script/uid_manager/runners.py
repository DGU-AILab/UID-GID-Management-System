from __future__ import annotations

import shlex
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence

from .errors import RemoteCommandError


@dataclass(frozen=True)
class CommandResult:
    args: Sequence[str]
    stdout: str = ""
    stderr: str = ""
    returncode: int = 0


class LocalRunner:
    def run(self, args: Sequence[str], check: bool = True, cwd: Optional[Path] = None) -> CommandResult:
        completed = subprocess.run(
            list(args),
            cwd=str(cwd) if cwd else None,
            text=True,
            capture_output=True,
            check=False,
        )
        result = CommandResult(args=args, stdout=completed.stdout, stderr=completed.stderr, returncode=completed.returncode)
        if check and completed.returncode != 0:
            raise RemoteCommandError(f"command failed: {' '.join(args)}\n{completed.stderr}")
        return result


class AnsibleRunner:
    def __init__(self, inventory: str, local_runner: Optional[LocalRunner] = None) -> None:
        self.inventory = inventory
        self.local_runner = local_runner or LocalRunner()

    def shell(self, host: str, command: str, check: bool = True) -> CommandResult:
        return self.local_runner.run(["ansible", host, "-i", self.inventory, "-m", "shell", "-a", command], check=check)

    def raw(
        self,
        host: str,
        command: str,
        *,
        user: str,
        port: int,
        private_key: str = "",
        ssh_common_args: str = "",
        check: bool = True,
    ) -> CommandResult:
        args: List[str] = [
            "ansible",
            host,
            "-i",
            f"{host},",
            "-u",
            user,
            "-e",
            f"ansible_port={port}",
            "-m",
            "raw",
            "-a",
            command,
        ]
        if private_key:
            args.extend(["--private-key", private_key])
        if ssh_common_args:
            args.extend(["-e", f"ansible_ssh_common_args={shlex.quote(ssh_common_args)}"])
        return self.local_runner.run(args, check=check)

    def playbook(
        self,
        playbook: Path,
        *,
        extra_vars: Optional[Dict[str, object]] = None,
        inventory: Optional[str] = None,
        check: bool = True,
    ) -> CommandResult:
        args: List[str] = ["ansible-playbook", "-i", inventory or self.inventory, str(playbook)]
        for key, value in (extra_vars or {}).items():
            args.extend(["-e", f"{key}={value}"])
        return self.local_runner.run(args, check=check)


class RecordingRunner(LocalRunner):
    """Test helper that records commands without executing them."""

    def __init__(self, outputs: Optional[Iterable[str]] = None) -> None:
        self.commands: List[Sequence[str]] = []
        self.outputs = list(outputs or [])

    def run(self, args: Sequence[str], check: bool = True, cwd: Optional[Path] = None) -> CommandResult:
        self.commands.append(tuple(args))
        stdout = self.outputs.pop(0) if self.outputs else ""
        return CommandResult(args=args, stdout=stdout)
