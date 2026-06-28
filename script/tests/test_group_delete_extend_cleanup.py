from uid_manager.config import AppConfig
from uid_manager.models import ContainerRecord, DeleteContainerRequest, ExtendContainerRequest, GroupRecord, GroupRequest, KerberosIdentityRecord, UserRecord
from uid_manager.services.delete_container import ContainerDeleteService
from uid_manager.services.expired_cleanup import ExpiredCleanupService
from uid_manager.services.extend_container import ContainerExtendService
from uid_manager.services.manage_group import GroupManagementService

from .fakes import FakeAnsibleRunner, FakePostActions, FakeRepository


def config() -> AppConfig:
    return AppConfig.from_mapping({
        "LAB_DB_HOST": "192.168.1.11",
        "FARM_DB_HOST": "192.168.2.11",
        "DB_USER": "u",
        "DB_PASSWORD": "p",
        "ANSIBLE_INVENTORY": "/tmp/inventory.ini",
    })


def repo_with_container() -> FakeRepository:
    repo = FakeRepository()
    repo.users["alice"] = UserRecord(1, "Alice", "alice", 10123, 10123, "alice@example.com")
    repo.groups["alice"] = GroupRecord(1, "alice", 10123)
    repo.containers.append(ContainerRecord(1, "abc123", "alice_by_jy", "FARM2", "decs", "v1", "alice", "Alice", "alice@example.com", "2026-12-31", "9100, 9101", uid=10123, gid=10123))
    repo.used_port_values = {9100, 9101}
    repo.pending_ports = {9100: "ssh", 9101: "jupyter notebook"}
    return repo


def test_delete_dry_run_matches_by_username_without_remote_change():
    repo = repo_with_container()
    remote = FakeAnsibleRunner()
    service = ContainerDeleteService(config(), repo, remote, FakePostActions())
    plan = service.execute(DeleteContainerRequest(domain="FARM", server_number=2, filter_username="alice", dry_run=True))

    assert "alice_by_jy" in plan.render()
    assert repo.containers
    assert not remote.shell_calls


def test_delete_apply_marks_deleted_and_removes_remote_container():
    repo = repo_with_container()
    remote = FakeAnsibleRunner()
    post = FakePostActions()
    service = ContainerDeleteService(config(), repo, remote, post)
    service.execute(DeleteContainerRequest(domain="FARM", server_number=2, filter_username="alice", skip_post_actions=False))

    assert repo.containers == []
    assert any("docker rm -f 'abc123'" in command for _, command in remote.shell_calls)
    assert post.deleted
    assert post.backups == ["FARM"]
    assert post.exports == 1


def test_delete_last_user_container_removes_kerberos_refresh_secret_files():
    repo = repo_with_container()
    repo.kerberos_identities["alice"] = KerberosIdentityRecord(
        username="alice",
        ad_username="alice",
        ad_realm="FARM.DECS.INTERNAL",
        ad_netbios_domain="FARM",
        ad_domain_sid="S-1-5-21-1-2-3",
        ad_object_sid="S-1-5-21-1-2-3-1100",
        ad_uid_number=10123,
        ad_gid_number=10123,
    )
    remote = FakeAnsibleRunner()
    service = ContainerDeleteService(config(), repo, remote, FakePostActions())
    service.execute(DeleteContainerRequest(domain="FARM", server_number=2, filter_username="alice", skip_post_actions=True))

    commands = "\n".join(command for _, command in remote.shell_calls)
    assert "docker rm -f 'abc123'" in commands
    assert "decs-krb-refresh@${instance}.timer" in commands
    assert "DECS_KRB_CLEANUP_ENV=/etc/decs-krb/refresh.d/alice.env" in commands
    assert "DECS_KRB_CLEANUP_KEYTAB=/etc/decs-krb/keytabs/alice.keytab" in commands
    assert "DECS_KRB_CLEANUP_CCACHE=FILE:/run/user/10123/krb5cc" in commands


def test_delete_keeps_kerberos_refresh_when_same_user_has_another_container_on_host():
    repo = repo_with_container()
    repo.containers.append(ContainerRecord(2, "def456", "alice_second", "FARM2", "decs", "v1", "alice", "Alice", "alice@example.com", "2026-12-31", "9102", uid=10123, gid=10123))
    remote = FakeAnsibleRunner()
    service = ContainerDeleteService(config(), repo, remote, FakePostActions())
    service.execute(DeleteContainerRequest(domain="FARM", server_number=2, container_name="alice_by_jy", skip_post_actions=True))

    commands = "\n".join(command for _, command in remote.shell_calls)
    assert "docker rm -f 'abc123'" in commands
    assert "DECS_KRB_CLEANUP_ENV" not in commands
    assert [row.container_name for row in repo.containers] == ["alice_second"]


def test_extend_dry_run_and_apply_all_matches():
    farm = repo_with_container()
    lab = FakeRepository()
    service = ContainerExtendService(config(), {"FARM": farm, "LAB": lab}, FakePostActions())
    plan = service.execute(ExtendContainerRequest(expiration_date="2027-01-31", username="alice", domains="FARM,LAB"))
    assert "would update FARM alice_by_jy" in plan.render()

    post = FakePostActions()
    service = ContainerExtendService(config(), {"FARM": farm, "LAB": lab}, post)
    service.execute(ExtendContainerRequest(expiration_date="2027-01-31", username="alice", domains="FARM,LAB", apply_changes=True))
    assert farm.containers[0].expiring_at == "2027-01-31"
    assert post.extended and post.backups == ["FARM"]


def test_manage_group_add_user_and_set_primary():
    repo = FakeRepository()
    repo.users["alice"] = UserRecord(1, "Alice", "alice", 10123, 10123)
    repo.groups["alice"] = GroupRecord(1, "alice", 10123)
    remote = FakeAnsibleRunner()
    service = GroupManagementService(config(), repo, remote)

    service.execute(GroupRequest(action="add-user", groupname="projecta", username="alice", ad_host="farm2"))
    assert "projecta" in repo.groups
    assert repo.groups["projecta"].gid in repo.supplemental["alice"]
    assert any("message['gidNumber']" in command for _, command in remote.shell_calls)
    assert any("samba-tool group addmembers" in command for _, command in remote.shell_calls)

    service.execute(GroupRequest(action="set-primary", groupname="projecta", username="alice", ad_host="farm2"))
    assert repo.users["alice"].gid == repo.groups["projecta"].gid
    assert repo.supplemental["alice"] == []


def test_manage_group_delete_protects_active_primary_group():
    repo = FakeRepository()
    repo.users["alice"] = UserRecord(1, "Alice", "alice", 10123, 10123)
    repo.groups["alice"] = GroupRecord(1, "alice", 10123)
    service = GroupManagementService(config(), repo, FakeAnsibleRunner())

    try:
        service.execute(GroupRequest(action="delete", groupname="alice", ad_host="farm2"))
    except Exception as exc:
        assert "primary user" in str(exc)
    else:
        raise AssertionError("expected primary-group delete protection")


def test_expired_cleanup_dry_run_and_apply_marks_db_deleted():
    repo = repo_with_container()
    remote = FakeAnsibleRunner()
    post = FakePostActions()
    service = ExpiredCleanupService(config(), {"FARM": repo}, post, remote)

    plan = service.execute(today="2027-01-01", domains="FARM", apply_changes=False, username="alice")
    assert "expired alice_by_jy" in plan.render()
    assert repo.containers

    service.execute(today="2027-01-01", domains="FARM", apply_changes=True, username="alice")
    assert repo.containers == []
    assert any("docker rm -f 'abc123'" in command for _, command in remote.shell_calls)
    assert post.deleted
    assert post.backups == ["FARM"]
    assert post.exports == 1
