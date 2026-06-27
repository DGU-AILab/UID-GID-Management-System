# DECS Samba AD Backup

This directory contains the FARM Samba AD DC backup workflow. It is separate
from container creation and monitoring.

## What This Backs Up

- `/var/lib/samba/private`
- `/var/lib/samba/sysvol`
- `/etc/samba/smb.conf`
- `/etc/krb5.conf`
- `/etc/decs-krb/keytabs` when `AD_BACKUP_INCLUDE_KEYTABS=true`

Each DC is backed up independently. The expected FARM DCs are `farm2`,
`farm6`, and `farm7`.

## Usage

```bash
cd ~/uid/ad_backup
cp config.example.env config.local.env
./backup_ad.sh
./verify_backup.sh
```

Install a daily timer on the management host:

```bash
./install_timer.sh
systemctl status decs-ad-backup.timer
```

## Restore Notes

These backups are intended for disaster recovery and identity verification.
They do not replace a tested restore runbook. A real restore should preserve
the Samba AD domain SID, user objectSid values, krbtgt/machine secrets, and
SYSVOL data. If all DCs are lost and a new AD domain is provisioned without
these backups, identical usernames will not be the same identities.

DB Kerberos metadata such as `ad_object_sid` is a verification record. The AD
backup is what keeps those identities recoverable.
