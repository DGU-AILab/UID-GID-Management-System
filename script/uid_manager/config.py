from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, Optional

from .errors import ValidationError


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG_PATH = PROJECT_ROOT / "config" / "db_config.local.env"


def _strip_env_value(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value


def load_env_file(path: Path) -> Dict[str, str]:
    values: Dict[str, str] = {}
    with path.open("r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = _strip_env_value(value)
    return values


def _get(values: Dict[str, str], key: str, default: str = "") -> str:
    return values.get(key, default)


def _get_int(values: Dict[str, str], key: str, default: int) -> int:
    raw = values.get(key)
    if raw is None or raw == "":
        return default
    try:
        return int(raw)
    except ValueError as exc:
        raise ValidationError(f"{key} must be an integer") from exc


@dataclass(frozen=True)
class AppConfig:
    db_port: int
    db_name: str
    db_user: str
    db_password: str
    db_charset: str
    lab_db_host: str
    farm_db_host: str
    db_host: str
    ansible_inventory: str
    backup_root_dir: str
    export_domains: str
    lab_storage_host: str
    lab_storage_port: int
    lab_storage_user: str
    lab_storage_ssh_key: str
    lab_storage_ssh_common_args: str
    lab_storage_user_share_root: str
    lab_storage_sudo: str
    lab_host_user_share_root_template: str
    lab_kerberos_realm: str
    lab_kerberos_ad_netbios: str
    lab_kerberos_nis_domain: str
    lab_kerberos_ad_dc_host: str
    lab_kerberos_storage_user_share_root: str
    lab_kerberos_mount_user_share_root_template: str
    lab_kerberos_ccache_base: str
    lab_kerberos_krb5_conf: str
    lab_kerberos_keytab_dir: str
    lab_kerberos_refresh_env_dir: str
    lab_kerberos_refresh_interval: str
    farm_nas_host: str
    farm_nas_port: int
    farm_nas_user: str
    farm_nas_ssh_key: str
    farm_nas_user_share_root: str
    farm_nas_sudo: str
    farm_kerberos_ad_netbios: str
    farm_kerberos_realm: str
    farm_kerberos_nis_domain: str
    farm_kerberos_ad_dc_host: str
    farm_kerberos_ad_dc_hosts: tuple[str, ...]
    farm_kerberos_nas_user_share_root: str
    farm_kerberos_nas_restart_gss_services: bool
    farm_kerberos_nas_svcgssd: str
    farm_kerberos_nas_idmapd: str
    farm_kerberos_nas_nfs_principal: str
    farm_kerberos_mount_user_share_root: str
    farm_kerberos_ccache_base: str
    farm_kerberos_krb5_conf: str
    farm_kerberos_keytab_dir: str
    farm_kerberos_refresh_env_dir: str
    farm_kerberos_refresh_interval: str
    farm_kerberos_nas_identity_retries: int
    farm_kerberos_nas_identity_retry_delay: int
    farm_kerberos_nfs_access_initial_delay: int
    farm_kerberos_nfs_access_retries: int
    farm_kerberos_nfs_access_retry_delay: int
    kerberos_remote_sudo: str

    @classmethod
    def from_file(cls, path: Path = DEFAULT_CONFIG_PATH) -> "AppConfig":
        if not path.exists():
            raise ValidationError(f"config file not found: {path}")
        return cls.from_mapping(load_env_file(path))

    @classmethod
    def from_mapping(cls, values: Dict[str, str]) -> "AppConfig":
        ad_dc_hosts = split_csv(_get(values, "FARM_KERBEROS_AD_DC_HOSTS", _get(values, "FARM_KERBEROS_AD_DC_HOST", "farm2")))
        if not ad_dc_hosts:
            ad_dc_hosts = ["farm2"]
        lab_storage_user_share_root = _get(values, "LAB_STORAGE_USER_SHARE_ROOT", "/294t/dcloud/share/user-share")
        lab_host_user_share_root_template = _get(values, "LAB_HOST_USER_SHARE_ROOT_TEMPLATE", "/home/tako{server_number}/share/user-share")
        lab_kerberos_storage_user_share_root = _get(values, "LAB_KERBEROS_STORAGE_USER_SHARE_ROOT", lab_storage_user_share_root)
        lab_kerberos_mount_user_share_root_template = _get(
            values,
            "LAB_KERBEROS_MOUNT_USER_SHARE_ROOT_TEMPLATE",
            _get(values, "LAB_KERBEROS_MOUNT_USER_SHARE_ROOT", lab_host_user_share_root_template),
        )
        return cls(
            db_port=_get_int(values, "DB_PORT", 3307),
            db_name=_get(values, "DB_NAME", "nfs_db"),
            db_user=_get(values, "DB_USER", ""),
            db_password=_get(values, "DB_PASSWORD", ""),
            db_charset=_get(values, "DB_CHARSET", "utf8mb4"),
            lab_db_host=_get(values, "LAB_DB_HOST", _get(values, "DB_HOST", "")),
            farm_db_host=_get(values, "FARM_DB_HOST", _get(values, "DB_HOST", "")),
            db_host=_get(values, "DB_HOST", ""),
            ansible_inventory=_get(values, "ANSIBLE_INVENTORY", ""),
            backup_root_dir=_get(values, "BACKUP_ROOT_DIR", str(PROJECT_ROOT / "mysql_backups")),
            export_domains=_get(values, "EXPORT_DOMAINS", _get(values, "SERVER_DOMAIN", "LAB,FARM")),
            lab_storage_host=_get(values, "LAB_STORAGE_HOST", "192.168.1.20"),
            lab_storage_port=_get_int(values, "LAB_STORAGE_PORT", 6953),
            lab_storage_user=_get(values, "LAB_STORAGE_USER", "jy"),
            lab_storage_ssh_key=_get(values, "LAB_STORAGE_SSH_KEY", ""),
            lab_storage_ssh_common_args=_get(values, "LAB_STORAGE_SSH_COMMON_ARGS", ""),
            lab_storage_user_share_root=lab_storage_user_share_root,
            lab_storage_sudo=_get(values, "LAB_STORAGE_SUDO", "sudo -n"),
            lab_host_user_share_root_template=lab_host_user_share_root_template,
            lab_kerberos_realm=_get(values, "LAB_KERBEROS_REALM", "LAB.DECS.INTERNAL"),
            lab_kerberos_ad_netbios=_get(values, "LAB_KERBEROS_AD_NETBIOS", "LAB"),
            lab_kerberos_nis_domain=_get(values, "LAB_KERBEROS_NIS_DOMAIN", "lab"),
            lab_kerberos_ad_dc_host=_get(values, "LAB_KERBEROS_AD_DC_HOST", "lab2"),
            lab_kerberos_storage_user_share_root=lab_kerberos_storage_user_share_root,
            lab_kerberos_mount_user_share_root_template=lab_kerberos_mount_user_share_root_template,
            lab_kerberos_ccache_base=_get(values, "LAB_KERBEROS_CCACHE_BASE", "/run/user"),
            lab_kerberos_krb5_conf=_get(values, "LAB_KERBEROS_KRB5_CONF", "/etc/krb5.conf"),
            lab_kerberos_keytab_dir=_get(values, "LAB_KERBEROS_KEYTAB_DIR", "/etc/decs-krb/keytabs"),
            lab_kerberos_refresh_env_dir=_get(values, "LAB_KERBEROS_REFRESH_ENV_DIR", "/etc/decs-krb/refresh.d"),
            lab_kerberos_refresh_interval=_get(values, "LAB_KERBEROS_REFRESH_INTERVAL", _get(values, "FARM_KERBEROS_REFRESH_INTERVAL", "1h")),
            farm_nas_host=_get(values, "FARM_NAS_HOST", "192.168.2.30"),
            farm_nas_port=_get_int(values, "FARM_NAS_PORT", 6954),
            farm_nas_user=_get(values, "FARM_NAS_USER", "jy"),
            farm_nas_ssh_key=_get(values, "FARM_NAS_SSH_KEY", ""),
            farm_nas_user_share_root=_get(values, "FARM_NAS_USER_SHARE_ROOT", "/volume1/share/user-share"),
            farm_nas_sudo=_get(values, "FARM_NAS_SUDO", "sudo -n"),
            farm_kerberos_ad_netbios=_get(values, "FARM_KERBEROS_AD_NETBIOS", "FARM"),
            farm_kerberos_realm=_get(values, "FARM_KERBEROS_REALM", "FARM.DECS.INTERNAL"),
            farm_kerberos_nis_domain=_get(values, "FARM_KERBEROS_NIS_DOMAIN", "farm"),
            farm_kerberos_ad_dc_host=ad_dc_hosts[0],
            farm_kerberos_ad_dc_hosts=tuple(ad_dc_hosts),
            farm_kerberos_nas_user_share_root=_get(values, "FARM_KERBEROS_NAS_USER_SHARE_ROOT", "/volume1/share/user-share"),
            farm_kerberos_nas_restart_gss_services=parse_bool(_get(values, "FARM_KERBEROS_NAS_RESTART_GSS_SERVICES", "true")),
            farm_kerberos_nas_svcgssd=_get(values, "FARM_KERBEROS_NAS_SVCGSSD", "/usr/sbin/svcgssd"),
            farm_kerberos_nas_idmapd=_get(values, "FARM_KERBEROS_NAS_IDMAPD", "/usr/sbin/idmapd"),
            farm_kerberos_nas_nfs_principal=_get(values, "FARM_KERBEROS_NAS_NFS_PRINCIPAL", "nfs/nas.farm.decs.internal@FARM.DECS.INTERNAL"),
            farm_kerberos_mount_user_share_root=_get(values, "FARM_KERBEROS_MOUNT_USER_SHARE_ROOT", "/home/tako{server_number}/share/user-share"),
            farm_kerberos_ccache_base=_get(values, "FARM_KERBEROS_CCACHE_BASE", "/run/user"),
            farm_kerberos_krb5_conf=_get(values, "FARM_KERBEROS_KRB5_CONF", "/etc/krb5.conf"),
            farm_kerberos_keytab_dir=_get(values, "FARM_KERBEROS_KEYTAB_DIR", "/etc/decs-krb/keytabs"),
            farm_kerberos_refresh_env_dir=_get(values, "FARM_KERBEROS_REFRESH_ENV_DIR", "/etc/decs-krb/refresh.d"),
            farm_kerberos_refresh_interval=_get(values, "FARM_KERBEROS_REFRESH_INTERVAL", "1h"),
            farm_kerberos_nas_identity_retries=_get_int(values, "FARM_KERBEROS_NAS_IDENTITY_RETRIES", 12),
            farm_kerberos_nas_identity_retry_delay=_get_int(values, "FARM_KERBEROS_NAS_IDENTITY_RETRY_DELAY", 5),
            farm_kerberos_nfs_access_initial_delay=_get_int(values, "FARM_KERBEROS_NFS_ACCESS_INITIAL_DELAY", 30),
            farm_kerberos_nfs_access_retries=_get_int(values, "FARM_KERBEROS_NFS_ACCESS_RETRIES", 12),
            farm_kerberos_nfs_access_retry_delay=_get_int(values, "FARM_KERBEROS_NFS_ACCESS_RETRY_DELAY", 5),
            kerberos_remote_sudo=_get(values, "KERBEROS_REMOTE_SUDO", "sudo -n"),
        )

    def db_host_for_domain(self, domain: str) -> str:
        normalized = normalize_domain(domain)
        host = self.lab_db_host if normalized == "LAB" else self.farm_db_host
        if not host:
            raise ValidationError(f"{normalized}_DB_HOST or DB_HOST must be configured")
        return host

    def is_farm_kerberos_ad_dc_host(self, host: str) -> bool:
        return host in self.farm_kerberos_ad_dc_hosts

    def farm_kerberos_ad_dc_hosts_csv(self) -> str:
        return ",".join(self.farm_kerberos_ad_dc_hosts)

    def farm_kerberos_domain_fqdn(self) -> str:
        return self.farm_kerberos_realm.lower()

    def farm_kerberos_domain_dn(self) -> str:
        return ",".join(f"DC={part}" for part in self.farm_kerberos_domain_fqdn().split("."))

    def farm_kerberos_ad_dc_fqdn(self, host: str) -> str:
        domain = self.farm_kerberos_domain_fqdn()
        if host == self.farm_kerberos_ad_dc_host and host == "farm2":
            return f"dc1.{domain}"
        if "." in host:
            return host
        return f"{host}.{domain}"

    def lab_kerberos_domain_fqdn(self) -> str:
        return self.lab_kerberos_realm.lower()

    def lab_kerberos_domain_dn(self) -> str:
        return ",".join(f"DC={part}" for part in self.lab_kerberos_domain_fqdn().split("."))

    def lab_kerberos_ad_dc_fqdn(self, host: str) -> str:
        domain = self.lab_kerberos_domain_fqdn()
        if host == self.lab_kerberos_ad_dc_host and host == "lab2":
            return f"dc1.{domain}"
        if "." in host:
            return host
        return f"{host}.{domain}"

    def lab_host_user_share_root(self, server_number: int) -> str:
        return self.lab_host_user_share_root_template.replace("{server_number}", str(validate_server_number(server_number))).rstrip("/")

    def lab_kerberos_mount_user_share_root(self, server_number: int) -> str:
        return self.lab_kerberos_mount_user_share_root_template.replace("{server_number}", str(validate_server_number(server_number))).rstrip("/")

    def farm_kerberos_mount_user_share_root_for_server(self, server_number: int) -> str:
        return self.farm_kerberos_mount_user_share_root.replace("{server_number}", str(validate_server_number(server_number))).rstrip("/")

    def domains(self, raw: Optional[str] = None) -> Iterable[str]:
        value = raw or self.export_domains
        for item in value.split(","):
            item = item.strip()
            if item:
                yield normalize_domain(item)


def parse_bool(raw: str) -> bool:
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def split_csv(raw: str) -> list[str]:
    return [item.strip() for item in raw.replace(" ", ",").split(",") if item.strip()]


def normalize_domain(domain: str) -> str:
    normalized = domain.strip().upper()
    if normalized not in {"LAB", "FARM"}:
        raise ValidationError("domain name must be LAB or FARM")
    return normalized


def split_server_id(server_id: str) -> tuple[str, int]:
    letters = "".join(ch for ch in server_id if ch.isalpha())
    digits = "".join(ch for ch in server_id if ch.isdigit())
    if not letters or not digits or server_id.upper() != f"{letters}{digits}".upper():
        raise ValidationError("server id must be in format LAB1 or FARM2")
    return normalize_domain(letters), int(digits)


def compose_server_id(domain: str, server_number: int) -> str:
    return f"{normalize_domain(domain)}{validate_server_number(server_number)}"


def compose_ansible_host_alias(domain: str, server_number: int) -> str:
    return f"{normalize_domain(domain).lower()}{validate_server_number(server_number)}"


def validate_server_number(server_number: int | str) -> int:
    try:
        number = int(server_number)
    except (TypeError, ValueError) as exc:
        raise ValidationError("server number must be numeric") from exc
    if number <= 0:
        raise ValidationError("server number must be positive")
    return number
