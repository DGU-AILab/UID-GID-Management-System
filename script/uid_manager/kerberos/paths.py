from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

from ..config import AppConfig


def _join(root: str, leaf: str) -> str:
    return f"{root.rstrip('/')}/{leaf}"


@dataclass(frozen=True)
class KerberosPaths:
    username: str
    uid: int
    config: AppConfig
    host_mount_root: str | None = None
    home_username: str | None = None
    realm: Optional[str] = None
    storage_home_root: Optional[str] = None
    ccache_base: Optional[str] = None
    krb5_conf: Optional[str] = None
    keytab_dir: Optional[str] = None
    storage_keytab_dir: Optional[str] = None
    refresh_env_dir: Optional[str] = None
    refresh_interval: Optional[str] = None

    @property
    def home_leaf(self) -> str:
        return self.home_username or self.username

    @property
    def realm_name(self) -> str:
        return self.realm or self.config.farm_kerberos_realm

    @property
    def principal(self) -> str:
        return f"{self.username}@{self.realm_name}"

    @property
    def storage_home(self) -> str:
        root = self.storage_home_root or self.config.farm_kerberos_nas_user_share_root
        return _join(root, self.home_leaf)

    @property
    def nas_home(self) -> str:
        return self.storage_home

    @property
    def mount_root(self) -> str:
        if self.host_mount_root:
            return self.host_mount_root.rstrip("/")
        return self.config.farm_kerberos_mount_user_share_root.rstrip("/")

    @property
    def host_home(self) -> str:
        return _join(self.mount_root, self.home_leaf)

    @property
    def ccache_dir(self) -> str:
        return _join(self.ccache_base or self.config.farm_kerberos_ccache_base, str(self.uid))

    @property
    def ccache_file(self) -> str:
        return _join(self.ccache_dir, "krb5cc")

    @property
    def keytab_file(self) -> str:
        return _join(self.keytab_dir or self.config.farm_kerberos_keytab_dir, f"{self.username}.keytab")

    @property
    def storage_keytab_file(self) -> str:
        root = self.storage_keytab_dir or self.keytab_dir or self.config.farm_kerberos_keytab_dir
        return _join(root, f"{self.username}.keytab")

    @property
    def refresh_env_file(self) -> str:
        return _join(self.refresh_env_dir or self.config.farm_kerberos_refresh_env_dir, f"{self.username}.env")

    @property
    def refresh_env_root(self) -> str:
        return self.refresh_env_dir or self.config.farm_kerberos_refresh_env_dir

    @property
    def refresh_interval_value(self) -> str:
        return self.refresh_interval or self.config.farm_kerberos_refresh_interval

    @property
    def krb5_conf_file(self) -> str:
        return self.krb5_conf or self.config.farm_kerberos_krb5_conf
