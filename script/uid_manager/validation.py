from __future__ import annotations

import re
from datetime import datetime

from .errors import ValidationError

IDENTITY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]{0,63}$")


def validate_identity_name(name: str, label: str = "name") -> str:
    if not IDENTITY_RE.fullmatch(name or ""):
        raise ValidationError(f"{label} must match {IDENTITY_RE.pattern}")
    return name


def validate_date(value: str, label: str = "date") -> str:
    try:
        datetime.strptime(value, "%Y-%m-%d")
    except ValueError as exc:
        raise ValidationError(f"{label} must be YYYY-MM-DD") from exc
    return value


def validate_numeric(value: str | int, label: str) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError) as exc:
        raise ValidationError(f"{label} must be numeric") from exc
    return number


def sql_escape(value: str) -> str:
    return value.replace("'", "''")
