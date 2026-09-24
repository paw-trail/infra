#!/bin/bash
# =============================================================================
# 미니 PC 에 서버 운영 설정을 놓음 — 여러 번 돌려도 결과가 같음
# =============================================================================
#   1  journald 30일           ops/journald-pawtrail.conf → /etc/systemd/journald.conf.d/pawtrail.conf
#   2  docker 로그 → journald   /etc/docker/daemon.json 의 log-driver (다른 설정은 그대로 둠)
#   3  outbox 정리 매일 04:30   pawtrail-outbox-cleanup.service · .timer
#   4  부팅 때 스택 켜기        pawtrail-stack.service (docker 가 뜰 때마다 compose 를 순서대로 켬)
#
# docker 를 다시 시작하는 일은 하지 않음 — 컨테이너가 모두 멈추므로 따로 함
#   sudo systemctl restart docker
#   sudo docker compose up -d --force-recreate      (로그 드라이버는 컨테이너를 새로 만들 때 바뀜)
#
# 쓰는 법   cd ~/pawtrail/infra && sudo bash ops/install.sh
# =============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "sudo 로 실행할 것: sudo bash $0" >&2; exit 1; }
D=$(cd "$(dirname "$0")" && pwd)

# 1 journald 30일
install -D -m 644 "$D/journald-pawtrail.conf" /etc/systemd/journald.conf.d/pawtrail.conf
systemctl restart systemd-journald
echo "1 journald — 30일 보관 · 하루 단위 파일 · 전체 2G"

# 2 docker 로그 드라이버
#   json-file 용 log-opts(max-size 등)가 남아 있으면 journald 에서는 docker 가 뜨지 않으므로 함께 걷음
python3 - <<'PY'
import json, os
path = '/etc/docker/daemon.json'
cfg = {}
if os.path.exists(path):
    text = open(path).read().strip()
    cfg = json.loads(text) if text else {}
before = json.dumps(cfg, sort_keys=True)
cfg['log-driver'] = 'journald'
cfg.pop('log-opts', None)
if json.dumps(cfg, sort_keys=True) != before:
    os.makedirs('/etc/docker', exist_ok=True)
    with open(path, 'w') as f:
        json.dump(cfg, f, indent=2)
        f.write('\n')
    print('2 docker — daemon.json 에 log-driver journald 를 넣음 (docker 를 다시 시작해야 적용)')
else:
    print('2 docker — 이미 journald')
PY

# 3 outbox 정리 타이머 — 스크립트는 이 저장소 안의 것을 그대로 부름 (git pull 하면 바로 반영)
cat > /etc/systemd/system/pawtrail-outbox-cleanup.service <<UNIT
[Unit]
Description=함께하개 - 발행 끝나고 30일 지난 outbox 행 정리
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash ${D}/outbox-cleanup.sh
UNIT

cat > /etc/systemd/system/pawtrail-outbox-cleanup.timer <<'UNIT'
[Unit]
Description=함께하개 - outbox 정리 매일 04:30

[Timer]
OnCalendar=*-*-* 04:30:00
# 그 시각에 꺼져 있었으면 켜진 뒤 한 번 돎
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now pawtrail-outbox-cleanup.timer >/dev/null
echo "3 outbox 정리 — 매일 04:30 · 스크립트 ${D}/outbox-cleanup.sh"
systemctl list-timers pawtrail-outbox-cleanup.timer --no-pager | head -3

# 4 부팅 때 스택 켜기
#   재시작 정책을 쓰지 않는 까닭
#     docker 는 재시작 정책으로 컨테이너를 켤 때 compose 의 depends_on 순서를 지키지 않음
#     서비스는 설정 서버를 optional:configserver 로 읽으므로 설정 서버보다 먼저 뜬 서비스가 기본값으로 뜰 수 있음
#     compose up 은 설정 서버 → 유레카 → 게이트웨이 → 서비스 순서로 healthy 를 기다리며 켬
#   --no-recreate    멈춘 컨테이너를 켜기만 함 · 다시 만들지 않으므로 볼륨이 없는 kafka 의 토픽이 남음
#   create-topics    그래도 kafka 컨테이너가 새로 만들어진 경우를 대비해 한 번 더 돌림 (여러 번 돌려도 안전)
#   WantedBy=docker  부팅뿐 아니라 docker 를 다시 시작했을 때도 스택을 다시 켬
R=$(dirname "$D")
cat > /etc/systemd/system/pawtrail-stack.service <<UNIT
[Unit]
Description=함께하개 - docker 가 뜨면 compose 스택을 순서대로 켬
Requires=docker.service
After=docker.service wg-quick@wg0.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${R}
ExecStart=/usr/bin/docker compose up -d --no-recreate
ExecStartPost=/usr/bin/docker compose exec -T kafka bash /opt/scripts/create-topics.sh
TimeoutStartSec=900

[Install]
WantedBy=docker.service
UNIT

systemctl daemon-reload
systemctl enable pawtrail-stack.service >/dev/null
echo "4 부팅 때 스택 켜기 — pawtrail-stack.service · ${R} 에서 docker compose up -d --no-recreate"
