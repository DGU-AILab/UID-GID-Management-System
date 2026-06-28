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
        "LAB_KERBEROS_AD_DC_HOST": "lab2",
        "LAB_KERBEROS_AD_NETBIOS": "LAB",
        "LAB_KERBEROS_NIS_DOMAIN": "lab",
        "LAB_KERBEROS_STORAGE_USER_SHARE_ROOT": "/294t/share/test-krb/user-share",
        "LAB_KERBEROS_MOUNT_USER_SHARE_ROOT": "/mnt/decs-lab-test-krb/user-share",
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


def test_dry_run_new_user_can_use_requested_uid_gid():
    repo = FakeRepository()
    service = ContainerCreateService(config(), repo, FakeAnsibleRunner(), FakePostActions())
    result = service.execute(request(requested_uid=10018, requested_gid=10019))

    rendered = result.plan.render()
    assert result.uid == 10018
    assert result.gid == 10019
    assert "identity_source: requested" in rendered
    assert "requested_uid: 10018" in rendered
    assert "requested_gid: 10019" in rendered
    assert "UID='10018'" in result.plan.commands[0]
    assert "GID='10019'" in result.plan.commands[0]


def test_requested_uid_conflicting_with_db_user_is_rejected():
    repo = FakeRepository()
    repo.users["bob"] = UserRecord(2, "Bob", "bob", 10018, 10018)
    service = ContainerCreateService(config(), repo, FakeAnsibleRunner(), FakePostActions())

    try:
        service.execute(request(requested_uid=10018))
    except ValidationError as exc:
        assert "--uid 10018 already belongs to user bob" in str(exc)
    else:
        raise AssertionError("expected requested uid conflict")


def test_requested_gid_conflicting_with_db_group_is_rejected():
    repo = FakeRepository()
    repo.groups["projectb"] = GroupRecord(2, "projectb", 10019)
    service = ContainerCreateService(config(), repo, FakeAnsibleRunner(), FakePostActions())

    try:
        service.execute(request(requested_gid=10019))
    except ValidationError as exc:
        assert "--gid 10019 already belongs to group projectb" in str(exc)
    else:
        raise AssertionError("expected requested gid conflict")


def test_requested_uid_must_match_existing_user():
    repo = FakeRepository()
    repo.users["alice"] = UserRecord(1, "Alice", "alice", 10020, 10020)
    service = ContainerCreateService(config(), repo, FakeAnsibleRunner(), FakePostActions())

    try:
        service.execute(request(requested_uid=10018))
    except ValidationError as exc:
        assert "existing user alice has uid 10020, requested 10018" in str(exc)
    else:
        raise AssertionError("expected existing user requested uid mismatch")


def test_dry_run_lab_user_uses_lab_mount_template():
    repo = FakeRepository()
    service = ContainerCreateService(config(), repo, FakeAnsibleRunner(), FakePostActions())
    result = service.execute(request(domain="LAB", server_number=2))

    assert result.server_id == "LAB2"
    assert "--mount type=bind,source='/home/tako2/share/user-share/',target=/home" in result.plan.commands[0]
    assert any("LAB storage home" in step for step in result.plan.steps)


def test_lab_new_user_adopts_existing_storage_home_owner():
    repo = FakeRepository()
    remote = FakeAnsibleRunner()
    remote.raw_outputs = ["present 10051 10051\n"]
    service = ContainerCreateService(config(), repo, remote, FakePostActions())
    result = service.execute(request(domain="LAB", server_number=8))

    assert result.uid == 10051
    assert result.gid == 10051
    assert "identity_source: storage_home" in result.plan.render()
    assert "adopted_storage_home: /294t/dcloud/share/user-share/alice" in result.plan.render()


def test_apply_lab_adopted_storage_home_owner_writes_db_with_that_uid():
    repo = FakeRepository()
    remote = FakeAnsibleRunner()
    remote.raw_outputs = ["present 10051 10051\n"]
    service = ContainerCreateService(config(), repo, remote, FakePostActions())
    result = service.execute(request(domain="LAB", server_number=8, dry_run=False))

    assert result.uid == 10051
    assert repo.users["alice"].uid == 10051
    assert repo.groups["alice"].gid == 10051
    assert 10051 in repo.used_id_values


def test_lab_storage_home_owner_conflict_is_rejected():
    repo = FakeRepository()
    repo.users["bob"] = UserRecord(2, "Bob", "bob", 10051, 10051)
    remote = FakeAnsibleRunner()
    remote.raw_outputs = ["present 10051 10051\n"]
    service = ContainerCreateService(config(), repo, remote, FakePostActions())

    try:
        service.execute(request(domain="LAB", server_number=8))
    except ValidationError as exc:
        assert "uid 10051 already belongs to bob" in str(exc)
    else:
        raise AssertionError("expected storage uid conflict")


def test_requested_uid_gid_must_match_adopted_storage_home():
    repo = FakeRepository()
    remote = FakeAnsibleRunner()
    remote.raw_outputs = ["present 10051 10051\n"]
    service = ContainerCreateService(config(), repo, remote, FakePostActions())

    try:
        service.execute(request(domain="LAB", server_number=8, requested_uid=10018, requested_gid=10018))
    except ValidationError as exc:
        assert "selected=10018:10018 storage=10051:10051" in str(exc)
    else:
        raise AssertionError("expected requested id and storage home mismatch")


def test_dry_run_lab_kerberos_uses_lab_realm_and_ccache():
    repo = FakeRepository()
    service = ContainerCreateService(config(), repo, FakeAnsibleRunner(), FakePostActions())
    result = service.execute(request(domain="LAB", server_number=8, enable_kerberos=True))

    command = result.plan.commands[0]
    rendered = result.plan.render()
    assert result.server_id == "LAB8"
    assert "ad_username: alice" in rendered
    assert "ad_private_group: alice_gid" in rendered
    assert "ad_primary_group: alice_gid" in rendered
    assert "kerberos_principal: alice@LAB.DECS.INTERNAL" in rendered
    assert "kerberos_realm: LAB.DECS.INTERNAL" in rendered
    assert "kerberos_storage_home: /294t/share/test-krb/user-share/alice" in rendered
    assert "KRB5CCNAME='FILE:/run/user/10000/krb5cc'" in command
    assert "DECS_KRB5_PRINCIPAL='alice@LAB.DECS.INTERNAL'" in command
    assert "KRB5_REALM='LAB.DECS.INTERNAL'" in command
    assert "DECS_USER_SUDO_MODE='restricted'" in command
    assert "--mount type=bind,source='/mnt/decs-lab-test-krb/user-share/',target=/home" in command


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


def test_apply_lab_kerberos_prepares_samba_ad_keytab_storage_home_and_access_check():
    repo = FakeRepository()
    remote = FakeAnsibleRunner()
    post = FakePostActions()
    service = ContainerCreateService(config(), repo, remote, post)
    result = service.execute(request(domain="LAB", server_number=8, enable_kerberos=True, dry_run=False, skip_post_actions=False))

    raw_commands = "\n".join(command for _, command in remote.raw_calls)
    shell_commands = "\n".join(command for _, command in remote.shell_calls)
    local_commands = "\n".join(" ".join(command) for command in remote.local_runner.commands)
    assert result.runtime_gid == 10000
    assert "kadmin.local" not in raw_commands
    assert "/294t/share/test-krb/user-share/alice" in raw_commands
    assert "kerberos_lab_storage_ad_home_ready" in raw_commands
    assert "getent passwd \"$username\"" in raw_commands
    assert "samba-tool user create \"$username\"" in shell_commands
    assert "principal=alice@LAB.DECS.INTERNAL" in shell_commands
    assert "keytab_file=/etc/decs-krb/keytabs/alice.keytab" in shell_commands
    assert "kerberos_lab_host_ad_identity_ready" in shell_commands
    assert "decs-krb-refresh" in shell_commands
    assert "setpriv --reuid=10000 --regid=10000" in shell_commands
    assert "src=/etc/decs-krb/keytabs/alice.keytab" in local_commands
    docker_runs = [command for _, command in remote.shell_calls if command.startswith("docker run")]
    assert docker_runs and "DECS_KRB5_PRINCIPAL='alice@LAB.DECS.INTERNAL'" in docker_runs[0]
    assert docker_runs and "KRB5_REALM='LAB.DECS.INTERNAL'" in docker_runs[0]
    identity = repo.kerberos_identities["alice"]
    assert identity.ad_realm == "LAB.DECS.INTERNAL"
    assert identity.ad_netbios_domain == "LAB"
    assert identity.ad_uid_number == 10000
    assert identity.ad_gid_number == 10000
    assert identity.last_seen_nfs_uid == 10000
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
    assert "samba-tool user setprimarygroup \"$username\" \"$groupname\"" in shell_commands
    assert "groupname=projecta" in shell_commands
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
    assert "ad_private_group: farm_jy_gid" in rendered
    assert "ad_primary_group: farm_jy_gid" in rendered
    assert "kerberos_principal: farm_jy@FARM.DECS.INTERNAL" in rendered
    assert "ad_unix_uid: 1003" in rendered
    assert "ad_unix_gid: 1003" in rendered
    assert "DECS_KRB5_PRINCIPAL='farm_jy@FARM.DECS.INTERNAL'" in command
    assert "USER_ID='jy'" in command
    assert "UID='1003'" in command
    assert "GID='1003'" in command
    assert "TARGET_UID" not in command
    assert "TARGET_GID" not in command
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
    assert "identity='FARM\\farm_jy'" in raw_commands
    assert 'wbinfo_bin" -i "$identity"' in raw_commands
    assert 'id -u "$identity"' in raw_commands
    assert "samba-tool user create \"$username\"" in shell_commands
    assert "groupname=farm_jy_gid" in shell_commands
    assert "samba-tool user setprimarygroup \"$username\" \"$groupname\"" in shell_commands
    assert "principal=farm_jy@FARM.DECS.INTERNAL" in shell_commands
    assert "uid=1003" in shell_commands
    assert "gid=1003" in shell_commands
    assert "setpriv --reuid=1003 --regid=1003" in shell_commands
    docker_runs = [command for _, command in remote.shell_calls if command.startswith("docker run")]
    assert docker_runs and "UID='1003'" in docker_runs[0] and "GID='1003'" in docker_runs[0]
    assert "TARGET_UID" not in docker_runs[0]
    assert "TARGET_GID" not in docker_runs[0]
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
