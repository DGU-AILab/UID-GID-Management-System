# Kerberized NFS PoC

이 문서는 FARM2에서 기존 `/home/tako2/share` mount를 건드리지 않고, 병렬 mount point로 Kerberized NFS를 검증하는 절차다.

## 목표 구조

```text
기존 운영 mount:
100.100.100.120:/volume1/share -> /home/tako2/share       sec=sys

PoC mount:
nas.farm.decs.internal:/volume1/test_krb
                              -> /mnt/nas-krb-test-v3   vers=3,sec=krb5p
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
kerb_nfs_mount_point=/mnt/nas-krb-test-v3
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
findmnt -T /mnt/nas-krb-test-v3 -o TARGET,SOURCE,FSTYPE,OPTIONS
```

`OPTIONS`에 `vers=3`과 `sec=krb5p`가 보여야 한다.

2026-06-20 확인 결과:

```text
NFSv3 sec=krb5p mount: 성공
root/machine credential read/write: 성공
일반 사용자 기본 ccache ticket 기반 read/write: 성공
NFSv4.1 sec=krb5p mount: access denied
```

NFSv4.1 실패는 Kerberos ticket 발급 실패가 아니라 Synology NFSv4 pseudo-root/export 처리 문제로 보인다. farm2에서 `FARM2$` machine ticket과 `nfs/nas.farm.decs.internal` service ticket 발급은 성공했다.

## Docker 테스트

병렬 mount가 성공하면 테스트 홈을 준비한 뒤 컨테이너를 띄운다.

```bash
sudo mkdir -p /mnt/nas-krb-test-v3/user-share/krbtest
sudo chown 13100:13100 /mnt/nas-krb-test-v3/user-share/krbtest
sudo chmod 750 /mnt/nas-krb-test-v3/user-share/krbtest
```

이후 테스트용 Docker run 또는 create script 변형에서 mount source를 아래로 바꾼다.

```text
/mnt/nas-krb-test-v3/user-share/
```

컨테이너 내부 사용자가 직접 Kerberos ticket으로 접근하게 하려면 컨테이너가 생성한 credential cache를 host `rpc.gssd`가 볼 수 있어야 한다. 단순 bind mount만으로는 host의 NFS client가 접근을 수행하므로, ticket cache 경로 공유 또는 gssproxy 기반 설계가 추가로 필요하다.

## Rollback

병렬 mount만 해제한다. 기존 `/home/tako2/share`는 건드리지 않는다.

```bash
sudo umount /mnt/nas-krb-test-v3
sudo rmdir /mnt/nas-krb-test-v3
```

`/etc/krb5.conf`를 playbook으로 썼다면 기존 파일 백업 정책을 정한 뒤 원복한다.

## 다음 단계

1. Docker bind mount로 DECS 컨테이너 smoke
2. 컨테이너 내부 `kinit`/ticket lifecycle 검토
3. host `rpc.gssd`/`gssproxy`가 컨테이너 사용자 credential을 사용할 수 있는지 검증
4. Synology에서 NFSv4 `sec=krb5p` pseudo-root 구성 가능 여부 추가 확인
5. k8s CSI/PV/PVC 구조로 확장
