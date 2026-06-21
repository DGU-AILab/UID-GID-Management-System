# Kerberized NFS PoC

이 문서는 FARM2에서 기존 `/home/tako2/share` mount를 건드리지 않고, 병렬 mount point로 Kerberized NFS를 검증하는 절차다.

## 목표 구조

```text
기존 운영 mount:
100.100.100.120:/volume1/share -> /home/tako2/share       sec=sys

PoC mount:
nas.farm.decs.internal:/volume1/test_krb
                              -> /mnt/nas-krb-test-v4   vers=4.1,sec=krb5p
```

PoC는 Synology NAS의 테스트 공유 폴더인 `/volume1/test_krb`만 사용한다. 기존 컨테이너와 기존 `/volume1/share` mount는 그대로 둔다.

## 보관 방식

PoC 설정은 운영 서버에 수동으로만 남기지 않고 repo에 보관한다.

- `ansible/samba_ad_dc_poc.yml`: farm2 Samba AD DC, NAS/FARM2 principal, farm2 machine keytab 준비
- `ansible/kerberized_nfs_poc.yml`: farm2 preflight, krb5.conf 생성, 병렬 mount 생성, 선택형 write test
- 이 README: NAS/KDC 준비값, 실행 순서, rollback

운영 적용 전에는 `kerb_nfs_apply=false` 기본값으로 preflight만 실행한다.

## 필요한 값

Kerberized NFS는 IP mount보다 FQDN mount가 안전하다. NFS service principal이 FQDN 기준으로 발급되기 때문이다.

필수 값:

```text
kerb_nfs_server_fqdn=<nas-fqdn>
kerb_nfs_export=/volume1/test_krb
kerb_nfs_mount_point=/mnt/nas-krb-test-v4
kerb_realm=<REALM>
kerb_kdc=<kdc-fqdn>
kerb_domain=<dns-domain>
```

NAS/KDC 준비:

```text
1. KDC, AD, 또는 FreeIPA realm 준비
2. NAS가 realm에 join되어 있어야 함
3. NAS NFS 서버에 nfs/<nas-fqdn>@<REALM> principal/keytab이 있어야 함
4. NAS export가 sec=krb5, sec=krb5i, 또는 sec=krb5p를 허용해야 함
5. farm2가 <nas-fqdn>과 <kdc-fqdn>을 DNS로 해석할 수 있어야 함
```

farm2 준비:

```text
1. krb5-user, nfs-common 설치
2. /etc/krb5.conf 설정
3. rpc.gssd 동작
4. rpc.gssd가 사용할 machine principal/keytab 준비. 현재 PoC는 `FARM2$@FARM.DECS.INTERNAL` 사용
```

## 현재 PoC 값

```text
Realm: FARM.DECS.INTERNAL
DNS domain: farm.decs.internal
AD DC: dc1.farm.decs.internal / 100.100.100.102
NAS FQDN: nas.farm.decs.internal / 100.100.100.120
NAS test share: /volume1/test_krb
farm2 machine principal: FARM2$@FARM.DECS.INTERNAL
farm2 keytab: /etc/krb5.keytab
```

## Preflight

아래 명령은 설정을 변경하지 않는다.

```bash
ansible-playbook \
  -i /home/jy/ansible/inventory.ini \
  ansible/kerberized_nfs_poc.yml \
  -e target_hosts=farm2 \
  -e kerb_nfs_server_fqdn=nas.farm.decs.internal \
  -e kerb_realm=FARM.DECS.INTERNAL \
  -e kerb_kdc=100.100.100.102 \
  -e kerb_domain=farm.decs.internal
```

현재 확인된 FARM2 상태:

```text
/home/tako2/share = 100.100.100.120:/volume1/share, nfs4, sec=sys
mount.nfs 있음
rpc.gssd 동작
kinit 있음
/etc/krb5.conf = FARM.DECS.INTERNAL
/etc/krb5.keytab = FARM2$@FARM.DECS.INTERNAL
```

## Apply

preflight가 통과하고 NAS/KDC 준비가 끝난 뒤에만 실행한다.

```bash
ansible-playbook \
  -i /home/jy/ansible/inventory.ini \
  ansible/kerberized_nfs_poc.yml \
  -e target_hosts=farm2 \
  -e kerb_nfs_apply=true \
  -e kerb_nfs_install_packages=false \
  -e kerb_nfs_server_fqdn=nas.farm.decs.internal \
  -e kerb_realm=FARM.DECS.INTERNAL \
  -e kerb_kdc=100.100.100.102 \
  -e kerb_domain=farm.decs.internal \
  -e kerb_nfs_write_test=true
```

성공 확인:

```bash
findmnt -T /mnt/nas-krb-test-v4 -o TARGET,SOURCE,FSTYPE,OPTIONS
```

`OPTIONS`에 `vers=4.1`과 `sec=krb5p`가 보여야 한다.

2026-06-21 확인 결과:

```text
NFSv3 sec=krb5p mount: 성공
NFSv4.1 sec=krb5p mount: 성공
root/machine credential read/write: 성공
컨테이너 내부 kinit + host /run/user/<uid>/krb5cc 공유 기반 read/write: 성공
host root-only keytab + systemd refresh 기반 ccache 자동 발급/read/write: 성공
신규 AD user 자동 생성 + keytab 발급: 성공
신규 AD user Kerberos NFS write: 실패. principal/keytab/RFC2307 attrs/NAS wbinfo mapping은 정상이나 Synology NFS server가 신규 identity에 write 권한을 주지 않음.
```

Synology는 Kerberos principal을 winbind AD-mapped UID/GID로 매핑한다. 따라서 Kerberos 모드의 NAS home owner는 컨테이너 UID/GID가 아니라 `wbinfo -i FARM\\<username>`으로 확인되는 NAS AD-mapped UID/GID여야 한다.

## Docker 테스트

병렬 mount가 성공하면 테스트 홈을 준비한 뒤 컨테이너를 띄운다.

```bash
sudo mkdir -p /mnt/nas-krb-test-v4/user-share/krbtest
sudo chown <nas-ad-uid>:<nas-ad-gid> /mnt/nas-krb-test-v4/user-share/krbtest
sudo chmod 750 /mnt/nas-krb-test-v4/user-share/krbtest
```

이후 테스트용 Docker run 또는 create script 변형에서 mount source를 아래로 바꾼다.

```text
/mnt/nas-krb-test-v4/user-share/
```

컨테이너 내부 사용자가 Kerberos ticket으로 접근하게 하려면 credential cache를 host `rpc.gssd`가 볼 수 있어야 한다. 현재 성공한 운영형 방식은 host `/run/user/<uid>`를 컨테이너에 같은 경로로 bind mount하고 `KRB5CCNAME=FILE:/run/user/<uid>/krb5cc`를 설정하는 방식이다.

사용자 비밀번호를 컨테이너에 넣지 않기 위해 keytab은 target host에만 root-only secret으로 둔다.

```text
/etc/decs-krb/keytabs/<username>.keytab      root:root 0400
/etc/decs-krb/refresh.d/<username>.env       root:root 0600
/usr/local/sbin/decs-krb-refresh
decs-krb-refresh@<username>.timer
/run/user/<uid>/krb5cc                       <uid>:<gid> 0600
```

`decs-krb-refresh`는 기존 ticket이 있으면 `kinit -R`을 먼저 시도하고, 실패하거나 ccache가 없으면 `kinit -kt`로 새 ticket을 발급한다. 컨테이너에는 keytab을 mount하지 않고 `/run/user/<uid>` ccache directory만 공유한다.

keytab rotation은 `create_container.sh --enable-kerberos true --rotate-kerberos-keytab true`로 수행한다. 이 작업은 AD user password를 재설정하고 새 keytab을 export한다. 이미 발급된 ticket은 보통 ticket lifetime까지 유효하므로 유출 대응 시에는 ticket lifetime/renewable lifetime도 같이 조정해야 한다.

신규 AD user는 `samba-tool user addunixattrs`로 `uidNumber`, `gidNumber`, `unixHomeDirectory`, `loginShell`을 추가한다. 다만 2026-06-21 테스트에서 Synology NAS는 신규 principal을 `wbinfo`/`id`로는 정상 인식하면서도 NFS Kerberos write는 거부했다. 기존에 NAS/NFS가 이미 인식하던 principal은 같은 keytab/ccache 구조로 write 성공한다. 따라서 create script는 실제 NFS write check를 통과해야만 컨테이너 생성과 DB 기록으로 넘어간다.

## Rollback

병렬 mount만 해제한다. 기존 `/home/tako2/share`는 건드리지 않는다.

```bash
sudo umount /mnt/nas-krb-test-v4
sudo rmdir /mnt/nas-krb-test-v4
```

`/etc/krb5.conf`를 playbook으로 썼다면 기존 파일 백업 정책을 정한 뒤 원복한다.

## 다음 단계

1. Synology NFS server가 신규 AD Kerberos identity를 즉시 반영하도록 idmap/gssd/NFS cache flush 또는 안전한 service reload 방법 확인
2. farm2 밖의 FARM host로 keytab을 안전하게 배포하는 방식 설계. 현재 PoC는 target host와 AD DC host가 같은 경우만 자동화한다.
3. DB에 Kerberos secret이 아니라 `kerberos_enabled`, `principal`, `rotated_at` 같은 메타데이터만 남기는 schema 검토
4. gssproxy 기반 운영 구조 검토
5. k8s CSI/PV/PVC 구조로 확장
