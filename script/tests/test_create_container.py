from uid_manager.config import AppConfig
from uid_manager.errors import ValidationError
from uid_manager.models import CreateContainerRequest, GroupRecord, KerberosIdentityRecord, UserRecord
from uid_manager.services.create_container import ContainerCreateService

from .fakes import FakeAnsibleRunner, FakePostActions, FakeRepository


def config() -> AppConfig:
    return AppConfig.from_mapping({
        "LAB_DB_HOST": "192.168.1.11",
        "FARM_DB_HOST": "192.168.2.11",
        "DB_USER": "u",
        "DB_PASSWORD": "p",
        "ANSIBLE_INVENTORY": "/tmp/inventory.ini",
    })


def request(**overrides) -> CreateContainerRequest:
    data = dict(
        name="Alice",
        username="alice",
        groupname=None,
        domain="FARM",
        server_number=2,
        expiration_date="2026-12-31",
        image="decs",
        version="krb-e2e-260621",
        container_name=None,
        additional_ports=[],
        enable_vnc=False,
        enable_kerberos=False,
        created_by="jy",
        email="alice@example.com",
        phone="010",
        dry_run=True,
        skip_post_actions=True,
    )
    data.update(overrides)
    return CreateContainerRequest(**data)


def test_dry_run_new_plain_farm_user_reuses_uid_as_group_gid():
    repo = FakeRepository()
    service = ContainerCreateService(config(), repo, FakeAnsibleRunner(), FakePostActions())
    result = service.execute(request())

    assert result.container_id == "DRY-RUN"
    assert result.uid == 10000
    assert result.gid == 10000
    assert result.ports[0].host_port == 9100
    assert "--mount type=bind,source='/volume1/share/user-share/',target=/home" in result.plan.commands[0]
    assert "DECS_USER_SUDO_MODE='restricted'" not in result.plan.commands[0]


def test_dry_run_lab_user_uses_lab_mount_template():
    repo = FakeRepository()
    service = ContainerCreateService(config(), repo, FakeAnsibleRunner(), FakePostActions())
    result = service.execute(request(domain="LAB", server_number=2))

    assert result.server_id == "LAB2"
    assert "--mount type=bind,source='/home/tako2/share/user-share/',target=/home" in result.plan.commands[0]
    assert any("LAB storage home" in step for step in result.plan.steps)


def test_dry_run_kerberos_container_sets_ccache_and_restricted_sudo():
    repo = FakeRepository()
    repo.used_port_values = {9100}
    service = ContainerCreateService(config(), repo, FakeAnsibleRunner(), FakePostActions())
    result = service.execute(request(groupname="projecta", enable_kerberos=True, enable_vnc=True, additional_ports=[7000]))

    command = result.plan.commands[0]
    assert result.uid == 10000
    assert result.gid == 10001
    assert [(m.host_port, m.container_port) for m in result.ports] == [(9101, 22), (9102, 8888), (9103, 6080), (9104, 7000)]
    assert "KRB5CCNAME='FILE:/run/user/10000/krb5cc'" in command
    assert "DECS_USER_SUDO_MODE='restricted'" in command
    assert "--mount type=bind,source='/home/tako2/share/user-share/',target=/home" in command
    assert "USER_PW=***" in command
    assert "VNC_PASSWORD=***" in command


def test_live_docker_ports_are_excluded_from_allocation():
    repo = FakeRepository()
    remote = FakeAnsibleRunner()
    remote.shell_outputs = [
        "22/tcp -> 0.0.0.0:9100\n8888/tcp -> [::]:9101\n6080/tcp -> 0.0.0.0:9102\n"
    ]
    service = ContainerCreateService(config(), repo, remote, FakePostActions())
    result = service.execute(request(enable_vnc=True))

    assert [(m.host_port, m.container_port) for m in result.ports] == [(9103, 22), (9104, 8888), (9105, 6080)]
    assert any("docker ps -q" in command for _, command in remote.shell_calls)


def test_existing_user_and_group_can_create_second_container_for_same_home():
    repo = FakeRepository()
    repo.users["alice"] = UserRecord(1, "Alice", "alice", 10123, 10123, "a@example.com")
    repo.groups["alice"] = GroupRecord(1, "alice", 10123)
    repo.used_id_values = {10123}
    repo.used_port_values = {9100, 9101}
    service = ContainerCreateService(config(), repo, FakeAnsibleRunner(), FakePostActions())
    result = service.execute(request(container_name="alice_second"))

    assert result.uid == 10123
    assert result.gid == 10123
    assert result.container_name == "alice_second"
    assert result.ports[0].host_port == 9102


def test_apply_plain_farm_prepares_nas_home_and_writes_db():
    repo = FakeRepository()
    remote = FakeAnsibleRunner()
    post = FakePostActions()
    service = ContainerCreateService(config(), repo, remote, post)
    result = service.execute(request(dry_run=False, skip_post_actions=False))

    assert result.container_id == "abc123def4567890"
    assert repo.users["alice"].uid == 10000
    assert repo.groups["alice"].gid == 10000
    assert repo.containers[0].container_name == "alice_by_jy"
    assert any("/volume1/share/user-share/alice" in command for _, command in remote.raw_calls)
    assert post.created and post.backups == ["FARM"] and post.exports == 1


def test_apply_no_db_record_creates_container_without_db_writes_or_exports():
    repo = FakeRepository()
    remote = FakeAnsibleRunner()
    post = FakePostActions()
    service = ContainerCreateService(config(), repo, remote, post)
    result = service.execute(request(dry_run=False, skip_post_actions=False, no_db_record=True))

    assert result.container_id == "abc123def4567890"
    assert not repo.users
    assert not repo.groups
    assert not repo.containers
    assert not repo.used_id_values
    assert not repo.used_port_values
    assert repo.commits == 0
    assert repo.rollbacks == 0
    assert post.created
    assert post.backups == []
    assert post.exports == 0


def test_apply_lab_prepares_storage_home_and_writes_db():
    repo = FakeRepository()
    remote = FakeAnsibleRunner()
    post = FakePostActions()
    service = ContainerCreateService(config(), repo, remote, post)
    result = service.execute(request(domain="LAB", server_number=2, dry_run=False, skip_post_actions=False))

    assert result.container_id == "abc123def4567890"
    assert any(host == "192.168.1.20" and "/294t/dcloud/share/user-share/alice" in command for host, command in remote.raw_calls)
    assert repo.containers[0].server_id == "LAB2"
    assert post.created and post.backups == ["LAB"] and post.exports == 1


def test_apply_kerberos_runs_ad_nas_refresh_ccache_and_access_check():
    repo = FakeRepository()
    remote = FakeAnsibleRunner()
    remote.raw_outputs = [
        "96470001 96470002\n",
        "96470003\n",
        "kerberos_nas_gss_services_restarted_and_rpc_caches_flushed\n",
    ]
    service = ContainerCreateService(config(), repo, remote, FakePostActions())
    result = service.execute(request(groupname="projecta", enable_kerberos=True, dry_run=False))

    raw_commands = "\n".join(command for _, command in remote.raw_calls)
    shell_commands = "\n".join(command for _, command in remote.shell_calls)
    assert result.runtime_gid == 10001
    assert "wbinfo_bin" in raw_commands
    assert "svcgssd" in raw_commands
    assert "samba-tool user create" in shell_commands
    assert "message['gidNumber']" in shell_commands
    assert "message['uidNumber']" in shell_commands
    assert "decs-krb-refresh" in shell_commands
    assert "kerberos_nfs_owner_uid_mismatch" in shell_commands
    assert "setpriv --reuid=10000 --regid=10001" in shell_commands
    docker_runs = [command for _, command in remote.shell_calls if command.startswith("docker run")]
    assert docker_runs and "-e GID='10001'" in docker_runs[0]
    identity = repo.kerberos_identities["alice"]
    assert identity.ad_username == "alice"
    assert identity.ad_uid_number == 10000
    assert identity.ad_gid_number == 10001
    assert identity.ad_object_sid.startswith("S-1-5-21-100-200-300-")
    assert identity.last_seen_nas_internal_uid == 96470001
    assert identity.last_seen_nfs_uid == 10000


def test_dry_run_kerberos_alias_separates_container_and_ad_identity():
    repo = FakeRepository()
    repo.users["jy"] = UserRecord(18, "JY", "jy", 1003, 1003)
    repo.groups["jy"] = GroupRecord(12, "jy", 1003)
    repo.used_id_values = {1003, 1004}
    service = ContainerCreateService(config(), repo, FakeAnsibleRunner(), FakePostActions())
    result = service.execute(request(username="jy", groupname=None, enable_kerberos=True, ad_username="farm_jy"))

    command = result.plan.commands[0]
    rendered = result.plan.render()
    assert result.uid == 1003
    assert result.gid == 1003
    assert "ad_username: farm_jy" in rendered
    assert "kerberos_principal: farm_jy@FARM.DECS.INTERNAL" in rendered
    assert "ad_unix_uid: 1003" in rendered
    assert "ad_unix_gid: 1003" in rendered
    assert "DECS_KRB5_PRINCIPAL='farm_jy@FARM.DECS.INTERNAL'" in command
    assert "USER_ID='jy'" in command
    assert "TARGET_UID='1003'" in command
    assert "TARGET_GID='1003'" in command
    assert "KRB5CCNAME='FILE:/run/user/1003/krb5cc'" in command


def test_apply_kerberos_alias_uses_db_uid_for_ad_host_and_container_identity():
    repo = FakeRepository()
    repo.users["jy"] = UserRecord(18, "JY", "jy", 1003, 1003)
    repo.groups["jy"] = GroupRecord(12, "jy", 1003)
    repo.used_id_values = {1003, 1004}
    remote = FakeAnsibleRunner()
    remote.raw_outputs = [
        "96470150 96469505\n",
        "kerberos_nas_gss_services_restarted_and_rpc_caches_flushed\n",
    ]
    service = ContainerCreateService(config(), repo, remote, FakePostActions())
    service.execute(request(username="jy", groupname=None, enable_kerberos=True, ad_username="farm_jy", dry_run=False))

    raw_commands = "\n".join(command for _, command in remote.raw_calls)
    shell_commands = "\n".join(command for _, command in remote.shell_calls)
    assert "wbinfo_bin\" -i 'FARM\\farm_jy'" in raw_commands
    assert "samba-tool user create \"$username\"" in shell_commands
    assert "principal=farm_jy@FARM.DECS.INTERNAL" in shell_commands
    assert "uid=1003" in shell_commands
    assert "gid=1003" in shell_commands
    assert "setpriv --reuid=1003 --regid=1003" in shell_commands
    docker_runs = [command for _, command in remote.shell_calls if command.startswith("docker run")]
    assert docker_runs and "TARGET_UID='1003'" in docker_runs[0] and "TARGET_GID='1003'" in docker_runs[0]
    identity = repo.kerberos_identities["jy"]
    assert identity.ad_username == "farm_jy"
    assert identity.ad_uid_number == 1003
    assert identity.ad_gid_number == 1003
    assert identity.last_seen_nas_internal_uid == 96470150


def test_apply_kerberos_rejects_ad_object_sid_mismatch_before_docker_run():
    repo = FakeRepository()
    repo.kerberos_identities["alice"] = KerberosIdentityRecord(
        username="alice",
        ad_username="alice",
        ad_realm="FARM.DECS.INTERNAL",
        ad_netbios_domain="FARM",
        ad_domain_sid="S-1-5-21-100-200-300",
        ad_object_sid="S-1-5-21-100-200-300-99999",
        ad_uid_number=10000,
        ad_gid_number=10000,
    )
    remote = FakeAnsibleRunner()
    service = ContainerCreateService(config(), repo, remote, FakePostActions())

    try:
        service.execute(request(enable_kerberos=True, dry_run=False))
    except ValidationError as exc:
        assert "Kerberos identity mismatch" in str(exc)
    else:
        raise AssertionError("expected Kerberos identity mismatch")

    assert not [command for _, command in remote.shell_calls if command.startswith("docker run")]
