from uid_manager.config import AppConfig, compose_ansible_host_alias, compose_server_id, split_server_id
from uid_manager.kerberos.paths import KerberosPaths
from uid_manager.ports import allocate_ports
from uid_manager.validation import validate_identity_name


def config() -> AppConfig:
    return AppConfig.from_mapping({
        "LAB_DB_HOST": "192.168.1.11",
        "FARM_DB_HOST": "192.168.2.11",
        "DB_USER": "u",
        "DB_PASSWORD": "p",
        "ANSIBLE_INVENTORY": "/tmp/inventory.ini",
    })


def test_server_id_helpers():
    assert split_server_id("farm2") == ("FARM", 2)
    assert compose_server_id("lab", 10) == "LAB10"
    assert compose_ansible_host_alias("FARM", 2) == "farm2"


def test_identity_validation_allows_existing_script_pattern():
    assert validate_identity_name("alice_1.test-user") == "alice_1.test-user"


def test_port_allocation_covers_ssh_jupyter_vnc_and_extra_ports():
    mappings = allocate_ports(2, used_ports={9100, 9101}, additional_container_ports=[7000, 7001], enable_vnc=True)
    assert [(m.host_port, m.container_port, m.purpose) for m in mappings] == [
        (9102, 22, "ssh"),
        (9103, 8888, "jupyter notebook"),
        (9104, 6080, "vnc"),
        (9105, 7000, "container port 7000"),
        (9106, 7001, "container port 7001"),
    ]


def test_kerberos_paths_match_current_farm_defaults():
    cfg = config()
    paths = KerberosPaths("alice", 10123, cfg, cfg.farm_kerberos_mount_user_share_root_for_server(2))
    assert paths.principal == "alice@FARM.DECS.INTERNAL"
    assert paths.nas_home == "/volume1/share/user-share/alice"
    assert paths.host_home == "/home/tako2/share/user-share/alice"
    assert paths.ccache_file == "/run/user/10123/krb5cc"
    assert paths.keytab_file == "/etc/decs-krb/keytabs/alice.keytab"
