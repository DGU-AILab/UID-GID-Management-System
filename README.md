# UID/GID Management System

관리 서버에서 LAB/FARM 서버의 컨테이너 생성, 삭제, 사용자 현황 엑셀 추출, 만료 안내 메일 발송을 관리하는 운영용 스크립트 모음.

## 개요

관리 흐름:

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
  delete_container_with_notification.sh
  extend_container_expiration.sh
  export_users_to_excel.py
  send_container_deleted_email.py
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

- 관리 서버에서 실행.
- Ansible inventory에 `lab1`, `lab2`, `farm1`, `farm2` 같은 호스트 alias 필요.
- DB는 도메인별 분리.
  - `LAB_DB_HOST` -> LAB DB 서버
  - `FARM_DB_HOST` -> FARM DB 서버
- 컨테이너 작업은 대상 서버에서 수행, DB 갱신은 도메인별 DB 서버에 기록.

## 주요 명령

### 1. 컨테이너 생성

실제 실행 예시:

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

- `--server-id LAB10` 또는 `--domain LAB --server-number 10` 모두 지원.
- `--no-container-name`: 기본 이름 규칙 `username_by_createdby` 사용.
- `--no-additional-ports`: SSH/Jupyter 기본 포트만 할당.
- `--enable-vnc true` 또는 `--enable_vnc true`: 컨테이너 내부 `6080` 포트 추가 매핑, Docker 환경변수 `ENABLE_VNC=true` 전달. 외부 포트는 기존 포트 배정 방식으로 자동 선택.
- `--user-password` 생략 시 12자리 영문/숫자 초기 Ubuntu 비밀번호 자동 생성.
- `--vnc-password` 생략 + VNC 활성화 시 8자리 영문/숫자 초기 VNC 비밀번호 자동 생성. VNC 비밀번호는 최대 8자.

생성 내부 파이프라인:

1. `config/db_config.local.env` 로드. `--server-id LAB10` 을 `domain=LAB`, `server_number=10`, `server_id=LAB10`, Ansible host alias `lab10` 으로 변환.
2. `LAB_DB_HOST` 또는 `FARM_DB_HOST` 로 DB host 결정. `ANSIBLE_INVENTORY` 안의 `lab10` / `farmN` alias 확인.
3. 관리 서버에서 MySQL 접속 확인. dry-run도 DB 읽기 필요.
4. DB의 `used_ports` 조회 후 포트 배정. 서버 번호 `N` 의 포트 블록은 `9000 + 100 * (N - 1)` 부터 `9000 + 100 * N - 1` 까지. SSH `22`, Jupyter `8888` 에 외부 포트 2개 우선 배정. VNC와 추가 포트는 남은 포트 순차 배정.
5. DB의 `user`, `group`, `used_ids` 조회 후 UID/GID 결정. 기존 username은 UID 재사용. 신규 username은 `used_ids` 최댓값 다음 번호 사용. group이 비어 있으면 username을 group으로 사용.
6. `--dry-run` 인 경우 원격 Docker 실행, DB 쓰기, 백업, export, 메일 발송 없이 계획만 출력 후 종료.
7. 대상 서버에서 Ansible shell로 `docker image inspect dguailab/<image>:<version>` 실행. 이미지가 없으면 `docker pull`.
8. DB transaction 시작.
9. 대상 서버에서 Ansible shell로 `docker run -dit ...` 실행. 주요 옵션: GPU 전체 사용, 메모리 `192g`, `--runtime=nvidia`, `/home/takoN/share/user-share/` bind mount, `USER_ID`, `UID`, `GID`, `USER_PW`, `USER_GROUP` 환경변수 전달.
10. 생성된 container id 형식 확인. `docker inspect` 와 `docker port` 로 컨테이너와 SSH 포트 바인딩 검증.
11. 같은 transaction 안에서 `used_ids`, `used_ports`, `group`, `user`, `docker_container` 기록. `used_ports.docker_container_record_id` 를 새 `docker_container.id` 로 연결.
12. DB transaction commit.
13. 생성 안내 메일 발송. SSH/Jupyter/VNC 접속 정보와 초기 비밀번호 포함.
14. 도메인 DB를 `BACKUP_ROOT_DIR/<domain>/nfs_db_backup_YYYYMMDD_HHMMSS.sql.gz` 로 백업.
15. `script/export_users_to_excel.py --domains LAB,FARM` 실행. Excel/Google Sheets export 갱신.

생성 실패 처리:

- transaction 시작 후 실패 시 DB rollback 시도.
- 원격 Docker 컨테이너 생성 후 DB 기록/검증 실패 시 `docker rm -f` 로 방금 만든 컨테이너 제거 후 rollback.
- commit 이후 메일, 백업, export 실패는 생성 자체 rollback 대상 아님. 메일 실패는 로그 기록, 백업 실패는 무시 후 진행.

### 2. 컨테이너 삭제

사용자 삭제 안내 메일까지 보내는 실제 실행 예시:

```bash
bash script/delete_container_with_notification.sh \
  --server-id LAB10 \
  --container-name hong_by_jy
```

삭제 대상 조회 방식:

```bash
bash script/delete_container_with_notification.sh --server-id LAB10 --container-name hong_by_jy
bash script/delete_container_with_notification.sh --server-id LAB10 --container-id abc123
bash script/delete_container_with_notification.sh --server-id LAB10 --username hong
bash script/delete_container_with_notification.sh --server-id LAB10 --name "홍길동" --port 9050
```

- `--container-id`: Docker container id prefix 검색.
- `--container-name`: DB의 `docker_container.container_name` 과 정확히 일치 필요.
- `--name`, `--username`, `--port`: DB 필터. 여러 컨테이너 매칭 시 중단. 필터 축소 필요.
- 삭제 안내 메일 필요 시 `script/delete_container_with_notification.sh` 사용. `script/delete_container.sh` 직접 실행 시 삭제만 수행, 메일 미발송.
- wrapper는 삭제 전 사용자 이메일/포트/만료일 메타데이터 조회 필요. 운영에서는 `--server-id` 또는 `--domain` + `--server-number` 명시 권장.

삭제 내부 파이프라인:

1. `delete_container_with_notification.sh` 가 삭제 전 DB record 조회. 사용자 이름, username, email, port 목록, 만료일 저장. 삭제 성공 후 메일 발송에 사용.
2. wrapper가 같은 인자를 `script/delete_container.sh` 로 전달해 실제 삭제 실행.
3. `delete_container.sh` 가 `config/db_config.local.env` 로드. server id를 `domain`, `server_number`, Ansible host alias로 변환.
4. 도메인 DB에서 활성 컨테이너(`docker_container.existing = 1`) 조회. DB record의 `server_id` 가 요청 server id와 다르면 `--force` 없이는 중단.
5. 실제 DB record의 server id에서 Ansible host alias 재계산. 예: DB record가 `LAB10` 이면 원격 삭제 대상은 `lab10`.
6. `--dry-run` 인 경우 DB 쓰기, 원격 Docker 삭제, 백업, export, 메일 발송 없이 계획만 출력 후 종료.
7. DB transaction 시작.
8. `used_ports` 에서 해당 `docker_container.id` 에 연결된 포트 row 삭제.
9. `docker_container` row는 삭제하지 않고 `existing = 0`, `deleted_at = NOW()` 로 soft delete.
10. 대상 서버에서 Ansible shell로 `docker rm -f <container_id>` 실행. 실패 시 container name으로 한 번 더 삭제 시도.
11. DB update와 원격 Docker 삭제 성공 시 transaction commit.
12. `--skip-post-actions` 가 없으면 도메인 DB 백업, LAB/FARM Excel/Google Sheets export 갱신.
13. wrapper가 삭제 성공 메시지 확인 후 사용자에게 삭제 안내 메일 발송.

삭제 실패 처리:

- `--force` 없이 DB soft delete 또는 원격 Docker 삭제 실패 시 DB transaction rollback 후 종료.
- `--force` 사용 시 DB update 또는 원격 Docker 삭제 실패가 있어도 가능한 작업 계속 진행 후 commit 가능. 운영에서는 DB와 실제 Docker 상태 불일치 가능하므로 신중히 사용.
- commit 이후 백업/export 실패는 삭제 자체 rollback 대상 아님.
- 삭제 안내 메일은 삭제 성공 후에만 발송. 이메일이 없거나 삭제 전 메타데이터를 하나로 특정하지 못하면 삭제 완료, 메일만 생략.
- `--skip-post-actions`: 백업/export만 생략. wrapper 사용 시 삭제 성공 후 메일 발송은 계속 시도.

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

- 현재 dry-run 옵션 없음.
- 실행 시 실제 `.xlsx` 파일 생성. 인증 JSON이 있으면 Google Sheets도 갱신.

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

포트로 특정 컨테이너 조회 가능.

```bash
bash script/extend_container_expiration.sh \
  --port 9050 \
  --expiration-date 2026-04-30 \
  --apply
```

주의:

- 필터는 `--name`, `--username`, `--port` 중 하나 이상 필요.
- 여러 컨테이너 매칭 시 기본적으로 dry-run만 표시. 실제 반영은 `--all-matches` 필요.
- 반영 후 도메인별 DB 백업과 LAB/FARM export 갱신 1회 수행.

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

- 기본 대상: `7`, `3`, `1`일 남은 활성 컨테이너.
- 같은 수신자 + 같은 남은 일수는 메일 1통으로 묶음.
- 같은 사람의 컨테이너가 여러 개면 사람 정보는 한 번만 출력, 아래에 컨테이너 목록 출력.
- `config/reminder_admins.local.txt` 가 있으면 관리자 이메일을 참조(CC)에 추가.
- `EMAIL_TO_OVERRIDE` 설정 시 실제 테스트 발송을 특정 메일 한 곳으로 우회 가능.
- `EMAIL_TO_OVERRIDE` 테스트 모드에서는 관리자 CC 미발송.

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

- create/delete/extend dry-run도 DB 읽기 필요.
- 관리 서버에 최소 `mysql` 클라이언트 필요.
- 원격 Docker 변경, DB 쓰기, 백업, export 미수행.

## maintenance 스크립트

`maintenance/` 아래 스크립트는 정기 운영보다는 데이터 보정/정리/마이그레이션 성격.

- `delete_user.py`
- `delete_expired_containers.sh`
- `migrate_add_user_contact_columns.sh`
- `sync_containers.sh`
- `update_user_emails_from_csv.py`

`maintenance/delete_expired_containers.sh --apply`: 내부적으로 `script/delete_container_with_notification.sh` 호출. 실제 삭제 시 사용자 삭제 안내 메일도 함께 발송.

`maintenance/sync_containers.sh`: 현재 관리 서버 구조로 재설계된 상태 아님. 운영 메인 플로우와 별개 취급 권장.

만료된 활성 컨테이너 조회 또는 일괄 삭제:

```bash
bash maintenance/delete_expired_containers.sh --dry-run
```

옵션 없이 실행해도 동일하게 dry-run 조회만 수행.

실제 삭제:

```bash
bash maintenance/delete_expired_containers.sh --apply
```

이메일 CSV 업데이트를 도메인별 DB에 적용:

```bash
python3 maintenance/update_user_emails_from_csv.py \
  --domain FARM \
  --csv excel_exports/farm_user_emails.csv \
  --dry-run
```

## 자동화 권장안

잡이 많아질 예정이면 raw cron보다 `systemd timer` 로 통일 권장.

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

현재 저장소에는 백업 + 만료 메일 + 만료된 활성 컨테이너 정리를 함께 매일 실행하는 설치 스크립트 포함.

타이머 설정 파일 준비:

```bash
cp config/daily_maintenance.example.env config/daily_maintenance.local.env
```

설정 가능한 주요 값:

- `DAILY_MAINTENANCE_ON_CALENDAR`
- `DAILY_MAINTENANCE_LOG_FILE`
- `DAILY_MAINTENANCE_LOG_ROTATE_COUNT`
- `DAILY_MAINTENANCE_DOMAINS`

`DAILY_MAINTENANCE_DOMAINS`: CSV 형식. 두 도메인 모두 실행 시 `LAB,FARM`.

설치:

```bash
bash script/install_daily_maintenance_timer.sh
```

기본 스케줄: 한국 시간 기준 매일 `11:00`. 설정 파일 값 변경 후 아래 명령 재실행 시 기존 unit/timer/logrotate 설정도 현재 값으로 갱신.

설정 파일 대신 일회성 다른 시간 설치:

```bash
bash script/install_daily_maintenance_timer.sh --on-calendar "*-*-* 06:00:00 Asia/Seoul"
```

이미 unit이 있어도 현재 설정 파일 기준으로 내용 비교. 필요 시 갱신, 변경 없으면 up-to-date 출력. timer는 다시 읽고 활성 상태로 조정.

로그 경로와 보관 일수도 설정 파일에서 변경 가능. logrotate 설정 함께 설치. 기본값: `/var/log/uid-gid-daily-maintenance.log`, `14일` 보관.

daily maintenance 로그는 각 줄마다 timestamp와 단계 태그 포함. 예:

- `[BACKUP]`
- `[REMINDER]`
- `[DELETE]`
- `[ERROR]`

즉시 1회 실행:

```bash
sudo systemctl start uid-gid-daily-maintenance.service
```

## 의존성 설치

### apt 패키지

핵심 운영용:

```bash
sudo apt update
xargs -a apt-packages-core.txt sudo apt install -y
```

maintenance 스크립트 포함 시:

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

### DB / Ansible 설정

```bash
cp config/db_config.example.env config/db_config.local.env
```

`config/db_config.local.env`: 관리 서버에서 실행되는 shell/Python 스크립트의 공통 설정. 실제 비밀번호와 내부 IP 포함 가능하므로 git 커밋 금지.

예시:

```bash
DB_PORT=3307
DB_NAME=nfs_db
DB_USER=nfs_user
DB_PASSWORD=replace-with-real-password
DB_CHARSET=utf8mb4

LAB_DB_HOST=192.168.1.11
FARM_DB_HOST=192.168.2.11
DB_HOST=127.0.0.1

ANSIBLE_INVENTORY=/home/jy/ansible/inventory.ini
BACKUP_ROOT_DIR=/home/jy/uid/mysql_backups

EXPORT_DOMAINS=LAB,FARM
SERVER_DOMAIN=LAB
```

주요 값:

| 값 | 설명 |
| --- | --- |
| `DB_PORT` | MySQL 접속 포트. 저장소 예시: `3307`. |
| `DB_NAME` | 운영 DB 이름. 기본 스키마: `nfs_mysql/init.sql` 의 `nfs_db`. |
| `DB_USER`, `DB_PASSWORD` | LAB/FARM DB 접속 MySQL 계정. `user`, `group`, `docker_container`, `used_ports`, `used_ids` 읽기/쓰기 권한 필요. |
| `DB_CHARSET` | MySQL client character set. 기본값: `utf8mb4`. |
| `LAB_DB_HOST` | `--server-id LAB10` 또는 `--domain LAB` 작업 때 사용할 DB host. |
| `FARM_DB_HOST` | `--server-id FARM2` 또는 `--domain FARM` 작업 때 사용할 DB host. |
| `DB_HOST` | 일부 legacy/maintenance 스크립트용 단일 DB host fallback. LAB/FARM 분리 운영에서는 `LAB_DB_HOST`, `FARM_DB_HOST` 우선. |
| `ANSIBLE_INVENTORY` | create/delete가 원격 Docker 명령을 실행할 Ansible inventory 절대 경로. |
| `BACKUP_ROOT_DIR` | create/delete 성공 후 `mysqldump` 백업 저장용 관리 서버 로컬 디렉토리. 생략 시 `mysql_backups/` 사용. |
| `EXPORT_DOMAINS` | export 기본 대상 도메인 CSV. 보통 `LAB,FARM`. |
| `SERVER_DOMAIN` | `EXPORT_DOMAINS` 가 없을 때 일부 스크립트가 참고하는 fallback 도메인. 단일 도메인 운영 시 사용. |

DB 서버 신규 구성 시 `nfs_mysql/init.sql` 스키마 적용 필요. 저장소의 MySQL 컨테이너 예시는 `docker-compose.yml` 참고. 이 방식으로 실행하려면 `nfs_mysql/.env` 먼저 준비.

```bash
MYSQL_ROOT_PASSWORD=replace-with-root-password
MYSQL_DATABASE=nfs_db
MYSQL_USER=nfs_user
MYSQL_PASSWORD=replace-with-real-password
```

DB 컨테이너 실행:

```bash
docker compose up -d nfs_mysql
```

### Ansible inventory 설정

create/delete는 `LAB10` 같은 server id를 내부적으로 `lab10` Ansible host alias로 변환. 따라서 inventory에는 lowercase `labN`, `farmN` alias 필요.

예시:

```ini
[LAB]
lab1 ansible_host=192.168.1.11 ansible_port=8081 ansible_user=jy
lab10 ansible_host=192.168.1.20 ansible_port=8090 ansible_user=jy

[FARM]
farm1 ansible_host=192.168.2.11 ansible_port=8081 ansible_user=jy
farm2 ansible_host=192.168.2.12 ansible_port=8082 ansible_user=jy
```

확인:

```bash
ansible lab10 -i /home/jy/ansible/inventory.ini --list-hosts
ansible lab10 -i /home/jy/ansible/inventory.ini -m ping
ansible lab10 -i /home/jy/ansible/inventory.ini -m shell -a "docker ps"
```

원격 서버 전제:

- `ansible_user` 의 passwordless SSH 접속 가능.
- `ansible_user` 의 `sudo` 없는 `docker` 명령 실행 가능.
- GPU 컨테이너 생성에 필요한 Docker/NVIDIA runtime 준비.
- create 스크립트는 `/home/tako서버번호/share/user-share/` 를 컨테이너 `/home/` 에 bind mount. 예: `LAB10` 은 `/home/tako10/share/user-share/` 사용.
- Docker 이미지는 `dguailab/<image>:<version>` 형식으로 pull/inspect.

### 메일 설정

```bash
cp config/email_config.example.env config/email_config.local.env
```

관리자 CC 목록 분리 관리:

```bash
cp config/reminder_admins.example.txt config/reminder_admins.local.txt
```

`config/reminder_admins.local.txt` 에 한 줄에 한 이메일 주소씩 입력. 생성/삭제/만료 안내 메일의 참조(CC)로 추가.

예시:

```bash
SMTP_HOST=smtp-relay.gmail.com
SMTP_PORT=587
SMTP_USE_TLS=true
SMTP_FROM=svmanager@example.com
SMTP_FROM_NAME=DGU AILab Server Manager
SMTP_REPLY_TO=svmanager@example.com
SMTP_USERNAME=
SMTP_PASSWORD=
SMTP_TIMEOUT=30

SUPPORT_MANUAL_URL=https://example.com/manual
ERROR_REPORT_FORM_URL=https://example.com/error-report-form
ERROR_REPORT_FORM_URL_FARM=https://example.com/farm-error-report-form
ERROR_REPORT_FORM_URL_LAB=https://example.com/lab-error-report-form
```

주요 값:

| 값 | 설명 |
| --- | --- |
| `SMTP_FROM` | 필수. 모든 자동 메일의 From 주소. |
| `SMTP_FROM_NAME` | From 표시 이름. 생략 시 `DGU AILab Server Manager`. |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USE_TLS` | SMTP relay 접속 정보. 기본 relay: `smtp-relay.gmail.com:587`, TLS 사용. |
| `SMTP_USERNAME`, `SMTP_PASSWORD` | SMTP 인증이 필요한 relay에서만 입력. |
| `SMTP_REPLY_TO` | 회신 주소가 필요할 때 설정. |
| `SMTP_TIMEOUT` | SMTP 연결 timeout 초. |
| `EMAIL_TO_OVERRIDE` | 테스트용. 설정 시 실제 수신자를 이 주소 하나로 대체하고 CC 미발송. |
| `SUPPORT_MANUAL_URL` | 생성 안내 메일에 들어갈 사용자 매뉴얼 링크. |
| `ERROR_REPORT_FORM_URL` | 도메인별 오류 신고 폼 URL이 없을 때 쓰는 fallback. |
| `ERROR_REPORT_FORM_URL_FARM`, `ERROR_REPORT_FORM_URL_LAB` | 생성 안내 메일에 들어갈 도메인별 오류 신고 폼 URL. |

### Google Sheets 설정

Google Sheets 갱신 시 서비스 계정 JSON 파일을 `config/` 아래에 배치.

예시 파일:

```bash
cp config/google-client.example.json \
   config/google-client.local.json
```

이후 실제 서비스 계정 값 입력.

### 서버 인벤토리 JSONL 생성

Ansible facts를 AI가 읽기 쉬운 요약 인벤토리로 만들려면 원본 facts 먼저 갱신.

```bash
ansible all -m setup --tree server_info/
```

저장소의 정적 토폴로지 규칙과 합쳐 `servers.jsonl` 생성.

```bash
python3 server_info/generate_servers_jsonl.py \
  --inventory /etc/ansible/inventory.ini
```

- 정적 네트워크/포트 규칙은 `config/network_topology.json` 에서 관리.
- inventory 경로 미지정 시 `ANSIBLE_INVENTORY` 환경변수 우선. 없으면 facts와 포트 규칙만으로 보완.
- 기본 출력: `server_info/servers.jsonl`.
- 출력은 호스트당 한 줄 JSON(`jsonl`). management/storage NIC, MAC, 공인 접근 포트, 서버 번호별 서비스 포트 블록 포함.

## 참고

- example 파일은 샘플. 실제 운영값은 `*.local.env` 에 입력.
- `config/*.local.env`, `config/*.local.json` 은 git ignore 대상.
- `config/*.example.json` 은 저장소 포함.
- `config/*.example.env` 도 저장소 포함.
