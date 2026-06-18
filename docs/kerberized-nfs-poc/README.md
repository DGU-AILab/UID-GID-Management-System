# Kerberized NFS PoC

이 문서는 FARM2에서 기존 `/home/tako2/share` mount를 건드리지 않고, 병렬 mount point로 Kerberized NFS를 검증하는 절차다.

## 목표 구조

```text
기존 운영 mount:
100.100.100.120:/volume1/share -> /home/tako2/share       sec=sys

PoC mount:
<nas-fqdn>:/volume1/share       -> /mnt/nas-krb-share     sec=krb5p
```

PoC 컨테이너만 `/mnt/nas-krb-share/user-share/<username>`을 `/home/<username>`으로 bind mount한다. 기존 컨테이너와 기존 mount는 그대로 둔다.

## 보관 방식

PoC 설정은 운영 서버에 수동으로만 남기지 않고 repo에 보관한다.

- `ansible/kerberized_nfs_poc.yml`: farm2 preflight, krb5.conf 생성, 병렬 mount 생성
- 이 README: NAS/KDC 준비값, 실행 순서, rollback

운영 적용 전에는 `kerb_nfs_apply=false` 기본값으로 preflight만 실행한다.

## 필요한 값

Kerberized NFS는 IP mount보다 FQDN mount가 안전하다. NFS service principal이 FQDN 기준으로 발급되기 때문이다.

필수 값:

```text
kerb_nfs_server_fqdn=<nas-fqdn>
kerb_nfs_export=/volume1/share
kerb_nfs_mount_point=/mnt/nas-krb-share
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
4. host/farm2.<domain>@<REALM> 또는 NFS client에서 사용할 Kerberos credential 준비
```

## Preflight

아래 명령은 설정을 변경하지 않는다.

```bash
ansible-playbook \
  -i /home/jy/ansible/inventory.ini \
  ansible/kerberized_nfs_poc.yml \
  -e target_hosts=farm2 \
  -e kerb_nfs_server_fqdn=<nas-fqdn> \
  -e kerb_realm=<REALM> \
  -e kerb_kdc=<kdc-fqdn> \
  -e kerb_domain=<dns-domain>
```

현재 확인된 FARM2 상태:

```text
/home/tako2/share = 100.100.100.120:/volume1/share, nfs4, sec=sys
mount.nfs 있음
rpc.gssd 있음, inactive
kinit 없음
/etc/krb5.conf 없음 또는 비어 있음
```

따라서 실제 mount 전에는 Kerberos client package와 realm 설정이 필요하다.

## Apply

preflight가 통과하고 NAS/KDC 준비가 끝난 뒤에만 실행한다.

```bash
ansible-playbook \
  -i /home/jy/ansible/inventory.ini \
  ansible/kerberized_nfs_poc.yml \
  -e target_hosts=farm2 \
  -e kerb_nfs_apply=true \
  -e kerb_nfs_install_packages=true \
  -e kerb_nfs_server_fqdn=<nas-fqdn> \
  -e kerb_realm=<REALM> \
  -e kerb_kdc=<kdc-fqdn> \
  -e kerb_domain=<dns-domain>
```

성공 확인:

```bash
findmnt -T /mnt/nas-krb-share -o TARGET,SOURCE,FSTYPE,OPTIONS
```

`OPTIONS`에 `sec=krb5p`가 보여야 한다.

## Docker 테스트

병렬 mount가 성공하면 테스트 홈을 준비한 뒤 컨테이너를 띄운다.

```bash
sudo mkdir -p /mnt/nas-krb-share/user-share/krbtest
sudo chown 13100:13100 /mnt/nas-krb-share/user-share/krbtest
sudo chmod 750 /mnt/nas-krb-share/user-share/krbtest
```

이후 테스트용 Docker run 또는 create script 변형에서 mount source를 아래로 바꾼다.

```text
/mnt/nas-krb-share/user-share/
```

## Rollback

병렬 mount만 해제한다. 기존 `/home/tako2/share`는 건드리지 않는다.

```bash
sudo umount /mnt/nas-krb-share
sudo rmdir /mnt/nas-krb-share
```

`/etc/krb5.conf`를 playbook으로 썼다면 기존 파일 백업 정책을 정한 뒤 원복한다.

## 다음 단계

1. host-level `sec=krb5p` 병렬 mount 성공
2. Docker bind mount로 DECS 컨테이너 smoke
3. 컨테이너 내부 `kinit`/ticket lifecycle 검토
4. host `rpc.gssd`/`gssproxy`가 컨테이너 사용자 credential을 사용할 수 있는지 검증
5. k8s CSI/PV/PVC 구조로 확장
