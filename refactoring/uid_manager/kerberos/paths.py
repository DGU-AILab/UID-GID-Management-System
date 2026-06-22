from __future__ import annotations

from dataclasses import dataclass

from ..config import AppConfig


def _join(root: str, leaf: str) -> str:
    return f"{root.rstrip('/')}/{leaf}"


@dataclass(frozen=True)
class KerberosPaths:
    username: str
    uid: int
    config: AppConfig

    @property
    def principal(self) -> str:
        return f"{self.username}@{self.config.farm_kerberos_realm}"

    @property
    def nas_home(self) -> str:
        return _join(self.config.farm_kerberos_nas_user_share_root, self.username)

    @property
    def mount_root(self) -> str:
        return self.config.farm_kerberos_mount_user_share_root.rstrip("/")

    @property
    def host_home(self) -> str:
        return _join(self.mount_root, self.username)

    @property
    def ccache_dir(self) -> str:
        return _join(self.config.farm_kerberos_ccache_base, str(self.uid))

    @property
    def ccache_file(self) -> str:
        return _join(self.ccache_dir, "krb5cc")

    @property
    def keytab_file(self) -> str:
        return _join(self.config.farm_kerberos_keytab_dir, f"{self.username}.keytab")

    @property
    def refresh_env_file(self) -> str:
        return _join(self.config.farm_kerberos_refresh_env_dir, f"{self.username}.env")
