# Kerberos E2E Test Scenario

This document records the full manual/integration test flow for the Python
`uidctl` refactor. It mirrors the previous shell-script Kerberos test and adds
expiration extension, expired cleanup, email, and final deletion coverage.

The default unit tests are still safe local checks:

```bash
cd ~/uid/refactoring
python3 -B tests/run_tests.py
python3 -B -c "import ast,pathlib; [ast.parse(p.read_text(), filename=str(p)) for p in pathlib.Path('.').rglob('*.py')]; print('ok - syntax parse passed')"

cd ~/uid
bash tests/test_farm_nas_home.sh
bash tests/test_manage_group.sh
```

## Test Values

Use fresh names that do not already exist in DB, AD, or NAS home paths.

```bash
export E2E_USER_A=krbpyf260622
export E2E_USER_B=krbpyt260622
export E2E_USER_DUP=krbpyf260622
export E2E_GROUP=krbpyshare260622
export E2E_IMAGE=decs
export E2E_VERSION=krb-e2e-260621
export E2E_SERVER_ID=FARM2
export E2E_EMAIL=jade1087@dgu.ac.kr
```

## 0. Multi-DC Kerberos Precheck

When testing AD DC failover, prepare every target FARM host as a usable AD DC
and NFS Kerberos client before creating containers there.

```bash
cd ~/uid
ansible-playbook -i /etc/ansible/inventory.ini ansible/samba_ad_additional_dc.yml \
  -e target_host=farm6 \
  -e source_dc_host=farm2 \
  -e target_dc_service_ip=100.100.100.106

ansible-playbook -i /etc/ansible/inventory.ini ansible/samba_ad_additional_dc.yml \
  -e target_host=farm7 \
  -e source_dc_host=farm2 \
  -e target_dc_service_ip=100.100.100.107
```

Checklist:

- `_ldap`, `_kerberos`, `_kpasswd`, and `_gc` SRV records resolve from
  farm2, farm6, and farm7.
- `kinit` and `kvno nfs/nas.farm.decs.internal` succeed while using farm6 as
  KDC.
- NAS DNS resolution works when pointed at farm6.
- With farm2 `samba-ad-dc` temporarily stopped, farm6 can still obtain tickets
  and perform a Kerberos NFS write.
- The UID config lists all usable AD DC/container hosts:

```text
FARM_KERBEROS_AD_DC_HOSTS=farm2,farm6,farm7
FARM_KERBEROS_AD_DC_HOST=farm2
```

## 1. Create Kerberos Containers

Create user A with Kerberos, GUI, and the shared AD group.

```bash
cd ~/uid/refactoring
python3 -B -m uid_manager.cli create-container \
  --name "Krb Py F" \
  --username "$E2E_USER_A" \
  --group "$E2E_GROUP" \
  --server-id "$E2E_SERVER_ID" \
  --expiration-date 2026-12-31 \
  --image "$E2E_IMAGE" \
  --version "$E2E_VERSION" \
  --created-by jy \
  --email "$E2E_EMAIL" \
  --phone 010-0000-0000 \
  --enable-kerberos \
  --enable-vnc
```

Create user B with the same group.

```bash
python3 -B -m uid_manager.cli create-container \
  --name "Krb Py T" \
  --username "$E2E_USER_B" \
  --group "$E2E_GROUP" \
  --server-id "$E2E_SERVER_ID" \
  --expiration-date 2026-12-31 \
  --image "$E2E_IMAGE" \
  --version "$E2E_VERSION" \
  --created-by jy \
  --email "$E2E_EMAIL" \
  --phone 010-0000-0000 \
  --enable-kerberos \
  --enable-vnc
```

Expected:

- AD principal and keytab are created for each user.
- AD group exists and both users are members.
- NAS home exists under `/volume1/test_krb/user-share/<username>`.
- Host ccache exists under `/run/user/<uid>/krb5cc`.
- The create flow performs NFSv4.1 `sec=krb5p` write check before DB commit.
- Creation email is sent.

## 2. Service Checks

Resolve ports from DB:

```bash
mysql --defaults-extra-file=/tmp/uid-e2e.cnf -D nfs_db -e "
SELECT u.ubuntu_username, dc.container_name, up.port_number, up.purpose_of_use
FROM docker_container dc
JOIN user u ON u.id=dc.user_id
JOIN used_ports up ON up.docker_container_record_id=dc.id
WHERE u.ubuntu_username IN ('$E2E_USER_A', '$E2E_USER_B')
  AND dc.existing=1
ORDER BY u.ubuntu_username, up.port_number;
"
```

Check SSH, Jupyter, noVNC, Kerberos env, and home write:

```bash
sshpass -p '<initial-password>' ssh -o StrictHostKeyChecking=no -p <ssh-port> <user>@<farm-public-ip> 'id && echo ok > ~/e2e_home_write.txt && cat ~/e2e_home_write.txt && echo "$KRB5CCNAME"'
curl -fsS -o /dev/null -w '%{http_code}\n' "http://<farm-public-ip>:<jupyter-port>"
curl -fsS -o /dev/null -w '%{http_code}\n' "http://<farm-public-ip>:<vnc-port>"
```

## 3. UID Spoofing And Restricted Sudo

Inside user A container:

```bash
sudo -n setpriv --reuid=<B_UID> --regid=<B_GID> --clear-groups id
sudo -n su - "$E2E_USER_B" -c id
sudo -n chmod 777 "$HOME"
sudo -n bash -lc id
sudo -n python3 -c 'print("bad")'
sudo -n apt-get --version
```

Expected:

- `setpriv`, `su`, `chmod`, root shell, and arbitrary code execution fail.
- `apt-get --version` succeeds.

## 4. Same Username Re-Creation

Create another container for user A.

```bash
python3 -B -m uid_manager.cli create-container \
  --name "Krb Py F Again" \
  --username "$E2E_USER_DUP" \
  --group "$E2E_GROUP" \
  --server-id "$E2E_SERVER_ID" \
  --expiration-date 2027-01-31 \
  --image "$E2E_IMAGE" \
  --version "$E2E_VERSION" \
  --container-name "${E2E_USER_DUP}_again_by_jy" \
  --created-by jy \
  --email "$E2E_EMAIL" \
  --phone 010-0000-0000 \
  --enable-kerberos \
  --enable-vnc
```

Expected:

- Existing UID, existing group, existing NAS home are reused.
- Keytab/ccache refresh remains functional.
- SSH/Jupyter/noVNC work in the second container.
- If a host already has Docker containers outside the UID DB, `uidctl`
  excludes live Docker bind ports during allocation. Do not use
  `--container-ports` for host port selection; it means extra container ports
  to publish.

## 5. Kerberos Group Sharing

In user A container:

```bash
group-dir-share ~/sharing_dir "$E2E_GROUP"
echo from-a > ~/sharing_dir/from_a.txt
```

In user B container:

```bash
cat /home/"$E2E_USER_A"/sharing_dir/from_a.txt
echo from-b > /home/"$E2E_USER_A"/sharing_dir/from_b.txt
rm /home/"$E2E_USER_A"/sharing_dir/from_b.txt
```

Expected: user B can create, read, and delete files inside the shared directory.

## 6. Extend Container And Email

```bash
python3 -B -m uid_manager.cli extend-container \
  --username "$E2E_USER_A" \
  --expiration-date 2027-02-28 \
  --domains FARM \
  --apply \
  --all-matches
```

Expected:

- Matching active containers for user A are extended.
- Extension email is sent.
- DB backup/export hooks run.

## 7. Expired Cleanup And Email

First dry-run with a future `today`:

```bash
python3 -B -m uid_manager.cli expired-cleanup \
  --today 2028-01-01 \
  --domains FARM \
  --username "$E2E_USER_B" \
  --dry-run
```

Apply only when the listed containers are the intended test containers:

```bash
python3 -B -m uid_manager.cli expired-cleanup \
  --today 2028-01-01 \
  --domains FARM \
  --username "$E2E_USER_B" \
  --apply
```

Expected:

- Expired test containers are removed remotely and marked deleted in DB.
- Deletion email is sent.
- DB backup/export hooks run.

## 8. Final Delete Container

For any remaining test containers:

```bash
python3 -B -m uid_manager.cli delete-container \
  --server-id "$E2E_SERVER_ID" \
  --username "$E2E_USER_A"

python3 -B -m uid_manager.cli delete-container \
  --server-id "$E2E_SERVER_ID" \
  --username "$E2E_USER_B"
```

Expected:

- Used ports are deleted.
- Container DB rows are marked `existing=0`.
- Remote Docker containers are removed.
- Deletion email is sent.

## Results

### 2026-06-22 Single-DC Shell/Python Run

Run completed.

- Date: 2026-06-22
- Branch: `nas-krb260621`
- Image: `dguailab/decs:krb-e2e-260621`
- Users: `krbpyf260622`, `krbpyt260622`
- Group: `krbpyshare260622`
- Create:
  - `krbpyf260622_by_jy` created on FARM2.
  - `krbpyt260622_by_jy` created on FARM2.
  - AD principals/keytabs created.
  - NAS homes created under `/volume1/test_krb/user-share`.
  - Host ccaches created:
    - `/run/user/10132/krb5cc`
    - `/run/user/10134/krb5cc`
  - Docker runtime group used NAS AD-mapped group GID `96470126`.
- Service checks:
  - FARM2 localhost Jupyter:
    - `9141` -> `302`, `curl -L` -> `200`
    - `9144` -> `302`, `curl -L` -> `200`
  - FARM2 localhost noVNC:
    - `9142` -> `200`
    - `9145` -> `200`
  - SSH password login from FARM2 localhost succeeded for both users.
  - User home write through SSH succeeded.
  - Public `210.94.179.19:<port>` HTTP/SSH timed out from this management environment, while FARM2 localhost checks passed. Treat this as public routing/firewall path separate from container service health.
  - `docker exec` environment contains `KRB5CCNAME=FILE:/run/user/<uid>/krb5cc`.
  - SSH login shell did not show `KRB5CCNAME`; if users need `klist` in SSH sessions, add profile/session environment propagation. NFS access still works because host `rpc.gssd` uses the UID ccache path.
- UID spoofing:
  - A user writing B home failed with permission denied.
  - `sudo setpriv --reuid=<B_UID>` failed.
  - `sudo su` failed.
  - `sudo chmod` failed.
  - `sudo bash -lc` failed.
  - `sudo python3 -c` failed.
  - `sudo apt-get --version` succeeded.
- Same username:
  - `krbpyf260622_again_by_jy` created with existing UID `10132`.
  - Existing group and NAS home were reused.
  - Jupyter/noVNC/SSH checks passed on FARM2 localhost.
- Group sharing:
  - `group-dir-share ~/sharing_dir krbpyshare260622` succeeded.
  - User B read user A's file.
  - User B created/read/deleted a file inside user A's shared directory.
- Extend/email:
  - `krbpyf260622` two active containers extended to `2027-02-28`.
  - `krbpyt260622` extended to `2027-02-28`.
  - Extension email log confirmed: `extension_notification_sent`.
  - DB backup created under `/home/jy/mysql_backups/farm`.
  - Excel and Google Sheets export completed.
- Expired cleanup/email:
  - Added safe filters `--username` and `--container-name` to the Python refactor so E2E cleanup does not delete unrelated expired FARM containers.
  - Dry-run with `--username krbpyt260622` matched exactly one container.
  - Apply deleted `krbpyt260622_by_jy`.
  - Deletion email log confirmed.
  - DB backup/export completed.
- Final delete:
  - `delete-container --container-name krbpyf260622_again_by_jy` succeeded.
  - `delete-container --container-name krbpyf260622_by_jy` succeeded.
  - Deletion email logs confirmed for both.
  - DB backup/export completed for both.
  - FARM2 Docker has no remaining `krbpy*` containers.
  - DB records for all three E2E containers are `existing=0` with `deleted_at` set.
- Code changes made during the run:
  - Redacted generated user/VNC passwords from `create-container` plan output.
  - Printed post-action logs so email/backup/export success is visible.
  - Passed `AppConfig` into post actions so DB backup is actually created.
  - Added filtered expired cleanup options for safe E2E and operational use.

### 2026-06-22 Multi-DC Python Run

Run completed against farm2, farm6, and farm7.

- Branch: `nas-krb260621`
- Image: `dguailab/decs:krb-e2e-260621`
- AD DC hosts:
  - farm2: `100.100.100.102`
  - farm6: `100.100.100.106`
  - farm7: `100.100.100.107`
- Multi-DC checks:
  - farm6 and farm7 joined as additional Samba AD DCs.
  - DNS SRV records for `_ldap`, `_kerberos`, and `_gc` resolved on all three
    DCs after manual SRV completion and DRS pulls.
  - farm2 `samba-ad-dc` was temporarily stopped; farm6 still issued tickets and
    Kerberos NFS write succeeded.
  - NAS DNS resolution through farm6 worked during the farm2 AD outage.
  - `synowin -updateDomain` still returned `test join fail`; treat this as a
    remaining Synology domain-health caveat, not proof of full NAS DC failover.
- NFS mount note:
  - farm2 used NFSv4.1 `sec=krb5p`.
  - farm6 and farm7 timed out with NFSv4.1 against the Synology test export, but
    NFSv4.0 `sec=krb5p` mounted and passed write tests.
- Containers created:
  - farm2: `krbdc2a260622_by_codex`, ports `9140/9141/9142`.
  - farm6: `krbdc6a260622_by_codex`, ports `9502/9503/9504`.
  - farm7: `krbdc7a260622_by_codex`, ports `9600/9601/9602`.
- Service checks:
  - SSH password login succeeded on farm2, farm6, and farm7.
  - Jupyter returned `302` and noVNC returned `200` on all three hosts.
  - `KRB5CCNAME=FILE:/run/user/<uid>/krb5cc` was present in the Kerberos
    containers.
  - User home write succeeded through the Kerberos NFS mount.
- Restricted sudo and spoofing:
  - Cross-home write from user A to user B failed.
  - `sudo setpriv`, `sudo su`, `sudo chmod`, `sudo bash`, and
    `sudo python3 -c` failed.
  - `sudo apt-get --version` succeeded.
- Group sharing:
  - `group-dir-share ~/sharing_dir krbdcshare260622` succeeded.
  - farm6 and farm7 containers could create/read/delete files inside the farm2
    user's shared directory.
- Same username re-creation:
  - `krbdc6a260622_again_by_codex` reused UID `10137`, existing NAS home, and
    existing Kerberos ccache/keytab.
  - The first attempt exposed a live Docker port conflict with an existing
    non-DB container on farm6. `uidctl` now excludes live Docker host ports.
  - Duplicate SSH, Jupyter, noVNC, and user home write checks succeeded.
- Extend/email/cleanup/delete:
  - `extend-container --port 9505 --apply` updated the duplicate from
    `2026-07-31` to `2026-08-31`.
  - Extend and delete email scripts were verified with `--dry-run`; apply runs
    used localhost SMTP to avoid external delivery.
  - `expired-cleanup --container-name krbdc6a260622_again_by_codex --apply`
    removed the duplicate container and marked its DB row deleted.
  - `delete-container --container-name krbdc7a260622_by_codex` removed the
    farm7 test container and marked its DB row deleted.
- Remaining after this run:
  - `krbdc2a260622_by_codex` on farm2 and `krbdc6a260622_by_codex` on farm6
    were intentionally left running for follow-up inspection.
