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

### DB / Ansible 설정

```bash
cp config/db_config.example.env config/db_config.local.env
```

`config/db_config.local.env` 는 관리 서버에서 실행되는 shell/Python 스크립트가 공통으로 읽는 설정입니다. 실제 비밀번호와 내부 IP가 들어가므로 git에 커밋하지 않습니다.

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
| `DB_PORT` | MySQL 접속 포트입니다. 저장소 예시는 `3307` 입니다. |
| `DB_NAME` | 운영 DB 이름입니다. 기본 스키마는 `nfs_mysql/init.sql` 의 `nfs_db` 입니다. |
| `DB_USER`, `DB_PASSWORD` | LAB/FARM DB에 접속할 MySQL 계정입니다. `user`, `group`, `docker_container`, `used_ports`, `used_ids` 읽기/쓰기 권한이 필요합니다. |
| `DB_CHARSET` | MySQL client character set입니다. 기본값은 `utf8mb4` 입니다. |
| `LAB_DB_HOST` | `--server-id LAB10` 또는 `--domain LAB` 작업 때 사용할 DB host입니다. |
| `FARM_DB_HOST` | `--server-id FARM2` 또는 `--domain FARM` 작업 때 사용할 DB host입니다. |
| `DB_HOST` | 일부 legacy/maintenance 스크립트가 단일 DB host만 받을 때 쓰는 fallback입니다. LAB/FARM 분리 운영에서는 `LAB_DB_HOST`, `FARM_DB_HOST` 를 우선으로 봅니다. |
| `ANSIBLE_INVENTORY` | create/delete가 원격 Docker 명령을 실행할 Ansible inventory의 절대 경로입니다. |
| `BACKUP_ROOT_DIR` | create/delete 성공 후 `mysqldump` 백업을 저장할 관리 서버 로컬 디렉토리입니다. 생략하면 `mysql_backups/` 를 씁니다. |
| `EXPORT_DOMAINS` | export 기본 대상 도메인 CSV입니다. 보통 `LAB,FARM` 입니다. |
| `SERVER_DOMAIN` | `EXPORT_DOMAINS` 가 없을 때 일부 스크립트가 참고하는 fallback 도메인입니다. 단일 도메인만 운영할 때 사용합니다. |

DB 서버를 새로 만들 때는 `nfs_mysql/init.sql` 스키마가 적용되어 있어야 합니다. 저장소의 MySQL 컨테이너 예시는 `docker-compose.yml` 을 참고하면 됩니다. 이 방식으로 띄우려면 `nfs_mysql/.env` 를 먼저 준비합니다.

```bash
MYSQL_ROOT_PASSWORD=replace-with-root-password
MYSQL_DATABASE=nfs_db
MYSQL_USER=nfs_user
MYSQL_PASSWORD=replace-with-real-password
```

그 다음 DB 컨테이너를 실행합니다.

```bash
docker compose up -d nfs_mysql
```

### Ansible inventory 설정

create/delete는 `LAB10` 같은 server id를 내부적으로 `lab10` Ansible host alias로 바꿉니다. 따라서 inventory에는 lowercase `labN`, `farmN` alias가 있어야 합니다.

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

- `ansible_user` 가 passwordless SSH로 접속 가능해야 합니다.
- `ansible_user` 가 `sudo` 없이 `docker` 명령을 실행할 수 있어야 합니다.
- GPU 컨테이너 생성에 필요한 Docker/NVIDIA runtime이 대상 서버에 준비되어 있어야 합니다.
- create 스크립트는 `/home/tako서버번호/share/user-share/` 를 컨테이너 `/home/` 에 bind mount합니다. 예를 들어 `LAB10` 은 `/home/tako10/share/user-share/` 를 사용합니다.
- Docker 이미지는 `dguailab/<image>:<version>` 형식으로 pull/inspect 됩니다.

### 메일 설정

```bash
cp config/email_config.example.env config/email_config.local.env
```

관리자 CC 목록을 분리해서 관리하려면:

```bash
cp config/reminder_admins.example.txt config/reminder_admins.local.txt
```

`config/reminder_admins.local.txt` 에 한 줄에 한 이메일 주소씩 넣으면 생성/삭제/만료 안내 메일의 참조(CC)로 추가됩니다.

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
| `SMTP_FROM` | 필수입니다. 모든 자동 메일의 From 주소입니다. |
| `SMTP_FROM_NAME` | From 표시 이름입니다. 생략하면 `DGU AILab Server Manager` 입니다. |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USE_TLS` | SMTP relay 접속 정보입니다. 기본 relay는 `smtp-relay.gmail.com:587`, TLS 사용입니다. |
| `SMTP_USERNAME`, `SMTP_PASSWORD` | SMTP 인증이 필요한 relay에서만 채웁니다. |
| `SMTP_REPLY_TO` | 회신 주소가 필요할 때 설정합니다. |
| `SMTP_TIMEOUT` | SMTP 연결 timeout 초입니다. |
| `EMAIL_TO_OVERRIDE` | 테스트용입니다. 설정하면 실제 수신자를 모두 이 주소 하나로 바꾸고 CC는 보내지 않습니다. |
| `SUPPORT_MANUAL_URL` | 생성 안내 메일에 들어갈 사용자 매뉴얼 링크입니다. |
| `ERROR_REPORT_FORM_URL` | 도메인별 오류 신고 폼 URL이 없을 때 쓰는 fallback입니다. |
| `ERROR_REPORT_FORM_URL_FARM`, `ERROR_REPORT_FORM_URL_LAB` | 생성 안내 메일에 들어갈 도메인별 오류 신고 폼 URL입니다. |

### Google Sheets 설정

Google Sheets를 갱신하려면 서비스 계정 JSON 파일을 `config/` 아래에 두어야 합니다.

예시 파일:

```bash
cp config/google-client.example.json \
   config/google-client.local.json
```

그 다음 실제 서비스 계정 값으로 내용을 채워야 합니다.

### 서버 인벤토리 JSONL 생성

Ansible facts를 AI가 읽기 쉬운 요약 인벤토리로 만들려면 먼저 원본 facts를 갱신합니다.

```bash
ansible all -m setup --tree server_info/
```

그 다음 저장소의 정적 토폴로지 규칙과 합쳐 `servers.jsonl`을 생성합니다.

```bash
python3 server_info/generate_servers_jsonl.py \
  --inventory /etc/ansible/inventory.ini
```

- 정적 네트워크/포트 규칙은 `config/network_topology.json` 에서 관리합니다.
- inventory 경로를 주지 않으면 `ANSIBLE_INVENTORY` 환경변수를 먼저 보고, 없으면 facts와 포트 규칙만으로 보완합니다.
- 기본 출력은 `server_info/servers.jsonl` 입니다.
- 출력은 호스트당 한 줄 JSON(`jsonl`)이며, management/storage NIC, MAC, 공인 접근 포트, 서버 번호별 서비스 포트 블록을 포함합니다.

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

- `--server-id LAB10` 형식 또는 `--domain LAB --server-number 10` 형식 모두 지원합니다.
- `--no-container-name` 을 주면 기본 이름 규칙 `username_by_createdby` 를 사용합니다.
- `--no-additional-ports` 를 주면 SSH/Jupyter 기본 포트만 할당합니다.
- `--enable-vnc true` 또는 `--enable_vnc true` 를 주면 컨테이너 내부 `6080` 포트를 자동으로 추가 매핑하고, Docker 환경변수 `ENABLE_VNC=true` 를 전달합니다. 외부 포트는 기존 포트 배정 방식으로 자동 선택됩니다.
- `--user-password` 를 생략하면 12자리 영문/숫자 초기 Ubuntu 비밀번호를 자동 생성합니다.
- `--vnc-password` 를 생략하고 VNC가 켜져 있으면 8자리 영문/숫자 초기 VNC 비밀번호를 자동 생성합니다. VNC 비밀번호는 최대 8자까지만 사용합니다.

생성 내부 파이프라인:

1. `config/db_config.local.env` 를 읽고 `--server-id LAB10` 을 `domain=LAB`, `server_number=10`, `server_id=LAB10`, Ansible host alias `lab10` 으로 변환합니다.
2. `LAB_DB_HOST` 또는 `FARM_DB_HOST` 로 DB host를 결정하고, `ANSIBLE_INVENTORY` 안에 `lab10` / `farmN` alias가 있는지 확인합니다.
3. 관리 서버에서 MySQL 접속을 확인합니다. dry-run도 DB 읽기가 필요합니다.
4. DB의 `used_ports` 를 읽어 포트를 배정합니다. 서버 번호 `N` 의 포트 블록은 `9000 + 100 * (N - 1)` 부터 `9000 + 100 * N - 1` 까지입니다. 기본으로 SSH `22`, Jupyter `8888` 에 외부 포트 2개를 먼저 배정하고, VNC와 추가 포트가 있으면 남은 포트를 순서대로 배정합니다.
5. DB의 `user`, `group`, `used_ids` 를 읽어 UID/GID를 정합니다. 기존 username이 있으면 UID를 재사용하고, 없으면 `used_ids` 의 최댓값 다음 번호를 사용합니다. group이 비어 있으면 username을 group으로 씁니다.
6. `--dry-run` 이면 여기서 원격 Docker 실행, DB 쓰기, 백업, export, 메일 발송 없이 계획만 출력하고 종료합니다.
7. 대상 서버에서 Ansible shell로 `docker image inspect dguailab/<image>:<version>` 을 실행하고, 이미지가 없으면 `docker pull` 을 실행합니다.
8. DB transaction을 시작합니다.
9. 대상 서버에서 Ansible shell로 `docker run -dit ...` 을 실행합니다. 주요 옵션은 GPU 전체 사용, 메모리 `192g`, `--runtime=nvidia`, `/home/takoN/share/user-share/` bind mount, `USER_ID`, `UID`, `GID`, `USER_PW`, `USER_GROUP` 환경변수 전달입니다.
10. 생성된 container id 형식을 확인하고, `docker inspect` 와 `docker port` 로 컨테이너와 SSH 포트 바인딩을 검증합니다.
11. 같은 transaction 안에서 `used_ids`, `used_ports`, `group`, `user`, `docker_container` 를 기록하고, `used_ports.docker_container_record_id` 를 새 `docker_container.id` 로 연결합니다.
12. DB transaction을 commit합니다.
13. 생성 안내 메일을 사용자에게 발송합니다. 메일에는 SSH/Jupyter/VNC 접속 정보와 초기 비밀번호가 포함됩니다.
14. 도메인 DB를 `BACKUP_ROOT_DIR/<domain>/nfs_db_backup_YYYYMMDD_HHMMSS.sql.gz` 로 백업합니다.
15. `script/export_users_to_excel.py --domains LAB,FARM` 을 실행해 Excel/Google Sheets export를 갱신합니다.

생성 실패 처리:

- transaction 시작 후 실패하면 DB rollback을 시도합니다.
- 원격 Docker 컨테이너가 이미 만들어진 뒤 DB 기록이나 검증이 실패하면 `docker rm -f` 로 방금 만든 컨테이너를 제거한 뒤 rollback합니다.
- commit 이후의 메일, 백업, export 실패는 생성 자체를 rollback하지 않습니다. 메일 실패는 로그로 남기고, 백업은 실패해도 계속 진행합니다.

### 2. 컨테이너 삭제

사용자 삭제 안내 메일까지 보내는 실제 실행 예시:

```bash
bash script/delete_container_with_notification.sh \
  --server-id LAB10 \
  --container-name hong_by_jy
```

삭제 대상은 다음 방식으로 찾을 수 있습니다.

```bash
bash script/delete_container_with_notification.sh --server-id LAB10 --container-name hong_by_jy
bash script/delete_container_with_notification.sh --server-id LAB10 --container-id abc123
bash script/delete_container_with_notification.sh --server-id LAB10 --username hong
bash script/delete_container_with_notification.sh --server-id LAB10 --name "홍길동" --port 9050
```

- `--container-id` 는 Docker container id prefix 검색입니다.
- `--container-name` 은 DB의 `docker_container.container_name` 과 정확히 일치해야 합니다.
- `--name`, `--username`, `--port` 는 DB 필터입니다. 여러 컨테이너가 매칭되면 중단하므로 필터를 좁혀야 합니다.
- 삭제 안내 메일을 보내려면 `script/delete_container_with_notification.sh` 를 사용합니다. `script/delete_container.sh` 를 직접 실행하면 삭제만 하고 메일은 보내지 않습니다.
- wrapper가 삭제 전 사용자 이메일/포트/만료일 메타데이터를 미리 읽어야 하므로, 운영에서는 `--server-id` 또는 `--domain` + `--server-number` 를 명시하는 것이 안전합니다.

삭제 내부 파이프라인:

1. `delete_container_with_notification.sh` 가 먼저 삭제 전 DB record를 조회해 사용자 이름, username, email, port 목록, 만료일을 저장합니다. 이 정보는 삭제 성공 후 메일 발송에 사용됩니다.
2. wrapper가 같은 인자를 `script/delete_container.sh` 로 넘겨 실제 삭제를 실행합니다.
3. `delete_container.sh` 는 `config/db_config.local.env` 를 읽고 server id를 `domain`, `server_number`, Ansible host alias로 변환합니다.
4. 도메인 DB에 접속해 활성 컨테이너(`docker_container.existing = 1`)를 찾습니다. DB record의 `server_id` 가 요청한 server id와 다르면 `--force` 없이는 중단합니다.
5. 실제 DB record의 server id에서 다시 Ansible host alias를 계산합니다. 예를 들어 DB record가 `LAB10` 이면 원격 삭제 대상은 `lab10` 입니다.
6. `--dry-run` 이면 여기서 DB 쓰기, 원격 Docker 삭제, 백업, export, 메일 발송 없이 계획만 출력하고 종료합니다.
7. DB transaction을 시작합니다.
8. `used_ports` 에서 해당 `docker_container.id` 에 연결된 포트 row를 삭제합니다.
9. `docker_container` row는 삭제하지 않고 `existing = 0`, `deleted_at = NOW()` 로 soft delete 처리합니다.
10. 대상 서버에서 Ansible shell로 `docker rm -f <container_id>` 를 실행합니다. 실패하면 container name으로 한 번 더 삭제를 시도합니다.
11. DB update와 원격 Docker 삭제가 성공하면 transaction을 commit합니다.
12. `--skip-post-actions` 가 없으면 도메인 DB 백업을 만들고, LAB/FARM Excel/Google Sheets export를 갱신합니다.
13. wrapper가 삭제 성공 메시지를 확인한 뒤 사용자에게 삭제 안내 메일을 발송합니다.

삭제 실패 처리:

- `--force` 없이 DB soft delete 또는 원격 Docker 삭제가 실패하면 DB transaction을 rollback하고 종료합니다.
- `--force` 를 주면 DB update 또는 원격 Docker 삭제 실패가 있어도 가능한 작업을 계속 진행하고 commit할 수 있습니다. 운영에서는 DB와 실제 Docker 상태가 불일치할 수 있으므로 신중하게 사용해야 합니다.
- commit 이후 백업/export 실패는 삭제 자체를 rollback하지 않습니다.
- 삭제 안내 메일은 삭제 성공 후에만 발송됩니다. 이메일이 없거나 삭제 전 메타데이터를 하나로 특정하지 못하면 삭제는 완료되고 메일만 생략됩니다.
- `--skip-post-actions` 는 백업/export만 건너뜁니다. wrapper를 사용한 경우 삭제 성공 후 메일 발송은 계속 시도합니다.

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
- `config/reminder_admins.local.txt` 가 있으면 관리자 이메일을 참조(CC)에 추가합니다.
- `EMAIL_TO_OVERRIDE` 를 설정하면 실제 테스트 발송을 특정 메일 한 곳으로 우회할 수 있습니다.
- `EMAIL_TO_OVERRIDE` 테스트 모드에서는 관리자 CC를 보내지 않습니다.

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

`maintenance/delete_expired_containers.sh --apply` 는 내부적으로 `script/delete_container_with_notification.sh` 를 호출하므로, 실제 삭제 시 사용자 삭제 안내 메일도 함께 발송합니다.

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

이메일 CSV 업데이트를 도메인별 DB에 적용하려면:

```bash
python3 maintenance/update_user_emails_from_csv.py \
  --domain FARM \
  --csv excel_exports/farm_user_emails.csv \
  --dry-run
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

현재 저장소에는 백업 + 만료 메일 + 만료된 활성 컨테이너 정리를 함께 매일 실행하는 설치 스크립트가 포함되어 있습니다.

먼저 타이머 설정 파일을 준비합니다.

```bash
cp config/daily_maintenance.example.env config/daily_maintenance.local.env
```

설정 가능한 주요 값:

- `DAILY_MAINTENANCE_ON_CALENDAR`
- `DAILY_MAINTENANCE_LOG_FILE`
- `DAILY_MAINTENANCE_LOG_ROTATE_COUNT`
- `DAILY_MAINTENANCE_DOMAINS`

`DAILY_MAINTENANCE_DOMAINS` 는 CSV 형식입니다. 두 도메인을 모두 돌리려면 `LAB,FARM` 으로 설정하면 됩니다.

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

daily maintenance 로그는 각 줄마다 timestamp와 단계 태그가 붙습니다. 예:

- `[BACKUP]`
- `[REMINDER]`
- `[DELETE]`
- `[ERROR]`

즉시 1회 실행:

```bash
sudo systemctl start uid-gid-daily-maintenance.service
```

## 참고

- example 파일은 샘플입니다. 실제 운영값은 `*.local.env` 에 넣어야 합니다.
- `config/*.local.env`, `config/*.local.json` 은 git ignore 대상입니다.
- `config/*.example.json` 은 저장소에 포함됩니다.
- `config/*.example.env` 도 저장소에 포함됩니다.
