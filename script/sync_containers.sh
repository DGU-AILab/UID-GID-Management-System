#!/bin/bash
# =================================================================
# sync_containers.sh
# DB 기준으로 컨테이너 상태를 동기화합니다.
#
# 주요 기능:
# - DB와 서버 컨테이너 상태 비교 후 자동 동기화
# - DB 조회 실패 시 자동 삭제 방지, 단일 컨테이너 실패 시 전체 중단 방지
# - 임시 설정 파일을 통한 안전한 DB 인증 정보 전달
# - 'docker inspect'와 'jq'를 사용한 안정적인 포트 정보 비교
# - 최종 실행 결과 요약 로그 제공
# =================================================================

# --- 스크립트 안정성을 위한 설정 ---
# 명령어가 하나라도 실패하면 즉시 스크립트를 중단합니다.
set -e
# 파이프로 연결된 명령어 중 하나라도 실패하면 전체를 실패로 간주합니다.
set -o pipefail

# --- 환경 설정 (환경 변수 우선 사용, 없으면 기본값으로) ---
DB_ADDRESS=${DB_ADDRESS:-"192.168.2.11"}
DB_PORT=${DB_PORT:-"3307"}
DB_NAME=${DB_NAME:-"nfs_db"}
DB_USER=${DB_USER:-"nfs_user"}
DB_PASSWORD=${DB_PASSWORD:-"nfs_password"}

# --- 스크립트 옵션 변수 ---
DRY_RUN=false
AUTO_DELETE=false

# --- 함수 정의 ---
log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }
log_error() { echo "[ERROR] $1"; }
log_critical() { echo "[CRITICAL] $1"; }

# 컨테이너 생성/재생성 함수
create_container() {
    # 함수에서 사용할 지역 변수 선언
    local cname=$1 image=$2 version=$3 uname=$4 uid=$5 gid=$6 dbid=$7 action=$8

    log_info "[$action] $cname (image=$image:$version, user=$uname)"

    local ports
    ports=$(mysql $MYSQL_CONN_ARGS -N -D "$DB_NAME" -e "SELECT port_number, purpose_of_use FROM used_ports WHERE docker_container_record_id=$dbid;")

    local port_args=""
    local port_check_failed=false # 포트 할당 실패 여부를 추적하는 플래그

    # DB에서 조회한 포트 목록을 하나씩 확인
    while read -r port purpose; do
        [ -z "$port" ] && continue
        
        # CREATE 액션일 때, 포트가 이미 사용 중인지 확인
        if [ "$action" == "CREATE" ] && ss -tulpn | grep -q ":$port "; then
            log_critical "Port $port ($purpose) is already in use. Aborting creation for $cname."
            port_check_failed=true
            break # 포트 하나라도 실패하면 더 이상 확인할 필요 없이 루프 중단
        fi

        case "$purpose" in
            ssh) port_args+=" -p ${port}:22" ;;
            "jupyter notebook") port_args+=" -p ${port}:8888" ;;
            *) port_args+=" -p ${port}:${port}" ;;
        esac
    done <<< "$ports"

    # 포트 확인 중 실패가 있었다면, 컨테이너를 생성하지 않고 함수 종료
    if [ "$port_check_failed" = true ]; then
        log_error "Container '$cname' was not created due to port conflict."
        return 1 # '실패'를 의미하는 종료 코드 1을 반환
    fi

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would run: docker run -dit --name \"$cname\" $port_args -e USER_ID=$uname -e UID=$uid -e GID=$gid dguailab/$image:$version"
    else
        docker run -dit \
            --name "$cname" \
            $port_args \
            -e USER_ID="$uname" -e UID="$uid" -e GID="$gid" \
            "dguailab/$image:$version"
    fi
}

# --- main ---

# 최종 결과 요약을 위한 카운터 변수를 0으로 초기화합니다.
ACTION_SUCCESS=0
ACTION_FAIL=0
NO_ACTION_NEEDED=0

# 스크립트 실행 시 전달된 옵션(--dry-run, --auto-delete)을 파싱합니다.
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --auto-delete) AUTO_DELETE=true ;;
  esac
done

log_info "Using DB: $DB_NAME at $DB_ADDRESS:$DB_PORT"
log_info "Options: dry-run=$DRY_RUN, auto-delete=$AUTO_DELETE"

# 스크립트 실행에 필요한 명령어(mysql, docker, jq)가 설치되어 있는지 확인합니다.
for cmd in mysql docker jq; do
    if ! command -v "$cmd" &> /dev/null; then
        log_critical "$cmd could not be found. Please install it."
        exit 1
    fi
done

# DB 접속 정보를 담을 임시 파일을 생성하고, 스크립트 종료 시(EXIT) 자동으로 삭제되도록 trap을 설정합니다.
MY_CNF_FILE=$(mktemp)
trap 'rm -f "$MY_CNF_FILE"' EXIT

# 임시 파일에 DB 접속 정보를 기록하고, 보안을 위해 다른 사용자는 읽을 수 없도록 권한을 600으로 설정합니다.
cat <<EOF > "$MY_CNF_FILE"
[client]
user=$DB_USER
password=$DB_PASSWORD
host=$DB_ADDRESS
port=$DB_PORT
EOF
chmod 600 "$MY_CNF_FILE"

# mysql 명령어에 임시 설정 파일을 사용하도록 지시하는 옵션을 변수에 저장합니다.
export MYSQL_CONN_ARGS="--defaults-extra-file=$MY_CNF_FILE"

# DB에서 동기화할 컨테이너 목록을 불러옵니다.
containers=$(mysql $MYSQL_CONN_ARGS -N -D "$DB_NAME" -e "
SELECT dc.container_name, dc.image, dc.image_version,
       u.ubuntu_username, u.ubuntu_uid, u.ubuntu_gid,
       dc.server_id, dc.id
FROM docker_container dc
JOIN user u ON dc.user_id=u.id
WHERE dc.existing=1;
")

# --auto-delete 옵션이 켜졌을 때, DB 조회 결과가 비어있으면 모든 컨테이너를 삭제하는 참사를 막는 안전장치입니다.
if [ -z "$containers" ] && [ "$AUTO_DELETE" = true ]; then
    log_critical "DB returned no containers. Aborting to prevent accidental deletion of all running containers."
    exit 1
fi

log_info "Loaded $(echo "$containers" | wc -l | xargs) containers from DB."

# 현재 서버의 도커 컨테이너 상태를 다른 임시 파일에 저장합니다.
DOCKER_STATUS_FILE=$(mktemp)
# trap을 다시 설정하여, 스크립트 종료 시 두 개의 임시 파일을 모두 삭제하도록 합니다.
trap 'rm -f "$MY_CNF_FILE" "$DOCKER_STATUS_FILE"' EXIT
docker ps -a --format "{{.Names}} {{.State}}" > "$DOCKER_STATUS_FILE"

# DB에서 읽어온 컨테이너 목록을 한 줄씩 반복 처리합니다.
while read -r cname image version uname uid gid sid dbid; do
    server_status=$(grep -E "^${cname}[[:space:]]" "$DOCKER_STATUS_FILE" | awk '{print $2}' || true)

    # DB에는 있으나 서버에는 없는 경우 -> CREATE
    if [ -z "$server_status" ]; then
        # create_container 함수의 성공/실패 여부를 확인하여 카운트를 올립니다.
        # 함수가 실패(return 1)하더라도 스크립트가 중단되지 않습니다.
        if create_container "$cname" "$image" "$version" "$uname" "$uid" "$gid" "$dbid" "CREATE"; then
            ((ACTION_SUCCESS++))
        else
            ((ACTION_FAIL++))
        fi
        continue
    fi

    # (2) 서버에는 있으나 정지(exited)된 경우 -> RESTART
    if [ "$server_status" == "exited" ]; then
        if $DRY_RUN; then
            log_info "[DRY-RUN] Would restart $cname"
        else
            log_info "[RESTART] $cname"
            docker start "$cname"
        fi
        ((ACTION_SUCCESS++))
        continue
    fi
    
    # (3) 서버와 DB 모두에 존재하는 경우 -> 세부 정보 비교
    mismatch=false
    
    actual_image=$(docker inspect --format '{{.Config.Image}}' "$cname")
    expected_image="dguailab/$image:$version"
    if [ "$actual_image" != "$expected_image" ]; then
        log_warn "[MISMATCH] Image differs for $cname: DB=$expected_image, Actual=$actual_image"
        mismatch=true
    fi

    actual_uid=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$cname" | grep '^UID=' | cut -d= -f2)
    actual_gid=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$cname" | grep '^GID=' | cut -d= -f2)
    if [ "$actual_uid" != "$uid" ] || [ "$actual_gid" != "$gid" ]; then
        log_warn "[MISMATCH] UID/GID differs for $cname: DB=$uid/$gid, Actual=$actual_uid/$actual_gid"
        mismatch=true
    fi
    
    db_ports_raw=$(mysql $MYSQL_CONN_ARGS -N -D "$DB_NAME" -e "SELECT port_number FROM used_ports WHERE docker_container_record_id=$dbid;")
    db_ports_sorted=$(echo "$db_ports_raw" | sort -n | tr '\n' ' ' | sed 's/ *$//')
    actual_ports_sorted=$(docker inspect "$cname" \
  | jq -r '[.[] | .NetworkSettings.Ports | to_entries[] | .value[]?.HostPort] | unique | .[]' \
  | sort -n | tr '\n' ' ' | sed 's/ *$//')

    if [ "$db_ports_sorted" != "$actual_ports_sorted" ]; then
        log_warn "[MISMATCH] Ports differ for $cname"
        log_warn "  DB ports:     [$db_ports_sorted]"
        log_warn "  Actual ports: [$actual_ports_sorted]"
        mismatch=true
    fi

    # 불일치 시 RECREATE, 일치 시 OK
    if $mismatch; then
        if $DRY_RUN; then
            log_info "[DRY-RUN] Would recreate $cname due to mismatch."
        else
            log_info "[RECREATE] $cname due to mismatch."
            docker rm -f "$cname"
            # RECREATE 시에도 성공/실패 카운트를 동일하게 적용합니다.
            if create_container "$cname" "$image" "$version" "$uname" "$uid" "$gid" "$dbid" "RECREATE"; then
                ((ACTION_SUCCESS++))
            else
                ((ACTION_FAIL++))
            fi
        fi
    else
        log_info "[OK] $cname is running and matches DB configuration."
        ((NO_ACTION_NEEDED++))
    fi
done <<<"$containers"

# (4) 서버에는 있으나 DB에는 없는 경우 -> DELETE (옵션)
server_only_containers=$(comm -23 \
    <(awk '{print $1}' "$DOCKER_STATUS_FILE" | sort) \
    <(echo "$containers" | awk '{print $1}' | sort))

if [ -n "$server_only_containers" ]; then
    if $AUTO_DELETE; then
        for c in $server_only_containers; do
            if $DRY_RUN; then
                echo "[DRY-RUN] Would delete $c (not in DB)"
            else
                log_warn "[DELETE] $c (not in DB)"
                docker rm -f "$c"
                ((ACTION_SUCCESS++))
            fi
        done
    else
        log_warn "Containers on server but not in DB:"
        echo "$server_only_containers"
    fi
fi

# 스크립트 실행이 끝난 후, 최종적으로 몇 개의 작업이 성공/실패했는지, 또는 필요 없었는지 요약하여 보여줍니다.
log_info "========================================"
log_info " Sync Summary"
log_info "----------------------------------------"
log_info " Succeeded Actions : $ACTION_SUCCESS"
log_info " Failed Actions    : $ACTION_FAIL"
log_info " No Action Needed  : $NO_ACTION_NEEDED"
log_info "========================================"
log_info "Sync completed."
