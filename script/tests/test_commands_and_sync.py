from uid_manager.config import AppConfig
from uid_manager.kerberos.commands import (
    build_ad_group_command,
    build_ad_identity_command,
    build_ad_identity_metadata_command,
    build_ccache_dir_command,
    build_lab_ad_host_identity_check_command,
    build_lab_storage_ad_home_command,
    build_nas_gss_refresh_command,
    build_nas_prepare_home_command,
    build_nfs_access_check_command,
    build_nfs_owner_stat_command,
    build_nfs_owner_uid_check_command,
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
        "LAB_KERBEROS_AD_DC_HOST": "lab2",
        "LAB_KERBEROS_AD_NETBIOS": "LAB",
        "LAB_KERBEROS_NIS_DOMAIN": "lab",
        "LAB_KERBEROS_STORAGE_USER_SHARE_ROOT": "/294t/share/test-krb/user-share",
        "LAB_KERBEROS_MOUNT_USER_SHARE_ROOT": "/mnt/decs-lab-test-krb/user-share",
    })


def test_nas_prepare_and_refresh_commands_cover_root_squash_and_cache_flush():
    prepare = build_nas_prepare_home_command("/volume1/share/user-share/alice", 10123, 10123, "sudo -n")
    assert "home_dir=/volume1/share/user-share/alice" in prepare
    assert 'mkdir -p "$home_dir"' in prepare
    assert 'chown "$uid:$gid" "$home_dir"' in prepare
    assert "chmod 750" in prepare
    assert '"$home_dir/.jupyter" "$home_dir/decs_jupyter_lab" "$home_dir/.vnc"' in prepare

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
    paths = KerberosPaths("alice", 10123, cfg, cfg.farm_kerberos_mount_user_share_root_for_server(2))
    ccache = build_ccache_dir_command(cfg, paths, 96470003)
    assert "install -d -o 10123 -g 96470003 -m 0700 /run/user/10123" in ccache

    access = build_nfs_access_check_command(cfg, "alice", 10123, 96470003, paths)
    assert "sleep 30" in access
    assert "setpriv --reuid=10123 --regid=96470003 --clear-groups" in access
    assert "KRB5CCNAME=FILE:/run/user/10123/krb5cc" in access

    owner_check = build_nfs_owner_uid_check_command(cfg, 10123, 96470003, paths)
    assert "setpriv --reuid=10123 --regid=96470003 --clear-groups" in owner_check
    assert "KRB5CCNAME=FILE:/run/user/10123/krb5cc" in owner_check

    owner_stat = build_nfs_owner_stat_command(cfg, 10123, 96470003, paths)
    assert "setpriv --reuid=10123 --regid=96470003 --clear-groups" in owner_stat
    assert "stat -c '%u %g' /home/tako2/share/user-share/alice" in owner_stat


def test_lab_kerberos_commands_cover_samba_ad_and_storage_home_flow():
    cfg = config()
    paths = KerberosPaths(
        "alice",
        10123,
        cfg,
        "/mnt/decs-lab-test-krb/user-share",
        realm="LAB.DECS.INTERNAL",
        storage_home_root="/294t/share/test-krb/user-share",
        keytab_dir="/etc/decs-krb/keytabs",
    )
    group = build_ad_group_command(cfg, "alice_gid", 10123, domain="LAB")
    assert "nis_domain=lab" in group
    assert "samba-tool group add \"$groupname\"" in group
    assert "message['gidNumber']" in group

    identity = build_ad_identity_command(cfg, "alice", 10123, "alice_gid", 10123, paths, rotate=False, domain="LAB")
    assert "principal=alice@LAB.DECS.INTERNAL" in identity
    assert "samba-tool user create \"$username\"" in identity
    assert "samba-tool user setprimarygroup \"$username\" \"$groupname\"" in identity
    assert "samba-tool domain exportkeytab \"$tmp_keytab\" --principal=\"$principal\"" in identity
    assert "keytab_file=/etc/decs-krb/keytabs/alice.keytab" in identity
    assert "kadmin.local" not in identity

    metadata = build_ad_identity_metadata_command(cfg, "alice", domain="LAB")
    assert "realm=LAB.DECS.INTERNAL" in metadata
    assert "netbios=LAB" in metadata

    storage = build_lab_storage_ad_home_command(cfg, paths.storage_home, "alice", 10123, "alice_gid", 10123)
    assert "home_dir=/294t/share/test-krb/user-share/alice" in storage
    assert 'getent passwd "$username"' in storage
    assert 'getent group "$groupname"' in storage
    assert 'chown "$uid:$gid" "$home_dir"' in storage
    assert '"$home_dir/.jupyter" "$home_dir/decs_jupyter_lab" "$home_dir/.vnc"' in storage
    assert 'touch "$home_dir/.jupyter/jupyter_notebook_config.py"' in storage
    assert "/proc/net/rpc/nfs4.idtoname/flush" in storage

    host = build_lab_ad_host_identity_check_command(cfg, "alice", 10123, "alice_gid", 10123)
    assert 'getent passwd "$username"' in host
    assert 'getent group "$groupname"' in host
    assert "kerberos_lab_host_ad_identity_ready" in host


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
