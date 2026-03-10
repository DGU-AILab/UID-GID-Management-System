# UID/GID Management System

관리 서버에서 LAB/FARM 서버의 컨테이너 생성, 삭제, 사용자 현황 엑셀 추출, 만료 안내 메일 발송을 관리하는 운영용 스크립트 모음입니다.

## 개요

이 저장소는 다음 흐름을 관리합니다.

- 컨테이너 생성: 관리 서버에서 Ansible로 `labN` / `farmN` 서버에 원격 생성
- 컨테이너 삭제: DB soft delete + 원격 Docker 삭제
- 사용자 현황 추출: LAB/FARM DB를 읽어 Excel과 Google Sheets 갱신
- 만료 안내 메일: LAB/FARM DB를 읽어 사용자 이메일로 만료 예정 안내 메일 발송

## 디렉토리 구조

```text
config/
  db_config.example.env
  email_config.example.env
  google-client.example.json
  db_config.local.env           # 로컬 전용, git ignore
  email_config.local.env        # 로컬 전용, git ignore
  google-client.local.json      # Google Sheets 인증 JSON, git ignore

script/
  common_domain_db.sh
  create_container.sh
  delete_container.sh
  extend_container_expiration.sh
  export_users_to_excel.py
  send_expiration_reminder_emails.py

maintenance/
  delete_expired_containers.sh
  delete_user.py
  migrate_add_user_contact_columns.sh
  sync_containers.sh
  update_user_emails_from_csv.py

script_test/
  create_container.sh           # 운영 create의 dry-run wrapper
  delete_container.sh           # 운영 delete의 dry-run wrapper
  extend_container_expiration.sh
```

## 운영 전제

- 관리 서버에서 실행합니다.
- 관리 서버는 Ansible inventory를 통해 `lab1`, `lab2`, `farm1`, `farm2` 같은 호스트 alias를 알고 있어야 합니다.
- DB는 도메인별로 분리되어 있습니다.
  - `LAB_DB_HOST` -> LAB DB 서버
  - `FARM_DB_HOST` -> FARM DB 서버
- 컨테이너 작업은 대상 서버에서 수행하지만, DB 갱신은 도메인별 DB 서버에 기록됩니다.

## 의존성 설치

### apt 패키지

핵심 운영용:

```bash
sudo apt update
xargs -a apt-packages-core.txt sudo apt install -y
```

maintenance 스크립트까지 사용할 때:

```bash
xargs -a apt-packages-maintenance.txt sudo apt install -y
```

### Python 패키지

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 설정 파일 준비

### DB 설정

```bash
cp config/db_config.example.env config/db_config.local.env
```

필수 항목:

- `DB_PORT`
- `DB_NAME`
- `DB_USER`
- `DB_PASSWORD`
- `DB_CHARSET`
- `LAB_DB_HOST`
- `FARM_DB_HOST`
- `ANSIBLE_INVENTORY`
- `EXPORT_DOMAINS`

### 메일 설정

```bash
cp config/email_config.example.env config/email_config.local.env
```

필수 항목:

- `SMTP_FROM`

상황별 선택 항목:

- `SMTP_HOST`
- `SMTP_PORT`
- `SMTP_USE_TLS`
- `SMTP_USERNAME`
- `SMTP_PASSWORD`
- `SMTP_REPLY_TO`
- `EMAIL_TO_OVERRIDE`
- `SUPPORT_MANUAL_URL`
- `ERROR_REPORT_FORM_URL`

### Google Sheets 설정

Google Sheets를 갱신하려면 서비스 계정 JSON 파일을 `config/` 아래에 두어야 합니다.

예시 파일:

```bash
cp config/google-client.example.json \
   config/google-client.local.json
```

그 다음 실제 서비스 계정 값으로 내용을 채워야 합니다.

## 주요 명령

### 1. 컨테이너 생성

실제 실행:

```bash
bash script/create_container.sh \
  --server-id LAB10 \
  --name "홍길동" \
  --username hong \
  --group hong \
  --expiration-date 2026-03-31 \
  --image pytorch \
  --version latest \
  --created-by jy \
  --email hong@example.com \
  --phone 010-1234-5678 \
  --note "initial create" \
  --no-container-name \
  --no-additional-ports
```

- `--server-id LAB10` 형식 또는 `--domain LAB --server-number 10` 형식 모두 지원합니다.
- `--no-container-name` 을 주면 기본 이름 규칙 `username_by_createdby` 를 사용합니다.
- `--no-additional-ports` 를 주면 SSH/Jupyter 기본 포트만 할당합니다.

### 2. 컨테이너 삭제

실제 실행:

```bash
bash script/delete_container.sh \
  --server-id LAB10 \
  --container-name hong_by_jy
```

- DB에서는 `docker_container.existing = 0` 으로 soft delete 처리합니다.
- 포트는 `used_ports` 에서 제거됩니다.

### 3. 엑셀 / Google Sheets 추출

```bash
python3 script/export_users_to_excel.py --domains LAB,FARM
```

생성 결과:

- `excel_exports/user_export_YYYY-MM-DD.xlsx`
- 시트 예시:
  - `LAB`
  - `LAB(deleted)`
  - `FARM`
  - `FARM(deleted)`

주의:

- 이 스크립트는 현재 dry-run 옵션이 없습니다.
- 실행 시 실제 `.xlsx` 파일을 만들고, 인증 JSON이 있으면 Google Sheets도 갱신합니다.

### 4. 만료일 연장

dry-run:

```bash
bash script/extend_container_expiration.sh \
  --username hong \
  --expiration-date 2026-04-30 \
  --dry-run
```

실제 반영:

```bash
bash script/extend_container_expiration.sh \
  --username hong \
  --expiration-date 2026-04-30 \
  --apply
```

포트로 특정 컨테이너를 찾을 수도 있습니다.

```bash
bash script/extend_container_expiration.sh \
  --port 9050 \
  --expiration-date 2026-04-30 \
  --apply
```

주의:

- 필터는 `--name`, `--username`, `--port` 중 하나 이상 필요합니다.
- 여러 컨테이너가 매칭되면 기본적으로 dry-run으로만 보여주고, 실제 반영은 `--all-matches` 가 있어야 합니다.
- 반영 후에는 도메인별 DB 백업과 LAB/FARM export 갱신을 한 번 수행합니다.

### 5. 만료 안내 메일 발송

dry-run:

```bash
python3 script/send_expiration_reminder_emails.py --dry-run --domains LAB,FARM
```

실제 발송:

```bash
python3 script/send_expiration_reminder_emails.py --domains LAB,FARM
```

추가 테스트 옵션:

```bash
python3 script/send_expiration_reminder_emails.py \
  --dry-run \
  --domains LAB,FARM \
  --today 2026-03-15 \
  --days 7,3,1
```

메일 발송 규칙:

- 기본 대상은 `7`, `3`, `1`일 남은 활성 컨테이너입니다.
- 같은 수신자 + 같은 남은 일수는 메일 1통으로 묶습니다.
- 같은 사람의 컨테이너가 여러 개면 사람 정보는 한 번만 쓰고, 아래에 컨테이너 목록을 여러 개 출력합니다.
- `EMAIL_TO_OVERRIDE` 를 설정하면 실제 테스트 발송을 특정 메일 한 곳으로 우회할 수 있습니다.

## Dry-run 테스트

### 생성 dry-run

```bash
bash script_test/create_container.sh \
  --server-id FARM2 \
  --name "홍길동" \
  --username hong \
  --group hong \
  --expiration-date 2026-03-31 \
  --image pytorch \
  --version latest \
  --created-by jy \
  --email hong@example.com \
  --phone 010-1234-5678 \
  --note "dry run test" \
  --no-container-name \
  --no-additional-ports
```

### 삭제 dry-run

```bash
bash script_test/delete_container.sh \
  --server-id FARM2 \
  --container-name hong_by_jy
```

### 만료일 연장 dry-run

```bash
bash script_test/extend_container_expiration.sh \
  --username hong \
  --expiration-date 2026-04-30
```

주의:

- create/delete/extend dry-run도 DB 읽기는 필요합니다.
- 따라서 관리 서버에는 최소한 `mysql` 클라이언트가 설치되어 있어야 합니다.
- 원격 Docker 변경, DB 쓰기, 백업, export는 하지 않습니다.

## maintenance 스크립트

`maintenance/` 아래 스크립트는 정기 운영보다는 데이터 보정/정리/마이그레이션에 가깝습니다.

- `delete_user.py`
- `delete_expired_containers.sh`
- `migrate_add_user_contact_columns.sh`
- `sync_containers.sh`
- `update_user_emails_from_csv.py`

특히 `maintenance/sync_containers.sh` 는 현재 관리 서버 구조로 재설계된 상태가 아니므로, 운영 메인 플로우와 별개로 취급하는 것이 안전합니다.

만료된 활성 컨테이너를 조회하거나 일괄 삭제하려면:

```bash
bash maintenance/delete_expired_containers.sh --dry-run
```

옵션 없이 실행해도 동일하게 dry-run 조회만 수행합니다.

실제 삭제까지 하려면:

```bash
bash maintenance/delete_expired_containers.sh --apply
```

## 자동화 권장안

잡이 많아질 예정이면 raw cron보다 `systemd timer` 로 통일하는 것이 낫습니다.

권장 구조:

- `uid-gid-export.service`
- `uid-gid-export.timer`
- `uid-gid-reminder.service`
- `uid-gid-reminder.timer`
- `uid-gid-daily-maintenance.service`
- `uid-gid-daily-maintenance.timer`

장점:

- `systemctl list-timers` 로 한 번에 조회 가능
- `journalctl -u ...` 로 로그 확인 가능
- unit 파일을 저장소에 두고 버전 관리 가능
- Ansible로 배포 가능

현재 저장소에는 백업 + 만료 메일을 함께 매일 실행하는 설치 스크립트가 포함되어 있습니다.

먼저 타이머 설정 파일을 준비합니다.

```bash
cp config/daily_maintenance.example.env config/daily_maintenance.local.env
```

설정 가능한 주요 값:

- `DAILY_MAINTENANCE_ON_CALENDAR`
- `DAILY_MAINTENANCE_LOG_FILE`
- `DAILY_MAINTENANCE_LOG_ROTATE_COUNT`
- `DAILY_MAINTENANCE_DOMAINS`

설치:

```bash
bash script/install_daily_maintenance_timer.sh
```

기본 스케줄은 한국 시간 기준 매일 `11:00` 입니다. 설정 파일 값을 바꾸고 아래 명령을 다시 실행하면 기존 unit/timer/logrotate 설정도 현재 값으로 갱신됩니다.

설정 파일 대신 일회성으로 다른 시간으로 설치하려면:

```bash
bash script/install_daily_maintenance_timer.sh --on-calendar "*-*-* 06:00:00 Asia/Seoul"
```

이미 unit이 있어도 현재 설정 파일 기준으로 내용을 비교해서 필요하면 갱신하고, 변경이 없으면 up-to-date 라고 알려줍니다. timer는 다시 읽고 활성 상태로 맞춥니다.

로그 경로와 보관 일수도 설정 파일에서 바꿀 수 있습니다. logrotate 설정을 함께 설치하며, 기본값은 `/var/log/uid-gid-daily-maintenance.log` 와 `14일` 보관입니다.

즉시 1회 실행:

```bash
sudo systemctl start uid-gid-daily-maintenance.service
```

## 참고

- example 파일은 샘플입니다. 실제 운영값은 `*.local.env` 에 넣어야 합니다.
- `config/*.local.env`, `config/*.local.json` 은 git ignore 대상입니다.
- `config/*.example.json` 은 저장소에 포함됩니다.
- `config/*.example.env` 도 저장소에 포함됩니다.
