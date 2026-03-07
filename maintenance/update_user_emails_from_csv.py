#!/usr/bin/env python3
"""
CSV 파일을 기준으로 user.email 컬럼을 이름(name) 기준으로 갱신합니다.

기본 CSV 경로:
    ../excel_exports/user_note_emails.csv

규칙:
    - 같은 이름이 CSV에 여러 번 나와도 이메일이 동일하면 허용
    - 같은 이름에 서로 다른 이메일이 있으면 중단
    - CSV에 없는 이름은 건드리지 않음
    - 이메일이 비어 있거나 'NULL'이면 DB에 NULL로 반영
    - 같은 이름의 DB 레코드는 모두 같은 이메일로 갱신
"""

import argparse
import csv
import os
import sys
from collections import defaultdict

import pymysql


def resolve_db_config_path():
    """우선순위에 따라 DB 설정 파일 경로를 반환합니다."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    path = os.path.join(project_root, "config", "db_config.local.env")

    if os.path.exists(path):
        return path

    raise FileNotFoundError(
        "config/db_config.local.env not found. "
        "Copy config/db_config.example.env to config/db_config.local.env first."
    )


def load_db_config():
    """DB 설정 파일에서 데이터베이스 설정을 읽어옵니다."""
    config = {}
    config_file = resolve_db_config_path()

    with open(config_file, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                config[key.strip()] = value.strip()

    return {
        "host": config["DB_HOST"],
        "port": int(config["DB_PORT"]),
        "user": config["DB_USER"],
        "password": config["DB_PASSWORD"],
        "database": config["DB_NAME"],
        "charset": config["DB_CHARSET"],
    }


def normalize_email(value):
    if value is None:
        return None

    stripped = value.strip()
    if not stripped or stripped.upper() == "NULL":
        return None
    return stripped


def detect_email_column(fieldnames):
    for candidate in ("email", "email_from_note"):
        if candidate in fieldnames:
            return candidate

    raise ValueError(
        "CSV must contain one of these columns: email, email_from_note"
    )


def load_email_updates(csv_path):
    grouped_emails = defaultdict(set)

    with open(csv_path, "r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)

        if not reader.fieldnames or "name" not in reader.fieldnames:
            raise ValueError("CSV must contain a 'name' column")

        email_column = detect_email_column(reader.fieldnames)

        for row in reader:
            name = (row.get("name") or "").strip()
            if not name:
                continue

            grouped_emails[name].add(normalize_email(row.get(email_column)))

    updates = {}
    conflicts = {}

    for name, email_values in grouped_emails.items():
        non_null_emails = {email for email in email_values if email is not None}

        if len(non_null_emails) > 1:
            conflicts[name] = sorted(non_null_emails)
            continue

        updates[name] = next(iter(non_null_emails), None)

    return updates, conflicts


def fetch_db_name_counts(cursor):
    cursor.execute(
        """
        SELECT name, COUNT(*) AS row_count
        FROM user
        GROUP BY name
        """
    )
    return {name: row_count for name, row_count in cursor.fetchall()}


def apply_updates(db_config, updates, dry_run=False):
    connection = pymysql.connect(**db_config)

    try:
        with connection.cursor() as cursor:
            db_name_counts = fetch_db_name_counts(cursor)
            missing_names = sorted(name for name in updates if name not in db_name_counts)

            planned_updates = []
            for name, email in sorted(updates.items()):
                if name not in db_name_counts:
                    continue
                planned_updates.append((name, email, db_name_counts[name]))

            print(f"CSV names loaded: {len(updates)}")
            print(f"DB names matched: {len(planned_updates)}")
            print(f"DB names missing from CSV update: {len(missing_names)}")

            if missing_names:
                print("Missing names in DB:")
                for name in missing_names:
                    print(f"  - {name}")

            if dry_run:
                print("\n[DRY-RUN] Planned updates:")
                for name, email, row_count in planned_updates:
                    print(f"  - {name}: {email or 'NULL'} ({row_count} row(s))")
                return

            updated_rows = 0
            for name, email, _row_count in planned_updates:
                cursor.execute(
                    "UPDATE user SET email = %s WHERE name = %s",
                    (email, name),
                )
                updated_rows += cursor.rowcount

        connection.commit()
        print(f"\nUpdated rows: {updated_rows}")

    except pymysql.Error:
        connection.rollback()
        raise
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(
        description="CSV 파일 기준으로 user.email 컬럼을 이름 기준으로 갱신합니다."
    )
    parser.add_argument(
        "--csv",
        default=os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "excel_exports",
            "user_note_emails.csv",
        ),
        help="이메일 정보를 담은 CSV 파일 경로",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="DB를 실제로 변경하지 않고 반영 예정 내용만 출력",
    )

    args = parser.parse_args()

    updates, conflicts = load_email_updates(args.csv)
    if conflicts:
        print("CSV contains conflicting emails for the same name:", file=sys.stderr)
        for name, emails in sorted(conflicts.items()):
            print(f"  - {name}: {', '.join(emails)}", file=sys.stderr)
        sys.exit(1)

    db_config = load_db_config()
    apply_updates(db_config, updates, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
