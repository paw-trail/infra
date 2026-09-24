#!/bin/bash
# =============================================================================
# 프론트 빌드(dist)를 사이트에 올림 — Jenkins 가 sudo 로 부르고, 손으로도 씀
# =============================================================================
# 쓰는 법   sudo pawtrail-frontend-deploy <dist 폴더> <판>
#          예) sudo pawtrail-frontend-deploy /home/ubuntu/frontend-dist-v0.1.2 v0.1.2
#
# 순서
#   1  검사     dist 에 index.html · assets/ 가 있는지 · 허락된 자리인지 · 판이 vX.Y.Z 인지
#   2  보관     지금 사이트를 /var/www/paw-trail.previous 로 통째로 복사 (되돌리기용)
#   3  파일     index.html 을 뺀 새 파일을 먼저 넣음 · assets/ 의 옛 파일은 지우지 않음
#              이미 사이트를 열어 둔 브라우저는 옛 index.html 로 옛 조각 파일을 부르기 때문
#              (nginx 의 /assets/ 는 없는 파일에 404 를 줌)
#   4  index    index.html 을 맨 마지막에 바꿈 — 옆에 써 두고 이름만 바꿔 반쯤 쓴 파일이 보이지 않게
#   5  확인     https://paw-trail.click/ 이 새 index.html 을 내주고, 거기 적힌 파일 하나가 열리는지
#              아니면 보관한 판으로 되돌리고 실패로 끝냄
#   6  정리     assets/ 에서 30일 넘게 안 바뀐 파일을 지움 — 새 빌드에 든 파일은 이번에 시각을 새로 찍어 둠
#
# 보관 · 되돌리기는 --checksum 으로 내용을 비교함
#   index.html 은 해시 길이가 같아 크기가 같고, 같은 초에 바뀌면 시각도 같아 rsync 가 건너뛸 수 있음
# =============================================================================
set -euo pipefail

SITE=/var/www/paw-trail
PREV=/var/www/paw-trail.previous
TMP_INDEX=/var/www/.paw-trail-index.html.new
URL=https://paw-trail.click
KEEP_DAYS=30

log() { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { log "실패 — $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "sudo 로 실행할 것"

VERSION=${2:-}
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "판은 vX.Y.Z 모양이어야 함: '$VERSION'"
SRC=$(realpath -e "${1:-/nonexistent}" 2>/dev/null) || die "dist 폴더가 없음: '${1:-}'"

# 아무 폴더나 사이트에 올리지 못하게 — 경로는 심볼릭 링크를 푼 뒤에 봄
case "$SRC" in
  /var/lib/jenkins/workspace/*/dist | /home/ubuntu/frontend-dist-v*) ;;
  *) die "올릴 수 있는 자리가 아님: $SRC (Jenkins 작업 폴더의 dist 나 /home/ubuntu/frontend-dist-v* 만)" ;;
esac
[ -f "$SRC/index.html" ] && [ -d "$SRC/assets" ] || die "index.html · assets/ 가 없음 — 빌드 결과가 맞는지 볼 것: $SRC"

# 한 번에 하나만
exec 9>/run/lock/pawtrail-frontend-deploy.lock
flock -n 9 || die "다른 프론트 배포가 진행 중"

log "배포 시작 — 프론트 $VERSION ($SRC)"

install -d -m 755 "$PREV"
rsync -a --delete --checksum "$SITE/" "$PREV/"
log "지금 사이트를 $PREV 로 보관"

rollback() {
  log "되돌림 — $PREV 로"
  rsync -a --delete --checksum "$PREV/" "$SITE/"
}

rsync -a --chown=root:root --chmod=D755,F644 --exclude=/index.html "$SRC/" "$SITE/"
# 이번 빌드에 든 assets 는 시각을 지금으로 — 6 의 정리가 지금 쓰는 파일을 지우지 않게
(cd "$SRC" && find assets -type f -print0) | (cd "$SITE" && xargs -0 -r touch)
log "index.html 을 뺀 새 파일을 넣음 (옛 assets 는 남김)"

install -m 644 -o root -g root "$SRC/index.html" "$TMP_INDEX"
mv -f "$TMP_INDEX" "$SITE/index.html"
log "index.html 을 바꿈"

got=$(mktemp)
if ! curl -fsS --max-time 15 -o "$got" "$URL/" || ! cmp -s "$got" "$SITE/index.html"; then
  rm -f "$got"
  rollback
  die "$URL/ 이 새 index.html 을 내주지 않음"
fi
asset=$(grep -oE '/assets/[^"]+\.js' "$got" | head -1 || true)
rm -f "$got"
if [ -n "$asset" ] && ! curl -fsS --max-time 15 -o /dev/null "$URL$asset"; then
  rollback
  die "새 index.html 이 부르는 $asset 가 열리지 않음"
fi
log "확인 — $URL/ 이 새 index.html · ${asset:-assets 줄 없음}"

find "$SITE/assets" -type f -mtime +"$KEEP_DAYS" -delete
log "assets 에서 ${KEEP_DAYS}일 넘게 안 바뀐 파일을 정리"
log "배포 끝 — 프론트 $VERSION"
