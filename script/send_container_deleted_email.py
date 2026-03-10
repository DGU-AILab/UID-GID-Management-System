#!/usr/bin/env python3
"""Send a deletion notification email for a deleted container."""

from __future__ import annotations

import argparse
from datetime import date
from email.message import EmailMessage
from email.utils import formataddr
from pathlib import Path

from email_utils import load_smtp_config, normalize_email, resolve_project_root, send_email


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="삭제된 컨테이너에 대한 사용자 안내 메일을 발송합니다."
    )
    parser.add_argument("--recipient-email", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--server-id", required=True)
    parser.add_argument("--container-name", required=True)
    parser.add_argument("--allocated-ports", default="")
    parser.add_argument("--expiring-date", default="")
    parser.add_argument("--deleted-date", default=date.today().isoformat())
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def build_message(args: argparse.Namespace, smtp_config: dict[str, object], recipient_email: str) -> EmailMessage:
    ports = args.allocated_ports or "없음"
    expiring_line_kr = f"원래 서버 사용 완료 예정일: {args.expiring_date}" if args.expiring_date else ""
    expiring_line_en = f"Original Scheduled Expiration Date: {args.expiring_date}" if args.expiring_date else ""

    lines = [
        f"안녕하세요, {args.name}님.",
        "",
        "아래 컨테이너가 삭제 처리되었습니다.",
        "",
        f"- 이름: {args.name}",
        f"  로그인 아이디: {args.username}",
        f"  배정 서버: {args.server_id}",
        f"  컨테이너 명: {args.container_name}",
        f"  사용 중이던 포트 번호: {ports}",
        f"  삭제 일자: {args.deleted_date}",
    ]
    if expiring_line_kr:
        lines.append(f"  {expiring_line_kr}")
    lines.extend(
        [
            "",
            "문의가 있으면 서버 관리자에게 연락해 주세요.",
            "",
            "이 메일은 UID/GID Management System에서 자동 발송되었으며, 이 주소는 회신을 받지 않습니다.",
            "",
            f"Hello, {args.name}.",
            "",
            "The following container has been deleted.",
            "",
            f"- Name: {args.name}",
            f"  Login ID: {args.username}",
            f"  Assigned Server: {args.server_id}",
            f"  Container Name: {args.container_name}",
            f"  Ports Previously Allocated: {ports}",
            f"  Deleted At: {args.deleted_date}",
        ]
    )
    if expiring_line_en:
        lines.append(f"  {expiring_line_en}")
    lines.extend(
        [
            "",
            "If you have any questions, please contact the server administrators.",
            "",
            "This email was sent automatically by the UID/GID Management System, and replies to this address are not monitored.",
        ]
    )

    message = EmailMessage()
    message["Subject"] = f"[DGU AILab] 컨테이너 삭제 안내 ({args.deleted_date})"
    message["From"] = formataddr((str(smtp_config["from_name"]), str(smtp_config["from_email"])))
    message["To"] = recipient_email
    cc_emails = list(smtp_config.get("cc_emails") or [])
    if cc_emails and not smtp_config.get("to_override"):
        message["Cc"] = ", ".join(cc_emails)
    if smtp_config.get("reply_to"):
        message["Reply-To"] = str(smtp_config["reply_to"])
    message.set_content("\n".join(lines))
    return message


def main() -> int:
    args = parse_args()
    project_root = resolve_project_root(__file__)
    smtp_config = load_smtp_config(project_root)

    normalized_recipient = normalize_email(args.recipient_email)
    if not normalized_recipient:
        raise ValueError(f"Invalid recipient email: {args.recipient_email}")

    effective_recipient = str(smtp_config.get("to_override") or normalized_recipient)
    if smtp_config.get("to_override") and smtp_config.get("cc_emails"):
        print("[INFO] EMAIL_TO_OVERRIDE is set. Admin CC recipients are suppressed for test delivery.")

    message = build_message(args, smtp_config, effective_recipient)

    if args.dry_run:
        print(f"[DRY-RUN] Prepared deletion notification for {effective_recipient}")
        return 0

    send_email(message, smtp_config)
    print(f"Deletion notification sent to {effective_recipient}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
