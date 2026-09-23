#!/bin/bash
# =============================================================================
# 발행이 끝나고 30일이 지난 outbox 행을 서비스 DB 마다 지움
# =============================================================================
# outbox 는 paw-trail/common 이 서비스 DB 마다 만드는 표이며
# 발행한 뒤에도 행을 지우는 코드가 없어 그대로 쌓임
# 가입 이벤트(account.created)에는 이메일 · 닉네임이 실려 있어 탈퇴 뒤에도 사본이 남음
# 개인정보처리방침 3장 「서비스 운영 기록 — 30일 뒤 삭제」 가 이 스크립트에 걸려 있음
#
#   지우는 것   발행이 끝난 행(published_at 이 있음) 가운데 30일이 지난 것
#   두는 것     아직 발행하지 못한 행 — 관리자 재발행 화면이 씀
#
# 쓰는 법
#   sudo bash ops/outbox-cleanup.sh              지움
#   sudo bash ops/outbox-cleanup.sh --dry-run    지울 개수만 셈
#
# 서버에서는 pawtrail-outbox-cleanup.timer 가 매일 04:30 에 부름 (ops/install.sh 가 등록)
# 결과는 journalctl -u pawtrail-outbox-cleanup 으로 봄
# =============================================================================
set -euo pipefail

CONTAINER=pawtrail-postgres
DAYS=30
DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

# 컨테이너 안의 psql 로 부름 — 계정은 컨테이너 환경변수 POSTGRES_USER 를 씀
psql_in() {
  docker exec -i "$CONTAINER" sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -At "$@"' sh "$@"
}

WHERE="published_at IS NOT NULL AND published_at < now() - interval '${DAYS} days'"
total=0

for db in $(psql_in -d postgres -c "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate AND datname <> 'postgres' ORDER BY 1"); do
  if [ "$(psql_in -d "$db" -c "SELECT to_regclass('public.outbox') IS NOT NULL")" != "t" ]; then
    continue
  fi
  if $DRY_RUN; then
    n=$(psql_in -d "$db" -c "SELECT count(*) FROM outbox WHERE ${WHERE}")
    echo "${db}  지울 행 ${n}"
  else
    n=$(psql_in -d "$db" -c "WITH d AS (DELETE FROM outbox WHERE ${WHERE} RETURNING 1) SELECT count(*) FROM d")
    echo "${db}  지운 행 ${n}"
  fi
  total=$((total + n))
done

if $DRY_RUN; then
  echo "합계  지울 행 ${total} (발행 뒤 ${DAYS}일 지난 것 · 실제로 지우지 않음)"
else
  echo "합계  지운 행 ${total} (발행 뒤 ${DAYS}일 지난 것)"
fi
