# NAS Kerberos Adoption Guide

이 문서는 DECS/FARM 환경에서 Synology NAS의 NFS 접근을 Kerberos 기반으로 전환하기 위한 절차를 정리한다.

현재 PoC 기준 목표는 다음과 같다.

- Samba AD DC: `farm2`
- Realm: `FARM.DECS.INTERNAL`
- NetBIOS domain: `FARM`
- NAS FQDN: `nas.farm.decs.internal`
- NAS NFS principal: `nfs/nas.farm.decs.internal@FARM.DECS.INTERNAL`
- 테스트 공유 폴더: `/volume1/test_krb`
- 테스트 NFS mount: `/mnt/nas-krb-test-v4`
- 사용자별 host ccache: `/run/user/<uid>/krb5cc`
- 사용자별 host keytab: `/etc/decs-krb/keytabs/<username>.keytab`
- 컨테이너는 keytab을 받지 않고, host가 갱신한 ccache만 bind mount로 받는다.

## 0. 원칙

Kerberos NFS는 Ingress/Proxy 인증이 아니다. NAS NFS 서버와 FARM host NFS client가 같은 Kerberos realm을 신뢰해야 하고, NFS 요청은 `sec=krb5p` RPCSEC_GSS로 처리된다.

현재 DECS 컨테이너 구조에서는 컨테이너가 직접 NFS mount를 하지 않는다. FARM host가 NAS를 NFSv4.1 `sec=krb5p`로 mount하고, 컨테이너는 그 mount를 `/home`에 bind mount한다. Kerberos 인증은 host kernel/rpc.gssd가 요청 process UID 기준으로 `/run/user/<uid>/krb5cc`를 찾아 처리한다.

그래서 Kerberos 모드에서는 다음이 필수다.

- AD user/group에 RFC2307 UID/GID 속성이 있어야 한다.
- NAS가 AD user/group을 `wbinfo`로 UID/GID까지 해석할 수 있어야 한다.
- FARM host에도 NFS idmapper가 이해할 shadow user/group이 준비되어야 한다.
- 컨테이너 사용자가 root가 되어 다른 UID를 가장하지 못하도록 sudo는 restricted mode여야 한다.

## 1. 사전 준비

운영 공유 폴더를 바로 바꾸지 말고 테스트 공유 폴더로 시작한다.

```bash
/volume1/test_krb
```

확인할 것:

- farm2, NAS, FARM host들의 시간이 NTP로 맞는지 확인한다.
- AD DC와 NAS가 같은 DNS 기준을 사용하게 한다.
- `nas.farm.decs.internal`이 NAS의 NFS 통신 IP로 안정적으로 해석되게 한다.
- AD DC 저장소는 Kerberos NFS mount 위에 두지 않는다. AD가 죽으면 Kerberos NFS도 같이 죽는 순환 의존이 생긴다.
- 기존 운영 공유 `/volume1/share/user-share`는 건드리지 않는다.

## 2. Samba AD DC 준비

farm2에 Samba AD DC를 준비한다.

기준 값:

```text
Realm: FARM.DECS.INTERNAL
NetBIOS: FARM
DC host: dc1.farm.decs.internal
```

확인 명령:

```bash
sudo samba-tool domain info 127.0.0.1
host -t SRV _kerberos._udp.farm.decs.internal
host -t SRV _ldap._tcp.farm.decs.internal
kinit Administrator@FARM.DECS.INTERNAL
klist
```

DNS forwarder도 확인한다.

```bash
nslookup dc1.farm.decs.internal
nslookup google.com
```

AD DC가 Kerberos, LDAP, DNS를 안정적으로 제공하지 못하면 NAS join과 NFS Kerberos가 모두 흔들린다.

## 3. NAS를 AD에 Join

Synology DSM UI에서 Domain/LDAP join을 할 수 있으면 UI를 우선 사용한다. CLI로 할 경우 현재 PoC에서 사용한 형태는 다음과 같다.

```bash
read -rsp "AD Administrator password: " AD_PASS; echo
sudo /usr/syno/sbin/synowin -joinDomain FARM Administrator "$AD_PASS" \
  -d 100.100.100.102 \
  -i 100.100.100.102 \
  -n FARM \
  -f farm.decs.internal
unset AD_PASS
```

확인:

```bash
/usr/syno/sbin/synowin -getWorkgroup
/usr/syno/sbin/synowin -updateDomain
```

`-joinDomain`이 성공해도 `synowin -updateDomain`이 실패하면 정상 상태로 보면 안 된다. 이 경우 바로 NFS Kerberos로 넘어가지 말고 DNS, 시간, AD DC 상태, NAS domain 상태를 먼저 고쳐야 한다.

AD user/group 해석 확인:

```bash
/usr/local/packages/@appstore/SMBService/usr/bin/wbinfo -t
/usr/local/packages/@appstore/SMBService/usr/bin/wbinfo -u | head
/usr/local/packages/@appstore/SMBService/usr/bin/wbinfo -g | head
/usr/local/packages/@appstore/SMBService/usr/bin/wbinfo -i 'FARM\someuser'
/usr/local/packages/@appstore/SMBService/usr/bin/wbinfo --group-info 'FARM\somegroup'
```

여기서 UID/GID 숫자가 나오지 않으면 AD RFC2307 속성 또는 NAS AD mapping 문제가 남아있는 것이다.

## 4. 테스트 공유 폴더 준비

테스트 공유는 `/volume1/test_krb`를 사용한다.

이미 생성되어 있는지 확인:

```bash
sudo /usr/syno/sbin/synoshare --get test_krb
sudo /usr/syno/sbin/synoshare --get-real-path test_krb
ls -ld /volume1/test_krb
```

없으면 DSM UI에서 만들거나 `synoshare`로 만든다. CLI 인자는 DSM 버전에 따라 조금씩 다를 수 있으므로, 반드시 `synoshare --help` 출력에 맞춘다.

예시:

```bash
sudo mkdir -p /volume1/test_krb
sudo /usr/syno/sbin/synoshare --add test_krb "DECS Kerberos NFS PoC" /volume1/test_krb "" "" "" 0 0
```

운영 공유 폴더와 테스트 공유 폴더를 섞지 않는다.

## 5. NAS NFS Service Principal 준비

NFS Kerberos 서버는 NAS service principal을 가져야 한다.

현재 PoC 기준 principal:

```text
nfs/nas.farm.decs.internal@FARM.DECS.INTERNAL
```

AD DC에서 principal/SPN을 준비한다. NAS machine account에 SPN을 붙이거나 별도 service account를 쓰는 방식 중 하나를 선택한다. PoC에서는 NAS의 기본 keytab에서 `svcgssd`가 principal을 찾을 수 있어야 한다.

확인:

```bash
sudo klist -kte /etc/krb5.keytab
```

`nfs/nas.farm.decs.internal@FARM.DECS.INTERNAL` 항목이 있어야 한다.

주의:

- NAS의 `/etc/krb5.keytab`을 무작정 overwrite하지 않는다.
- DSM이 관리하는 keytab이 있으면 merge 또는 DSM 방식으로 등록해야 한다.
- keytab은 password-equivalent secret이다. root 전용 `0400` 권한이어야 한다.

## 6. NAS NFS Export를 Kerberos로 설정

테스트 공유 폴더에 대해서만 NFS Kerberos를 켠다.

목표:

```text
NFSv4.1
sec=krb5p
root_squash 유지
대상 path: /volume1/test_krb
```

DSM UI에서 공유 폴더의 NFS 권한을 설정하는 것이 가장 안전하다. CLI로 직접 export 파일을 수정하는 방식은 DSM이 덮어쓸 수 있으므로 운영 반영 전에는 피한다.

확인:

```bash
sudo exportfs -v
cat /proc/fs/nfsd/versions 2>/dev/null || true
```

출력에서 테스트 공유가 `sec=krb5p`로 export되어야 한다.

## 7. NAS GSS/idmap 서비스 갱신

AD user/group을 새로 만들면 NAS와 kernel RPC cache가 이전 상태를 잠시 들고 있을 수 있다. PoC create flow는 다음 refresh를 자동으로 수행한다.

```bash
sudo kill $(pidof svcgssd)
sudo /usr/sbin/svcgssd -p nfs/nas.farm.decs.internal@FARM.DECS.INTERNAL

sudo kill $(pidof idmapd)
sudo /usr/sbin/idmapd
```

그리고 다음 cache flush 파일에 현재 epoch timestamp를 쓴다.

```text
/proc/net/rpc/auth.unix.gid/flush
/proc/net/rpc/nfs4.idtoname/flush
/proc/net/rpc/nfs4.nametoid/flush
/proc/net/rpc/auth.rpcsec.init/flush
/proc/net/rpc/auth.rpcsec.context/flush
```

확인:

```bash
pidof svcgssd
pidof idmapd
```

주의:

- 이 작업은 영구 설정 변경이 아니라 runtime refresh다.
- active Kerberos NFS session에는 짧은 영향이 있을 수 있다.

## 8. FARM Host NFSv4.1 Mount

FARM host에는 NFS/Kerberos client 패키지가 필요하다.

```bash
sudo apt-get update
sudo apt-get install -y nfs-common krb5-user keyutils
```

필수 설정:

- `/etc/krb5.conf`가 `FARM.DECS.INTERNAL` realm을 알아야 한다.
- `rpc-gssd`가 동작해야 한다.
- NFSv4 idmap domain이 NAS/host 사이에서 맞아야 한다.

mount 예시:

```bash
sudo mkdir -p /mnt/nas-krb-test-v4
sudo mount -t nfs4 \
  -o vers=4.1,sec=krb5p,proto=tcp \
  nas.farm.decs.internal:/volume1/test_krb \
  /mnt/nas-krb-test-v4
```

현재 DECS create flow는 사용자 home root를 다음으로 본다.

```text
/mnt/nas-krb-test-v4/user-share
```

확인:

```bash
findmnt /mnt/nas-krb-test-v4
nfsstat -m
systemctl status rpc-gssd
```

`nfsstat -m`에 `sec=krb5p`와 `vers=4.1`이 보여야 한다.

### FARM Host AD/NSS identity resolution

Kerberos NFS mount가 성공해도 FARM host가 AD user/group을 NSS로 해석하지
못하면 container 안에서 home owner가 `nobody:nogroup` 또는 `65534:65534`로
보인다.

필수 조건:

- FARM host가 AD identity를 resolve할 수 있어야 한다.
- 현재 DECS/FARM 구조에서는 `winbind` + `libnss-winbind` + `nsswitch.conf` 조합을 사용한다.
- AD DC host는 Samba AD DC 자체 설정으로 `FARM\user`를 해석할 수 있어야 한다.
- AD DC가 아닌 FARM client host는 standalone Samba 상태이면 부족하다. AD domain member로 join되어 있거나, 동등하게 `FARM\user`를 UID/GID로 풀 수 있는 NSS/idmap 구성이 있어야 한다.

패키지:

```bash
sudo apt-get update
sudo apt-get install -y winbind libnss-winbind
```

`/etc/nsswitch.conf`에는 `passwd`와 `group`에 `winbind`가 포함되어야 한다.

```text
passwd:         files systemd winbind
group:          files systemd winbind
```

적용 후 확인:

```bash
grep -E '^(passwd|group):' /etc/nsswitch.conf
systemctl is-active winbind || true
testparm -s 2>/dev/null | egrep 'server role|workgroup|realm|security|idmap config'
wbinfo -n 'FARM\someuser'
wbinfo -i 'FARM\someuser'
getent passwd 'FARM\someuser'
getent group 'FARM\somegroup'
```

정상 예:

```text
FARM\uidcanon260627:*:10145:100::/home/FARM/uidcanon260627:/bin/false
```

`wbinfo`가 `WORKGROUP`을 보거나 `checking the trust secret for domain WORKGROUP failed`
같은 메시지를 내면 해당 host는 아직 AD domain identity를 제대로 해석하지
못하는 상태다. 이 상태에서 `nsswitch.conf`에 `winbind`만 추가해도
`nobody:nogroup` 문제는 해결되지 않는다.

NFS idmap cache refresh:

```bash
sudo nfsidmap -c || true
for p in \
  /proc/net/rpc/nfs4.idtoname/flush \
  /proc/net/rpc/nfs4.nametoid/flush \
  /proc/net/rpc/auth.unix.gid/flush
do
  [ -e "$p" ] && echo 0 | sudo tee "$p" >/dev/null || true
done
```

최종 검증:

```bash
sudo stat -c '%U|%G|%u|%g|%n' /home/takoX/share/user-share/<username>
```

정상이라면 UID가 AD `uidNumber`와 같아야 한다. `65534:65534` 또는
`nobody:nogroup`이면 create-container를 진행하지 않는다.

운영 중 자주 보이는 현상:

```bash
df -h /home/takoX/share
ls -al /home/takoX
```

일반 `takoX` 계정이 Kerberos ticket 없이 실행하면 `/home/takoX/share`가
`Permission denied` 또는 `d?????????`로 보일 수 있다. 이 자체는 mount 실패를
의미하지 않는다. mount 확인은 root 권한으로 한다.

```bash
sudo df -h /home/takoX/share
findmnt -T /home/takoX/share
```

하지만 root 권한으로 `stat`을 해도 user home owner가 `nobody:nogroup`이면
AD/NSS/idmap 문제가 남아있는 것이다.

### FARM Host static idmap/shadow fallback

정석은 FARM host를 AD DC 또는 AD domain member로 구성해서 `winbind`가
`FARM\user`를 직접 풀게 하는 것이다. 하지만 host가 아직 standalone Samba
상태이거나 `winbind`가 RFC2307 UID를 제대로 반영하지 못하면, 운영 중단 없이
다음 fallback을 쓸 수 있다.

핵심은 host의 `/etc/passwd`, `/etc/group`, `/etc/idmapd.conf`에 NFSv4 owner
string을 해석할 최소 shadow identity를 만드는 것이다.

예시: AD user `FARM\alice`, AD `uidNumber=10145`, NFS group은
`FARM\Domain Users -> users(100)`로 매핑하는 경우.

`/etc/passwd`:

```text
FARM\alice:x:10145:100::/home/FARM\alice:/usr/sbin/nologin
alice:x:10145:100::/home/alice:/usr/sbin/nologin
```

`/etc/group`:

```text
FARM\Domain Users:x:100:
FARM\domain users:x:100:
```

`/etc/idmapd.conf`:

```ini
[Translation]
Method = static,nsswitch

[Static]
FARM\alice@localdomain = alice
FARM\alice@farm.decs.internal = alice
FARM\Domain Users@localdomain = users
FARM\Domain Users@farm.decs.internal = users
FARM\domain users@localdomain = users
FARM\domain users@farm.decs.internal = users
```

적용 후 cache를 비운다.

```bash
sudo nfsidmap -c || true
for p in \
  /proc/net/rpc/nfs4.idtoname/flush \
  /proc/net/rpc/nfs4.nametoid/flush \
  /proc/net/rpc/auth.unix.gid/flush
do
  [ -e "$p" ] && echo 0 | sudo tee "$p" >/dev/null || true
done
```

2026-06-27 운영 확인:

- `uidcanon260627`은 모든 FARM host에서 `uidNumber=10145`로 보이도록 확인했다.
- 기존 `/user-share/jy`는 `jy`가 아니라 AD user `farm_jy`, `uidNumber=11003`
  소유로 NAS에서 내려온다.
- farm1/farm8/farm9는 이 이름을 못 풀어 `nobody:users`, `65534:100`으로
  보였고, farm6은 cache/idmap 문제로 `3000009:100`으로 보였다.
- host shadow identity와 static idmap을 추가한 뒤 모든 FARM host에서
  `/home/takoX/share/user-share/jy`가 `FARM\farm_jy|users|11003|100`으로
  보이는 것을 확인했다.

주의:

- 이 fallback은 NAS 데이터를 chown하지 않고 host의 이름 해석만 맞춘다.
- `jy`처럼 기존 이름과 AD 이름이 갈라진 경우, 실제 소유권 기준은 NFS가
  반환하는 AD identity다. `jy UID 1003`으로 쓰고 싶다면 별도 AD/NAS ownership
  migration을 해야 한다.
- 새 create-container flow는 생성 대상 username에 대해서 이 shadow identity와
  static idmap을 자동 준비해야 한다.

### Samba AD DC RFC2307 cache note

Samba AD DC host에서는 standalone `winbind.service`를 따로 띄우면 안 된다.
AD DC identity resolution은 `samba-ad-dc`가 제공하는 winbind 기능을 통해
동작해야 한다.

AD DC에서 `samba-tool user show <user>`에는 `uidNumber`가 있는데
`wbinfo -i 'FARM\<user>'`가 `3000000`대 idmap UID를 반환하면 다음을 확인한다.

```bash
testparm -s 2>/dev/null | grep -i 'idmap_ldb:use rfc2307'
sudo net cache flush
sudo systemctl restart samba-ad-dc
```

필요하면 cache DB를 백업한 뒤 제거하고 `samba-ad-dc`를 재시작한다.

```bash
sudo cp -a /var/lib/samba/winbindd_cache.tdb \
  /var/lib/samba/winbindd_cache.tdb.bak.$(date +%Y%m%d%H%M%S)
sudo rm -f /var/lib/samba/winbindd_cache.tdb
sudo systemctl restart samba-ad-dc
```

검증:

```bash
wbinfo -i 'FARM\uidcanon260627'
sudo stat -c '%U|%G|%u|%g|%n' /home/takoX/share/user-share/uidcanon260627
```

create-container에서 같은 사용자를 여러 FARM host에 만들 때는 같은 AD username을
재사용해야 한다. 예를 들어 `uidcanon260627`로 만든 test principal이 이미
`uidNumber=10145`를 갖고 있으면, 다른 FARM host의 test container도
`--username uidcanon260627`로 만들어 같은 UID/GID를 재사용해야 한다.
`--no-db-record`로 만든 AD principal은 DB `used_ids`에 남지 않으므로, create
로직은 DB뿐 아니라 AD의 기존 `uidNumber/gidNumber`도 확인해야 한다.

### NFSv4.1 compatibility note

2026-06-22 multi-DC testing found a host-specific compatibility issue:

- farm2 mounted the Synology test export with NFSv4.1 `sec=krb5p`.
- farm6 and farm7 timed out with NFSv4.1 against the same export.
- farm6 and farm7 mounted successfully with NFSv4.0 `sec=krb5p`, and Kerberos
  NFS write checks passed.

This does not invalidate the Kerberos model, but strict NFSv4.1 rollout should
wait until the farm6/farm7 kernel/NFS client and Synology DSM/NFS server
combination is isolated. For functional Kerberos/root-squash testing, NFSv4.0
`sec=krb5p` is an acceptable temporary FARM host mount on affected hosts.

## 9. AD User/Group RFC2307 Provisioning

Kerberos NFS 권한은 단순 username 문자열이 아니라 AD user/group의 UID/GID mapping에 의존한다.

DECS create flow가 해야 하는 일:

- AD user principal 생성
- AD user에 `uidNumber`, `gidNumber`, `unixHomeDirectory`, `loginShell`, `msSFU30*` 속성 설정
- AD group 생성
- AD group에 `gidNumber`, `msSFU30*` 속성 설정
- user를 AD group member로 추가
- NAS에서 `wbinfo -i 'FARM\<user>'`와 `wbinfo --group-info 'FARM\<group>'`로 UID/GID 조회

Python CLI 기준:

```bash
cd ~/uid/script
python3 -B -m uid_manager.cli manage-group ensure \
  --group project_a \
  --domain FARM

python3 -B -m uid_manager.cli manage-group add-user \
  --group project_a \
  --user alice \
  --domain FARM
```

컨테이너 생성 시에는 `--group`을 지정하면 AD group과 DB group을 같이 맞춘다.

```bash
python3 -B -m uid_manager.cli create-container \
  --name "Alice" \
  --username alice \
  --group project_a \
  --server-id FARM2 \
  --expiration-date 2026-12-31 \
  --image decs \
  --version krb-e2e-260621 \
  --created-by jy \
  --email alice@example.com \
  --phone 010-0000-0000 \
  --enable-kerberos \
  --enable-vnc
```

## 10. Host Keytab and Ccache Flow

사용자 Kerberos password를 DB나 컨테이너에 저장하지 않는다.

현재 설계:

1. AD user principal을 만든다.
2. AD password는 무작위로 생성하거나 rotation한다.
3. farm host에 사용자별 keytab을 export한다.
4. keytab은 root-only secret으로 저장한다.
5. systemd timer가 `kinit -kt`로 ccache를 갱신한다.
6. 컨테이너는 keytab이 아니라 ccache만 bind mount로 받는다.

경로:

```text
/etc/decs-krb/keytabs/<username>.keytab     root:root 0400
/etc/decs-krb/refresh.d/<username>.env      root:root 0600
/run/user/<uid>/                            <uid>:<gid> 0700
/run/user/<uid>/krb5cc                      <uid>:<gid> 0600
```

확인:

```bash
sudo klist -kte /etc/decs-krb/keytabs/alice.keytab
sudo systemctl status decs-krb-refresh@alice.timer
sudo systemctl start decs-krb-refresh@alice.service
sudo -u '#<uid>' KRB5CCNAME=FILE:/run/user/<uid>/krb5cc klist
```

## 11. 컨테이너 Integration

Kerberos container는 다음을 받아야 한다.

```text
--mount source=/mnt/nas-krb-test-v4/user-share,target=/home
--mount source=/run/user/<uid>,target=/run/user/<uid>
--mount source=/etc/krb5.conf,target=/etc/krb5.conf,readonly
KRB5CCNAME=FILE:/run/user/<uid>/krb5cc
DECS_KERBEROS_ENABLED=true
DECS_KERBEROS_HOST_KEYTAB=true
DECS_USER_SUDO_MODE=restricted
```

`DECS_USER_SUDO_MODE=restricted`는 필수다. 컨테이너 사용자가 root가 되면 host rpc.gssd가 UID 기준으로 다른 사용자의 ccache를 사용할 수 있어 UID spoofing이 가능해진다.

허용/차단 정책:

- package 설치 목적 sudo는 허용
- `sudo -u`, `su`, `setpriv`, `runuser`, root shell, `chmod/chown/chgrp`, mount namespace 관련 명령은 차단

## 12. 검증 Checklist

NAS:

```bash
/usr/syno/sbin/synowin -getWorkgroup
/usr/syno/sbin/synowin -updateDomain
/usr/local/packages/@appstore/SMBService/usr/bin/wbinfo -t
/usr/local/packages/@appstore/SMBService/usr/bin/wbinfo -i 'FARM\alice'
/usr/local/packages/@appstore/SMBService/usr/bin/wbinfo --group-info 'FARM\project_a'
sudo klist -kte /etc/krb5.keytab
sudo exportfs -v
pidof svcgssd
pidof idmapd
```

FARM host:

```bash
findmnt /mnt/nas-krb-test-v4
nfsstat -m
sudo klist -kte /etc/decs-krb/keytabs/alice.keytab
sudo systemctl status decs-krb-refresh@alice.timer
sudo setpriv --reuid=<uid> --regid=<gid> --clear-groups \
  env KRB5CCNAME=FILE:/run/user/<uid>/krb5cc \
  sh -c 'printf ok > /mnt/nas-krb-test-v4/user-share/alice/.krb_write_test && rm -f /mnt/nas-krb-test-v4/user-share/alice/.krb_write_test'
```

컨테이너:

```bash
env | grep KRB5CCNAME
klist
touch ~/self_write_test && rm ~/self_write_test
group-dir-share ~/sharing_dir project_a
```

서비스:

- SSH password login
- Jupyter HTTP 200
- noVNC HTTP 200
- 사용자 home write
- 같은 AD group 사용자 간 `group-dir-share` read/write/delete
- 다른 사용자 home write 실패
- UID spoofing sudo 명령 실패
- package 설치용 sudo 동작

## 13. 운영 반영 순서

운영 공유로 바로 전환하지 말고 다음 순서로 진행한다.

1. `/volume1/test_krb`에서 신규 테스트 user/group으로 검증한다.
2. 같은 username으로 컨테이너를 한 번 더 만들어 기존 home/keytab/ccache 재사용을 검증한다.
3. `extend-container`, `expired-cleanup`, `delete-container` 후처리를 검증한다.
4. NAS GSS/idmap refresh가 active session에 주는 영향을 관찰한다.
5. 테스트 공유에서 1주 이상 안정성을 본다.
6. 운영 공유 `/volume1/share/user-share`에 Kerberos export를 적용할지 결정한다.
7. 운영 반영 전에는 현재 NFS export와 DSM 설정을 백업한다.
8. FARM부터 적용하고 LAB은 별도 realm/domain 설계를 확정한 뒤 적용한다.

## 14. Rollback

테스트 단계 rollback:

```bash
sudo umount /mnt/nas-krb-test-v4
sudo systemctl disable --now decs-krb-refresh@<username>.timer
sudo rm -f /etc/decs-krb/keytabs/<username>.keytab
sudo rm -f /etc/decs-krb/refresh.d/<username>.env
sudo rm -rf /run/user/<uid>
```

NAS:

- `/volume1/test_krb` export만 원복한다.
- 운영 공유 export는 건드리지 않는다.
- AD join 해제는 NAS 전체 SMB/NFS identity에 영향이 있으므로 테스트 공유 원복과 별도로 판단한다.

AD:

```bash
sudo samba-tool group delete <test_group>
sudo samba-tool user delete <test_user>
```

운영 반영 후 rollback은 NAS export, FARM mount, DECS create flow, AD user/group, DB metadata가 얽히므로 별도 작업 계획을 세워야 한다.

## 15. 현재 UID Python CLI 관련 파일

```text
~/uid/script/uid_manager/services/create_container.py
~/uid/script/uid_manager/services/manage_group.py
~/uid/script/uid_manager/kerberos/commands.py
~/uid/script/playbooks/nas_kerberos_refresh.yml
~/uid/script/playbooks/nas_prepare_home.yml
~/uid/script/playbooks/farm_host_kerberos_identity.yml
```

기존 shell 기준 참고:

```text
~/uid/legacy/script/create_container.sh
~/uid/legacy/script/common_domain_db.sh
~/uid/legacy/script/manage_group.sh
~/uid/README_create_container.md
```
