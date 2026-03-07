#!/usr/bin/env python3
"""Send expiration reminder emails for containers expiring in 7, 3, and 1 days."""

from __future__ import annotations

import argparse
import os
import smtplib
import sys
from collections import defaultdict
from datetime import date, datetime
from email.message import EmailMessage
from email.utils import formataddr, parseaddr
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

import pymysql

DEFAULT_REMINDER_DAYS = (7, 3, 1)
DEFAULT_SMTP_HOST = "smtp-relay.gmail.com"
DEFAULT_SMTP_PORT = 587
DEFAULT_FROM_NAME = "DGU AILab Server Manager"
VALID_DOMAINS = ("LAB", "FARM")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="만료 예정 컨테이너 사용자에게 7/3/1일 전 이메일을 발송합니다."
    )
    parser.add_argument(
        "--today",
        default=date.today().isoformat(),
        help="기준 날짜 (YYYY-MM-DD). 기본값은 오늘 날짜.",
    )
    parser.add_argument(
        "--days",
        default="7,3,1",
        help="안내 메일을 발송할 일 수 목록. 예: 7,3,1",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="메일을 실제로 보내지 않고 발송 예정 목록만 출력합니다.",
    )
    parser.add_argument(
        "--domains",
        help="조회할 도메인 목록 (예: LAB,FARM). 기본값은 설정 파일의 EXPORT_DOMAINS 또는 SERVER_DOMAIN.",
    )
    return parser.parse_args()


def parse_bool(value: str | None, default: bool = False) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "y", "on"}


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


def resolve_db_config_path() -> Path:
    script_dir = Path(__file__).resolve().parent
    project_root = script_dir.parent
    db_config_path = project_root / "config" / "db_config.local.env"
    if db_config_path.exists():
        return db_config_path
    raise FileNotFoundError(
        "config/db_config.local.env not found. Copy config/db_config.example.env to config/db_config.local.env first."
    )


def load_raw_db_config() -> Dict[str, str]:
    return load_env_file(resolve_db_config_path())


def normalize_domain(domain_name: str) -> str:
    normalized = domain_name.strip().upper()
    if normalized not in VALID_DOMAINS:
        raise ValueError(f"Unsupported domain: {domain_name}")
    return normalized


def resolve_domains(raw_config: Dict[str, str], raw_domains: str | None) -> List[str]:
    domains_value = raw_domains or raw_config.get("EXPORT_DOMAINS") or raw_config.get("SERVER_DOMAIN") or "LAB"
    domains = [normalize_domain(item) for item in domains_value.split(",") if item.strip()]
    if not domains:
        raise ValueError("At least one domain is required.")
    return list(dict.fromkeys(domains))


def resolve_db_host_for_domain(raw_config: Dict[str, str], domain_name: str) -> str:
    specific_key = f"{domain_name}_DB_HOST"
    if raw_config.get(specific_key):
        return raw_config[specific_key]
    if raw_config.get("DB_HOST"):
        return raw_config["DB_HOST"]
    raise ValueError(f"{specific_key} or DB_HOST must be configured.")


def build_db_config(raw_config: Dict[str, str], domain_name: str) -> Dict[str, object]:
    return {
        "host": resolve_db_host_for_domain(raw_config, domain_name),
        "port": int(raw_config["DB_PORT"]),
        "user": raw_config["DB_USER"],
        "password": raw_config["DB_PASSWORD"],
        "database": raw_config["DB_NAME"],
        "charset": raw_config["DB_CHARSET"],
        "cursorclass": pymysql.cursors.DictCursor,
        "autocommit": False,
    }


def load_smtp_config() -> Dict[str, object]:
    script_dir = Path(__file__).resolve().parent
    project_root = script_dir.parent
    file_values = load_env_file(project_root / "config" / "email_config.local.env")

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
    }


def ensure_notification_log_table(cursor: pymysql.cursors.Cursor) -> None:
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS expiration_email_notifications (
            id INT PRIMARY KEY AUTO_INCREMENT,
            docker_container_id INT NOT NULL,
            reminder_days INT NOT NULL,
            scheduled_expiry_date DATE NOT NULL,
            notification_date DATE NOT NULL,
            recipient_email VARCHAR(255) NOT NULL,
            sent_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            UNIQUE KEY unique_notification (
                docker_container_id,
                reminder_days,
                notification_date
            ),
            CONSTRAINT fk_expiration_email_notifications_container
                FOREIGN KEY (docker_container_id) REFERENCES docker_container(id)
                ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
        """
    )


def parse_days_argument(raw_days: str) -> Tuple[int, ...]:
    days: List[int] = []
    for token in raw_days.split(","):
        token = token.strip()
        if not token:
            continue
        value = int(token)
        if value < 0:
            raise ValueError("Reminder days must be non-negative integers.")
        days.append(value)

    if not days:
        raise ValueError("At least one reminder day is required.")

    return tuple(sorted(set(days), reverse=True))


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


def fetch_pending_reminders(
    cursor: pymysql.cursors.Cursor,
    domain_name: str,
    today_value: date,
    reminder_days: Tuple[int, ...],
) -> List[Dict[str, object]]:
    placeholders = ", ".join(["%s"] * len(reminder_days))
    query = f"""
        SELECT
            dc.id AS docker_container_id,
            u.id AS user_id,
            u.name,
            u.ubuntu_username,
            u.email,
            dc.server_id,
            dc.container_name,
            dc.image,
            dc.image_version,
            DATE(dc.expiring_at) AS expiring_date,
            DATEDIFF(DATE(dc.expiring_at), %s) AS reminder_days
        FROM docker_container dc
        JOIN user u ON u.id = dc.user_id
        LEFT JOIN expiration_email_notifications log
            ON log.docker_container_id = dc.id
            AND log.reminder_days = DATEDIFF(DATE(dc.expiring_at), %s)
            AND log.notification_date = %s
        WHERE dc.existing = TRUE
          AND u.email IS NOT NULL
          AND TRIM(u.email) <> ''
          AND DATEDIFF(DATE(dc.expiring_at), %s) IN ({placeholders})
          AND log.id IS NULL
        ORDER BY reminder_days DESC, u.email ASC, dc.server_id ASC, dc.container_name ASC
    """
    params: List[object] = [
        today_value,
        today_value,
        today_value,
        today_value,
        *reminder_days,
    ]
    cursor.execute(query, params)
    rows = cursor.fetchall()

    valid_rows = []
    invalid_email_rows = 0
    for row in rows:
        normalized = normalize_email(row["email"])
        if not normalized:
            invalid_email_rows += 1
            continue
        row["domain_name"] = domain_name
        row["email"] = normalized
        valid_rows.append(row)

    if invalid_email_rows:
        print(f"[{domain_name}] Skipped {invalid_email_rows} row(s) with invalid email addresses.")

    return valid_rows


def build_email_groups(
    rows: Iterable[Dict[str, object]],
) -> Dict[Tuple[str, int], List[Dict[str, object]]]:
    grouped: Dict[Tuple[str, int], List[Dict[str, object]]] = defaultdict(list)
    for row in rows:
        key = (str(row["email"]), int(row["reminder_days"]))
        grouped[key].append(row)
    return grouped


def build_email_message(
    smtp_config: Dict[str, object],
    recipient_email: str,
    reminder_days: int,
    rows: List[Dict[str, object]],
) -> EmailMessage:
    display_names = sorted({str(row["name"]).strip() for row in rows if row["name"]})
    salutation = ", ".join(display_names) if display_names else "사용자"
    expiring_dates = sorted({str(row["expiring_date"]) for row in rows})

    lines = [
        f"안녕하세요, {salutation}님.",
        "",
        f"아래 컨테이너의 서버 사용 완료 예정일이 {reminder_days}일 남았습니다.",
        "",
    ]

    for row in rows:
        lines.extend(
            [
                f"- 이름: {row['name']}",
                f"  로그인 아이디: {row['ubuntu_username']}",
                f"  도메인: {row['domain_name']}",
                f"  배정 서버: {row['server_id']}",
                f"  컨테이너 명: {row['container_name']}",
                f"  Docker 이미지: {row['image']}:{row['image_version']}",
                f"  서버 사용 완료 예정일: {row['expiring_date']}",
                "",
            ]
        )

    lines.extend(
        [
            "연장 또는 종료 관련 문의가 있으면 서버 관리자에게 미리 알려주세요.",
            "",
            "이 메일은 UID/GID Management System에서 자동 발송되었습니다.",
        ]
    )

    subject_date = expiring_dates[0] if len(expiring_dates) == 1 else ", ".join(expiring_dates)

    message = EmailMessage()
    message["Subject"] = f"[DGU AILab] 서버 사용 완료 예정일 {reminder_days}일 전 안내 ({subject_date})"
    message["From"] = formataddr((str(smtp_config["from_name"]), str(smtp_config["from_email"])))
    message["To"] = recipient_email
    if smtp_config.get("reply_to"):
        message["Reply-To"] = str(smtp_config["reply_to"])
    message.set_content("\n".join(lines))
    return message


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


def insert_notification_logs(
    cursor: pymysql.cursors.Cursor,
    rows: List[Dict[str, object]],
    reminder_days: int,
    notification_date: date,
    recipient_email: str,
) -> None:
    cursor.executemany(
        """
        INSERT INTO expiration_email_notifications (
            docker_container_id,
            reminder_days,
            scheduled_expiry_date,
            notification_date,
            recipient_email
        ) VALUES (%s, %s, %s, %s, %s)
        """,
        [
            (
                row["docker_container_id"],
                reminder_days,
                row["expiring_date"],
                notification_date,
                recipient_email,
            )
            for row in rows
        ],
    )


def main() -> int:
    args = parse_args()
    today_value = datetime.strptime(args.today, "%Y-%m-%d").date()
    reminder_days = parse_days_argument(args.days)
    smtp_config = load_smtp_config()
    raw_db_config = load_raw_db_config()
    domains = resolve_domains(raw_db_config, args.domains)

    connections: Dict[str, pymysql.connections.Connection] = {}
    cursors: Dict[str, pymysql.cursors.Cursor] = {}
    sent_email_count = 0
    pending_group_count = 0

    try:
        pending_rows: List[Dict[str, object]] = []
        for domain_name in domains:
            db_config = build_db_config(raw_db_config, domain_name)
            connection = pymysql.connect(**db_config)
            cursor = connection.cursor()
            connections[domain_name] = connection
            cursors[domain_name] = cursor

            ensure_notification_log_table(cursor)
            domain_rows = fetch_pending_reminders(cursor, domain_name, today_value, reminder_days)
            print(
                f"[{domain_name}] Pending reminder rows: {len(domain_rows)} "
                f"({db_config['host']}:{db_config['port']})"
            )
            pending_rows.extend(domain_rows)

        grouped_rows = build_email_groups(pending_rows)
        pending_group_count = len(grouped_rows)

        if not grouped_rows:
            print("No reminder emails to send.")
            for connection in connections.values():
                connection.commit()
            return 0

        for (recipient_email, days_left), rows in grouped_rows.items():
            effective_recipient = str(smtp_config.get("to_override") or recipient_email)
            message = build_email_message(
                smtp_config=smtp_config,
                recipient_email=effective_recipient,
                reminder_days=days_left,
                rows=rows,
            )

            print(
                f"{'[DRY-RUN] ' if args.dry_run else ''}"
                f"Prepared reminder for {effective_recipient}: "
                f"{len(rows)} container(s), {days_left} day(s) left."
            )

            if args.dry_run:
                continue

            send_email(message, smtp_config)
            rows_by_domain: Dict[str, List[Dict[str, object]]] = defaultdict(list)
            for row in rows:
                rows_by_domain[str(row["domain_name"])].append(row)

            for domain_name, domain_rows in rows_by_domain.items():
                insert_notification_logs(
                    cursor=cursors[domain_name],
                    rows=domain_rows,
                    reminder_days=days_left,
                    notification_date=today_value,
                    recipient_email=effective_recipient,
                )
            sent_email_count += 1

        for connection in connections.values():
            connection.commit()
    except Exception:
        for connection in connections.values():
            connection.rollback()
        raise
    finally:
        for cursor in cursors.values():
            cursor.close()
        for connection in connections.values():
            connection.close()

    if args.dry_run:
        print(f"[DRY-RUN] Pending reminder groups: {pending_group_count}")
    else:
        print(f"Sent {sent_email_count} reminder email(s).")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # pragma: no cover - CLI error path
        print(f"Error: {exc}", file=sys.stderr)
        raise
