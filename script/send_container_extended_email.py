#!/usr/bin/env python3
"""Send a container expiration extension notification email."""

from __future__ import annotations

import argparse
import sys
from email.message import EmailMessage
from email.utils import formataddr

from email_utils import load_smtp_config, log_event, normalize_email, resolve_project_root, send_email


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="사용 기한이 연장된 컨테이너에 대한 사용자 안내 메일을 발송합니다."
    )
    parser.add_argument("--recipient-email", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--server-id", required=True)
    parser.add_argument("--container-name", required=True)
    parser.add_argument("--current-expiration", required=True)
    parser.add_argument("--new-expiration", required=True)
    parser.add_argument("--allocated-ports", default="")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def resolve_error_report_form_url(smtp_config: dict[str, object], server_id: str) -> str:
    domain = "".join(ch for ch in server_id if ch.isalpha()).lower()
    domain_key = f"error_report_form_url_{domain}"
    return str(
        smtp_config.get(domain_key)
        or smtp_config.get("error_report_form_url")
        or "https://forms.gle/nACaxj2UeJF56V2i7"
    )


def build_message(
    args: argparse.Namespace,
    smtp_config: dict[str, object],
    recipient_email: str,
) -> EmailMessage:
    form_url = resolve_error_report_form_url(smtp_config, args.server_id)
    manual_url = str(smtp_config.get("support_manual_url") or "").strip()
    ports = args.allocated_ports or "없음"

    lines = [
        f"안녕하세요 {args.name}님, 동국대학교 서버관리팀입니다.",
        "",
        "아래 서버의 사용 기한 연장이 완료되었습니다.",
        "",
        "[연장 정보]",
        f"- 접속 아이디(username): {args.username}",
        f"- 배정 서버: {args.server_id}",
        f"- 컨테이너 명: {args.container_name}",
        f"- 포트 번호: {ports}",
        f"- 기존 만료일: {args.current_expiration}",
        f"- 변경 만료일: {args.new_expiration}",
    ]

    if manual_url:
        lines.extend(["", "[사용자 매뉴얼]", f"- {manual_url}"])

    lines.extend(
        [
            "",
            "[문의 및 오류 신고]",
            f"- 오류 신고, 컨테이너 사용 기한 연장, 기타 질문은 아래 구글 폼으로 신청해주세요.",
            f"- 구글 폼: {form_url}",
            "",
            "감사합니다.",
        ]
    )

    message = EmailMessage()
    message["Subject"] = f"[DGU AILab] 서버 사용 기한 연장 안내 ({args.new_expiration})"
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
        log_event("EXTEND", "email_override_enabled cc_suppressed=true")

    message = build_message(args, smtp_config, effective_recipient)

    if args.dry_run:
        log_event(
            "EXTEND",
            f"extension_notification_prepared mode=dry-run recipient={effective_recipient} "
            f"username={args.username} server={args.server_id}",
        )
        return 0

    send_email(message, smtp_config)
    log_event(
        "EXTEND",
        f"extension_notification_sent recipient={effective_recipient} "
        f"username={args.username} server={args.server_id}",
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        log_event("ERROR", f"extension_notification_exception error={exc}", stream=sys.stderr)
        raise
