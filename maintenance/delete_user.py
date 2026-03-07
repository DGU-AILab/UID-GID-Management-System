#!/usr/bin/env python3
"""
사용자를 데이터베이스에서 삭제하는 스크립트

사용법:
    python maintenance/delete_user.py <username1> [username2] [username3] ...

예시:
    python maintenance/delete_user.py test250420
    python maintenance/delete_user.py user1 user2 user3
"""

import pymysql
import sys
import argparse

# 데이터베이스 연결 정보
import os

def resolve_db_config_path():
    """우선순위에 따라 DB 설정 파일 경로를 반환합니다."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    candidates = [os.path.join(project_root, 'config', 'db_config.local.env')]

    for path in candidates:
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

    with open(config_file, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                if '=' in line:
                    key, value = line.split('=', 1)
                    config[key.strip()] = value.strip()

    return {
        'host': config['DB_HOST'],
        'port': int(config['DB_PORT']),
        'user': config['DB_USER'],
        'password': config['DB_PASSWORD'],
        'database': config['DB_NAME'],
        'charset': config['DB_CHARSET']
    }

DB_CONFIG = load_db_config()

def get_users_info(cursor, usernames):
    """삭제할 사용자 정보 조회"""
    placeholders = ', '.join(['%s'] * len(usernames))
    query = f"""
    SELECT id, name, ubuntu_username, ubuntu_uid, ubuntu_gid
    FROM user
    WHERE ubuntu_username IN ({placeholders})
    """
    cursor.execute(query, usernames)
    return cursor.fetchall()

def delete_users(usernames, delete_group=True, delete_used_ids=True):
    """사용자 및 관련 데이터 삭제"""
    try:
        connection = pymysql.connect(**DB_CONFIG)
        cursor = connection.cursor()

        # 삭제할 사용자 정보 조회
        users = get_users_info(cursor, usernames)

        if not users:
            print("삭제할 사용자를 찾을 수 없습니다.")
            return False

        print("\n삭제할 사용자:")
        print("-" * 60)
        user_ids = []
        uids = []
        gids = []

        for user in users:
            user_id, name, username, uid, gid = user
            print(f"  ID: {user_id}, 이름: {name}, 아이디: {username}, UID: {uid}, GID: {gid}")
            user_ids.append(user_id)
            uids.append(uid)
            if gid:
                gids.append(gid)

        print("-" * 60)

        # 확인
        confirm = input("\n위 사용자를 삭제하시겠습니까? (y/N): ")
        if confirm.lower() != 'y':
            print("삭제가 취소되었습니다.")
            return False

        # 트랜잭션 시작
        connection.begin()

        placeholders = ', '.join(['%s'] * len(usernames))

        # 1. used_ports 삭제
        cursor.execute(f"""
            DELETE FROM used_ports
            WHERE docker_container_record_id IN (
                SELECT dc.id FROM docker_container dc
                INNER JOIN user u ON dc.user_id = u.id
                WHERE u.ubuntu_username IN ({placeholders})
            )
        """, usernames)
        ports_deleted = cursor.rowcount
        print(f"✓ used_ports 삭제: {ports_deleted}개")

        # 2. docker_container 삭제
        cursor.execute(f"""
            DELETE FROM docker_container
            WHERE user_id IN (
                SELECT id FROM user
                WHERE ubuntu_username IN ({placeholders})
            )
        """, usernames)
        containers_deleted = cursor.rowcount
        print(f"✓ docker_container 삭제: {containers_deleted}개")

        # 3. user 삭제
        cursor.execute(f"""
            DELETE FROM user
            WHERE ubuntu_username IN ({placeholders})
        """, usernames)
        users_deleted = cursor.rowcount
        print(f"✓ user 삭제: {users_deleted}개")

        # 4. group 삭제 (옵션)
        if delete_group and gids:
            gid_placeholders = ', '.join(['%s'] * len(gids))
            # 같은 GID를 사용하는 다른 사용자가 있는지 확인
            cursor.execute(f"""
                DELETE FROM `group`
                WHERE ubuntu_gid IN ({gid_placeholders})
                AND ubuntu_gid NOT IN (SELECT ubuntu_gid FROM user WHERE ubuntu_gid IS NOT NULL)
            """, gids)
            groups_deleted = cursor.rowcount
            print(f"✓ group 삭제: {groups_deleted}개")

        # 5. used_ids 정리 (옵션)
        if delete_used_ids and uids:
            uid_placeholders = ', '.join(['%s'] * len(uids))
            # group에서 참조하지 않는 UID만 삭제
            cursor.execute(f"""
                DELETE FROM used_ids
                WHERE id IN ({uid_placeholders})
                AND id NOT IN (SELECT ubuntu_gid FROM `group`)
            """, uids)
            ids_deleted = cursor.rowcount
            print(f"✓ used_ids 정리: {ids_deleted}개")

        # 커밋
        connection.commit()
        print("\n✓ 삭제가 완료되었습니다.")
        return True

    except pymysql.Error as e:
        print(f"데이터베이스 오류: {e}")
        if connection:
            connection.rollback()
        return False
    finally:
        if cursor:
            cursor.close()
        if connection:
            connection.close()

def main():
    parser = argparse.ArgumentParser(
        description='사용자를 데이터베이스에서 삭제합니다.',
        epilog='예시: python maintenance/delete_user.py test250420 user1 user2'
    )
    parser.add_argument(
        'usernames',
        nargs='+',
        help='삭제할 사용자의 ubuntu_username (여러 개 가능)'
    )
    parser.add_argument(
        '--no-group',
        action='store_true',
        help='관련 그룹을 삭제하지 않음'
    )
    parser.add_argument(
        '--no-cleanup-ids',
        action='store_true',
        help='used_ids 테이블을 정리하지 않음'
    )

    args = parser.parse_args()

    print("=" * 60)
    print("사용자 삭제 스크립트")
    print("=" * 60)

    delete_users(
        args.usernames,
        delete_group=not args.no_group,
        delete_used_ids=not args.no_cleanup_ids
    )

if __name__ == "__main__":
    main()
