#!/usr/bin/env python3
"""Send a container allocation notification email after successful creation."""

from __future__ import annotations

import argparse
import json
import sys
from email.message import EmailMessage
from email.utils import formataddr
from pathlib import Path

from email_utils import load_smtp_config, log_event, normalize_email, resolve_project_root, send_email

EXCLUDED_CREATE_CC_EMAILS = {"tonyno193@gmail.com"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="생성 완료된 컨테이너에 대한 사용자 안내 메일을 발송합니다."
    )
    parser.add_argument("--recipient-email", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--server-id", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--ssh-port", required=True)
    parser.add_argument("--jupyter-port", required=True)
    parser.add_argument("--additional-port-mappings", default="")
    parser.add_argument("--vnc-port", default="")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def resolve_domain(server_id: str) -> str:
    prefix = "".join(ch for ch in server_id if ch.isalpha()).upper()
    if prefix not in {"LAB", "FARM"}:
        raise ValueError(f"Unsupported server id: {server_id}")
    return prefix


def load_domain_public_ip(project_root: Path, domain: str) -> str:
    topology_path = project_root / "config" / "network_topology.json"
    with topology_path.open("r", encoding="utf-8") as handle:
        topology = json.load(handle)
    return str(topology["domains"][domain]["public_ip"])


def resolve_error_report_form_url(smtp_config: dict[str, object], domain: str) -> str:
    domain_key = f"error_report_form_url_{domain.lower()}"
    return str(
        smtp_config.get(domain_key)
        or smtp_config.get("error_report_form_url")
        or "https://forms.gle/nACaxj2UeJF56V2i7"
    )


def format_additional_ports(raw_mappings: str) -> list[str]:
    mappings = []
    for raw_mapping in raw_mappings.split(","):
        mapping = raw_mapping.strip()
        if not mapping:
            continue
        if ":" in mapping:
            host_port, container_port = mapping.split(":", 1)
            mappings.append(f"{host_port}(외부) -> {container_port}(내부)")
        else:
            mappings.append(mapping)
    return mappings


def filtered_cc_emails(smtp_config: dict[str, object], recipient_email: str) -> list[str]:
    cc_emails = []
    seen = {recipient_email.lower()}
    for email in smtp_config.get("cc_emails") or []:
        normalized = normalize_email(str(email))
        if not normalized:
            continue
        lowered = normalized.lower()
        if lowered in EXCLUDED_CREATE_CC_EMAILS or lowered in seen:
            continue
        seen.add(lowered)
        cc_emails.append(normalized)
    return cc_emails


def build_message(
    args: argparse.Namespace,
    smtp_config: dict[str, object],
    recipient_email: str,
    public_ip: str,
    form_url: str,
) -> EmailMessage:
    image_label = f"{args.image}:{args.version}"
    additional_ports = format_additional_ports(args.additional_port_mappings)
    additional_port_lines = additional_ports or ["없음"]
    manual_url = str(smtp_config.get("support_manual_url") or "").strip()

    lines = [
        f"안녕하세요 {args.name}님, 동국대학교 서버관리팀입니다.",
        "",
        "서버 배정이 완료되었으며, 배정된 서버의 정보는 다음과 같습니다.",
        "",
        "[서버 정보]",
        f"- 이미지 버전: {image_label}",
        f"- 접속 아이디(username): {args.username}",
        f"- SSH 포트번호: {args.ssh_port}",
        f"- JUPYTER 포트번호: {args.jupyter_port}",
    ]
    if args.vnc_port:
        lines.append(f"- VNC 포트번호: {args.vnc_port}")
    for index, additional_port in enumerate(additional_port_lines):
        label = "- 추가 포트" if index == 0 else "- 추가 포트"
        lines.append(f"{label}: {additional_port}")

    lines.extend(
        [
            "",
            "[접속 정보]",
            f"- SSH 접속 명령어: ssh -p {args.ssh_port} {args.username}@{public_ip}",
            f"- JupyterLab 웹페이지 주소: http://{public_ip}:{args.jupyter_port}",
            f"- JupyterLab token 위치: /home/{args.username}/decs_jupyter_lab/jupyter_token.txt",
        ]
    )

    if args.vnc_port:
        lines.extend(
            [
                f"- GUI/noVNC 접속 URL: http://{public_ip}:{args.vnc_port}",
                f"- VNC 비밀번호 저장 위치: /home/{args.username}/vnc_password.txt",
            ]
        )

    lines.extend(
        [
            "",
            "[초기 설정]",
            "- 현재 제공 받은 기본 패스워드는 보안을 위해 반드시 변경해주세요.",
            "- 24시간 내에 변경하지 않을 경우 컨테이너가 경고없이 삭제될 수 있습니다.",
            f"- SSH/Ubuntu 비밀번호 변경 방법: sudo passwd {args.username}",
            "- JupyterLab Password도 제공된 token 값을 사용하여 변경해주세요.",
        ]
    )

    if args.vnc_port:
        lines.extend(
            [
                "- VNC 비밀번호도 반드시 변경해주세요. VNC 비밀번호는 최대 8자까지만 사용됩니다.",
                "- VNC 비밀번호 변경 방법: vncpasswd",
                f"- 컨테이너 재시작 후에도 같은 VNC 비밀번호를 사용하려면 변경한 비밀번호를 /home/{args.username}/vnc_password.txt에도 저장해주세요.",
            ]
        )

    if manual_url:
        lines.extend(["", "[사용자 매뉴얼]", f"- {manual_url}"])

    lines.extend(
        [
            "",
            "[문의 및 오류 신고]",
            f"- 오류 신고, 컨테이너 사용 기한 연장, 기타 질문은 아래 구글 폼으로 신청해주세요.",
            f"- 구글 폼: {form_url}",
            "- 구글 폼 응답은 '오류신고및문의' 채널에서 사용자 및 관리자 전원에게 공유됩니다.",
            "- 오류 신고 시 출력된 오류 메시지, 오류 발생 시각, 오류가 발생한 상황을 상세히 적어주세요.",
            "- 오류 신고 후에는 해당 채널 알림을 활성화하고, 관리자의 요청 또는 질문에 12시간 내에 답변해주세요.",
            "",
            "[주의 사항]",
            "- 서버 사용 중 본인의 실수, 매뉴얼 미숙지, 관리자 요청사항 미응답으로 발생하는 문제는 사용자 본인에게 책임이 있습니다.",
            "- 사용자 매뉴얼에 따라 디버깅하지 않고 오류 신고를 반복할 경우 지도교수에게 전달되고 계정이 폐쇄될 수 있습니다.",
            "- 관리자에게 개별 연락(DM, 카카오톡 등)은 불가능합니다. 오류 신고는 반드시 구글 폼으로 접수해주세요.",
            "- 서버 관리자에게 오는 개별 연락(DM, 카카오톡 등)은 답변드리지 않습니다.",
            "",
            "마지막으로, 사용자분의 데이터는 시스템에서 백업되지 않습니다. 개인적인 데이터는 모두 백업하시기 바랍니다. 감사합니다!",
        ]
    )

    message = EmailMessage()
    message["Subject"] = f"[DGU AILab] 서버 배정 안내 ({args.server_id})"
    message["From"] = formataddr((str(smtp_config["from_name"]), str(smtp_config["from_email"])))
    message["To"] = recipient_email
    cc_emails = filtered_cc_emails(smtp_config, recipient_email)
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

    domain = resolve_domain(args.server_id)
    public_ip = load_domain_public_ip(project_root, domain)
    form_url = resolve_error_report_form_url(smtp_config, domain)
    effective_recipient = str(smtp_config.get("to_override") or normalized_recipient)
    if smtp_config.get("to_override") and smtp_config.get("cc_emails"):
        log_event("CREATE", "email_override_enabled cc_suppressed=true")

    message = build_message(args, smtp_config, effective_recipient, public_ip, form_url)

    if args.dry_run:
        log_event(
            "CREATE",
            f"creation_notification_prepared mode=dry-run recipient={effective_recipient} "
            f"username={args.username} server={args.server_id}",
        )
        return 0

    send_email(message, smtp_config)
    log_event(
        "CREATE",
        f"creation_notification_sent recipient={effective_recipient} "
        f"username={args.username} server={args.server_id}",
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        log_event("ERROR", f"creation_notification_exception error={exc}", stream=sys.stderr)
        raise
