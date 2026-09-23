#!/bin/bash
# =============================================================================
# 미니 PC 에 운영 기록 보관 설정을 놓음 — 여러 번 돌려도 결과가 같음
# =============================================================================
#   1  journald 30일           ops/journald-pawtrail.conf → /etc/systemd/journald.conf.d/pawtrail.conf
#   2  docker 로그 → journald   /etc/docker/daemon.json 의 log-driver (다른 설정은 그대로 둠)
#   3  outbox 정리 매일 04:30   pawtrail-outbox-cleanup.service · .timer
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
