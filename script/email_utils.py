#!/usr/bin/env python3
"""Common email configuration and delivery helpers for management scripts."""

from __future__ import annotations

import os
import smtplib
import sys
from datetime import datetime
from email.message import EmailMessage
from email.utils import parseaddr
from pathlib import Path
from typing import Dict, List

DEFAULT_SMTP_HOST = "smtp-relay.gmail.com"
DEFAULT_SMTP_PORT = 587
DEFAULT_FROM_NAME = "DGU AILab Server Manager"


def log_event(tag: str, message: str, *, stream=None) -> None:
    timestamp = datetime.now().astimezone().isoformat(timespec="seconds")
    print(f"{timestamp} [{tag}] {message}", file=stream or sys.stdout)


def resolve_project_root(current_file: str) -> Path:
    return Path(current_file).resolve().parent.parent


def load_env_file(path: Path) -> Dict[str, str]:
    values: Dict[str, str] = {}
    if not path.exists():
        return values

    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


def parse_bool(value: str | None, default: bool = False) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "y", "on"}


def normalize_email(value: str | None) -> str | None:
    if value is None:
        return None
    candidate = value.strip()
    if not candidate:
        return None
    _, parsed = parseaddr(candidate)
    if "@" not in parsed:
        return None
    return parsed


def resolve_email_config_path(project_root: Path) -> Path:
    return project_root / "config" / "email_config.local.env"


def resolve_admin_cc_path(project_root: Path) -> Path:
    return project_root / "config" / "reminder_admins.local.txt"


def load_admin_cc_emails(project_root: Path) -> List[str]:
    path = resolve_admin_cc_path(project_root)
    if not path.exists():
        return []

    emails: List[str] = []
    seen = set()
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            normalized = normalize_email(line)
            if not normalized:
                print(f"Warning: ignoring invalid admin CC email: {line}")
                continue
            if normalized in seen:
                continue
            seen.add(normalized)
            emails.append(normalized)
    return emails


def load_smtp_config(project_root: Path) -> Dict[str, object]:
    file_values = load_env_file(resolve_email_config_path(project_root))

    def get_value(key: str, default: str | None = None) -> str | None:
        return os.environ.get(key, file_values.get(key, default))

    smtp_from = get_value("SMTP_FROM")
    if not smtp_from:
        raise ValueError(
            "SMTP_FROM is required. Set it in the environment or config/email_config.local.env."
        )

    return {
        "host": get_value("SMTP_HOST", DEFAULT_SMTP_HOST),
        "port": int(get_value("SMTP_PORT", str(DEFAULT_SMTP_PORT))),
        "use_tls": parse_bool(get_value("SMTP_USE_TLS"), default=True),
        "username": get_value("SMTP_USERNAME"),
        "password": get_value("SMTP_PASSWORD"),
        "from_email": smtp_from,
        "from_name": get_value("SMTP_FROM_NAME", DEFAULT_FROM_NAME),
        "reply_to": get_value("SMTP_REPLY_TO"),
        "to_override": get_value("EMAIL_TO_OVERRIDE"),
        "timeout": int(get_value("SMTP_TIMEOUT", "30")),
        "support_manual_url": get_value("SUPPORT_MANUAL_URL"),
        "error_report_form_url": get_value("ERROR_REPORT_FORM_URL"),
        "cc_emails": load_admin_cc_emails(project_root),
    }


def send_email(message: EmailMessage, smtp_config: Dict[str, object]) -> None:
    host = str(smtp_config["host"])
    port = int(smtp_config["port"])
    timeout = int(smtp_config["timeout"])
    use_tls = bool(smtp_config["use_tls"])
    username = smtp_config.get("username")
    password = smtp_config.get("password")

    if use_tls and port == 465:
        server: smtplib.SMTP = smtplib.SMTP_SSL(host, port, timeout=timeout)
    else:
        server = smtplib.SMTP(host, port, timeout=timeout)

    with server:
        server.ehlo()
        if use_tls and port != 465:
            server.starttls()
            server.ehlo()
        if username:
            server.login(str(username), str(password or ""))
        server.send_message(message)
