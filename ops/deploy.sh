#!/bin/bash
# =============================================================================
# 함께하개 서비스 하나를 새 판으로 바꿈 — Jenkins 가 SSH 로 부르고, 손으로도 씀
# =============================================================================
# 쓰는 법   sudo pawtrail-deploy <서비스> <판>        예) sudo pawtrail-deploy weather-service v0.1.0
#
# 판(ghcr.io/paw-trail/<서비스>:<판>)은 Jenkins 가 먼저 push 해 둔 것이어야 함
# compose 는 :latest 를 가리키므로, 받은 판에 이 서버에서만 latest 이름을 붙여 교체함
#
# 도메인 서비스   임시 인스턴스를 새 판으로 먼저 띄움 → healthy · 유레카 UP
#                → 본 인스턴스를 유레카에서 빼고(OUT_OF_SERVICE) 게이트웨이 목록이 바뀌기를 기다림
#                → 본 인스턴스를 새 판으로 다시 만듦 → healthy · 유레카 UP
#                → 임시 인스턴스를 유레카에서 빼고 기다렸다가 내림
# 플랫폼          설정 서버 · 유레카 · 게이트웨이는 그냥 다시 만듦 (잠깐 끊김)
# 되돌리기        확인이 실패하면 배포 전 이미지(:previous)로 되돌리고 실패로 끝냄
#
# 설정          /etc/pawtrail-deploy.conf 의 INFRA_DIR (ops/install.sh 가 씀)
# 로그          표준 출력 — Jenkins 가 SSH 로 받아 그대로 보여 줌
# =============================================================================
set -euo pipefail

# SSH 가 끊겨도(Jenkins 중단 등) 반쯤 바꾼 채로 멈추지 않고 끝까지 감
trap '' HUP

log() { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { log "실패 — $*"; FINISHED=1; exit 1; }

# 예상하지 못한 곳에서 멈추면(set -e) 상태를 사람이 보도록 알림 — 스스로 고치려 들지 않음
FINISHED=0
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$FINISHED" = 0 ]; then
    log "예상하지 못한 곳에서 멈춤 (종료 $rc) — docker ps -a 와 docker images 로 상태를 볼 것"
  fi
}
trap on_exit EXIT

CONF=/etc/pawtrail-deploy.conf
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"
INFRA_DIR=${INFRA_DIR:-}
[ -n "$INFRA_DIR" ] && [ -f "$INFRA_DIR/docker-compose.yml" ] || die "INFRA_DIR 를 못 찾음 — ops/install.sh 를 먼저 돌릴 것"

REGISTRY=ghcr.io/paw-trail
EUREKA=http://127.0.0.1:8761/eureka
# 유레카에서 뺀 뒤 게이트웨이가 옛 주소를 잊을 때까지 기다리는 시간
#   유레카 응답 캐시 30초 + 게이트웨이의 목록 받아 오기 30초 + 부하 분산 캐시 35초 안팎
DRAIN=${DRAIN_SECONDS:-90}
PLATFORM="config-server eureka-server gateway-server"

SERVICE=${1:-}
VERSION=${2:-}
[[ "$SERVICE" =~ ^[a-z][a-z0-9-]*$ ]] || die "서비스 이름이 이상함: '$SERVICE'"
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "판은 vX.Y.Z 모양이어야 함: '$VERSION'"

# 한 번에 하나만 — 두 배포가 겹치면 임시 인스턴스 이름과 태그가 엉킴
exec 9>/run/lock/pawtrail-deploy.lock
flock -n 9 || die "다른 배포가 진행 중"

cd "$INFRA_DIR"
IMAGE="$REGISTRY/$SERVICE"
MAIN="pawtrail-$SERVICE"
NEXT="pawtrail-$SERVICE-next"
APP=${SERVICE^^}

# compose 가 이 서비스를 우리 이미지로 띄우는지 확인 — 인자로 아무 컨테이너나 건드리지 못하게
declared=$(docker compose config --format json | python3 -c '
import json, sys
svc = json.load(sys.stdin).get("services", {}).get(sys.argv[1], {})
print(svc.get("image", ""))
' "$SERVICE")
[ "$declared" = "$IMAGE:latest" ] || die "compose 에 $IMAGE:latest 로 떠 있는 서비스가 아님 ($SERVICE → '${declared:-없음}')"

# ---------------------------------------------------------------------------
# 도우미
# ---------------------------------------------------------------------------
container_ip() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"
}

wait_healthy() {   # 컨테이너 · 최대 초
  local c=$1 limit=$2 s i
  for ((i = 0; i < limit; i += 5)); do
    s=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || echo gone)
    case "$s" in
      healthy|none) log "$c — $s"; return 0 ;;
      unhealthy|gone) log "$c — $s"; return 1 ;;
    esac
    sleep 5
  done
  log "$c — ${limit}초 안에 healthy 가 안 됨"
  return 1
}

eureka_instance() {   # 앱 · IP → "인스턴스ID 상태" (없으면 빈 줄)
  curl -fsS -H 'Accept: application/json' "$EUREKA/apps/$1" 2>/dev/null | python3 -c '
import json, sys
try:
    app = json.load(sys.stdin)["application"]
except Exception:
    sys.exit(0)
inst = app.get("instance", [])
inst = inst if isinstance(inst, list) else [inst]
for i in inst:
    if i.get("ipAddr") == sys.argv[1]:
        print(i["instanceId"], i["status"])
        break
' "$2" || true
}

wait_eureka_up() {   # 컨테이너 · 최대 초
  local c=$1 limit=$2 ip found i
  ip=$(container_ip "$c")
  for ((i = 0; i < limit; i += 5)); do
    found=$(eureka_instance "$APP" "$ip")
    if [ "${found#* }" = "UP" ]; then
      log "$c — 유레카 UP (${found% *})"
      return 0
    fi
    sleep 5
  done
  log "$c — ${limit}초 안에 유레카 UP 이 안 됨 (IP $ip)"
  return 1
}

take_out() {   # 컨테이너 — 유레카에서 빼고 게이트웨이가 잊을 때까지 기다림
  local c=$1 ip found
  ip=$(container_ip "$c")
  found=$(eureka_instance "$APP" "$ip")
  if [ -n "$found" ]; then
    curl -fsS -o /dev/null -X PUT "$EUREKA/apps/$APP/${found% *}/status?value=OUT_OF_SERVICE" \
      && log "$c — 유레카에서 뺌 (${found% *}) · ${DRAIN}초 기다림"
    sleep "$DRAIN"
  else
    log "$c — 유레카에 없음 · 기다리지 않음"
  fi
}

recreate_main() {
  docker compose up -d --no-deps --force-recreate "$SERVICE"
}

# ---------------------------------------------------------------------------
# 준비 — 지금 이미지를 :previous 로 표시하고 새 판을 받아 :latest 로
# ---------------------------------------------------------------------------
log "배포 시작 — $SERVICE $VERSION"
if docker inspect "$MAIN" >/dev/null 2>&1; then
  docker tag "$(docker inspect -f '{{.Image}}' "$MAIN")" "$IMAGE:previous"
  log "지금 이미지를 $IMAGE:previous 로 표시"
  HAS_PREVIOUS=1
else
  log "지금 도는 $MAIN 이 없음 — 되돌릴 이미지 없이 새로 띄움"
  HAS_PREVIOUS=0
fi

docker pull -q "$IMAGE:$VERSION"
docker tag "$IMAGE:$VERSION" "$IMAGE:latest"
log "$IMAGE:$VERSION 를 받아 latest 로 붙임"

rollback_main() {
  if [ "$HAS_PREVIOUS" = 1 ]; then
    log "되돌림 — $IMAGE:previous 로"
    docker tag "$IMAGE:previous" "$IMAGE:latest"
    recreate_main
    wait_healthy "$MAIN" 300 || log "되돌린 판도 healthy 가 안 됨 — 사람이 볼 것"
  fi
}

# ---------------------------------------------------------------------------
# 플랫폼 — 그냥 다시 만듦
# ---------------------------------------------------------------------------
if [[ " $PLATFORM " == *" $SERVICE "* ]] || [ "$HAS_PREVIOUS" = 0 ]; then
  recreate_main
  if wait_healthy "$MAIN" 300 && { [ "$SERVICE" = eureka-server ] || wait_eureka_up "$MAIN" 120; }; then
    docker image prune -f >/dev/null
    log "배포 끝 — $SERVICE $VERSION"
    FINISHED=1
    exit 0
  fi
  rollback_main
  die "$SERVICE $VERSION 가 확인을 통과하지 못해 되돌림"
fi

# ---------------------------------------------------------------------------
# 도메인 서비스 — 새 것 먼저
# ---------------------------------------------------------------------------
docker rm -f "$NEXT" >/dev/null 2>&1 || true
docker compose run -d --no-deps --name "$NEXT" "$SERVICE" >/dev/null
log "임시 인스턴스 $NEXT 를 새 판으로 띄움"

if ! { wait_healthy "$NEXT" 300 && wait_eureka_up "$NEXT" 120; }; then
  docker rm -f "$NEXT" >/dev/null 2>&1 || true
  [ "$HAS_PREVIOUS" = 1 ] && docker tag "$IMAGE:previous" "$IMAGE:latest"
  die "새 판이 뜨지 않아 멈춤 — 본 인스턴스는 옛 판 그대로"
fi

take_out "$MAIN"
recreate_main
log "본 인스턴스 $MAIN 를 새 판으로 다시 만듦"

if ! { wait_healthy "$MAIN" 300 && wait_eureka_up "$MAIN" 120; }; then
  rollback_main
  wait_eureka_up "$MAIN" 120 || true
  take_out "$NEXT"
  docker rm -f "$NEXT" >/dev/null 2>&1 || true
  die "본 인스턴스가 새 판으로 확인을 통과하지 못해 되돌림"
fi

take_out "$NEXT"
docker stop -t 30 "$NEXT" >/dev/null
docker rm "$NEXT" >/dev/null
docker image prune -f >/dev/null
FINISHED=1
log "배포 끝 — $SERVICE $VERSION (끊김 없이)"
