from uid_manager.config import AppConfig
from uid_manager.kerberos.commands import (
    build_ccache_dir_command,
    build_nas_gss_refresh_command,
    build_nas_prepare_home_command,
    build_nfs_access_check_command,
)
from uid_manager.kerberos.paths import KerberosPaths
from uid_manager.models import ContainerRecord
from uid_manager.services.sync_containers import ContainerSyncService
from uid_manager.runners import AnsibleRunner, RecordingRunner


def config() -> AppConfig:
    return AppConfig.from_mapping({
        "LAB_DB_HOST": "192.168.1.11",
        "FARM_DB_HOST": "192.168.2.11",
        "DB_USER": "u",
        "DB_PASSWORD": "p",
        "ANSIBLE_INVENTORY": "/tmp/inventory.ini",
        "FARM_KERBEROS_NFS_ACCESS_INITIAL_DELAY": "30",
    })


def test_nas_prepare_and_refresh_commands_cover_root_squash_and_cache_flush():
    prepare = build_nas_prepare_home_command("/volume1/share/user-share/alice", 10123, 10123, "sudo -n")
    assert "mkdir -p /volume1/share/user-share/alice" in prepare
    assert "chown 10123:10123" in prepare
    assert "chmod 750" in prepare

    refresh = build_nas_gss_refresh_command(config())
    assert "svcgssd" in refresh
    assert "idmapd" in refresh
    assert "/proc/net/rpc/auth.rpcsec.context/flush" in refresh


def test_ansible_raw_quotes_ssh_common_args_with_spaces():
    runner = RecordingRunner()
    AnsibleRunner("/tmp/inventory.ini", runner).raw(
        "192.168.1.20",
        "true",
        user="jy",
        port=6953,
        ssh_common_args="-o ProxyJump=jy@192.168.1.12:8082",
    )
    command = list(runner.commands[0])
    assert "ansible_ssh_common_args='-o ProxyJump=jy@192.168.1.12:8082'" in command


def test_ccache_and_access_check_commands_cover_uid_spoof_sensitive_flow():
    cfg = config()
    paths = KerberosPaths("alice", 10123, cfg)
    ccache = build_ccache_dir_command(cfg, paths, 96470003)
    assert "install -d -o 10123 -g 96470003 -m 0700 /run/user/10123" in ccache

    access = build_nfs_access_check_command(cfg, "alice", 10123, 96470003, paths)
    assert "sleep 30" in access
    assert "setpriv --reuid=10123 --regid=96470003 --clear-groups" in access
    assert "KRB5CCNAME=FILE:/run/user/10123/krb5cc" in access


def test_sync_plan_detects_create_ok_and_server_only_delete_warning():
    records = [
        ContainerRecord(1, "a", "alice_by_jy", "FARM2", "decs", "v1", "alice"),
        ContainerRecord(2, "b", "bob_by_jy", "FARM2", "decs", "v1", "bob"),
    ]
    plan = ContainerSyncService().plan_from_records(records, running_names={"alice_by_jy": "running", "orphan": "running"}, auto_delete=False)
    rendered = plan.render()
    assert "OK alice_by_jy" in rendered
    assert "CREATE bob_by_jy" in rendered
    assert "WARN orphan exists on server but not DB" in rendered

    plan = ContainerSyncService().plan_from_records(records, running_names={"alice_by_jy": "running", "orphan": "running"}, auto_delete=True)
    assert "DELETE orphan not in DB" in plan.render()


def test_sync_apply_creates_missing_restarts_exited_and_deletes_orphan():
    record = ContainerRecord(
        1,
        "a",
        "alice_by_jy",
        "FARM2",
        "decs",
        "v1",
        "alice",
        uid=10123,
        gid=10123,
        port_specs="9100:ssh|9101:jupyter notebook|9102:container port 7000",
    )
    runner = RecordingRunner(outputs=["bob_by_jy exited\norphan running\n"])
    plan = ContainerSyncService(runner).execute([record, ContainerRecord(2, "b", "bob_by_jy", "FARM2", "decs", "v1", "bob")], dry_run=False, auto_delete=True)
    commands = [" ".join(command) for command in runner.commands]
    assert "CREATE alice_by_jy" in plan.render()
    assert any("docker run -dit --init --name alice_by_jy -p 9100:22 -p 9101:8888 -p 9102:7000" in command for command in commands)
    assert any("docker start bob_by_jy" in command for command in commands)
    assert any("docker rm -f orphan" in command for command in commands)
