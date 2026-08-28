#!/bin/bash
# =============================================================================
# 서비스별 데이터베이스와 전용 계정 생성
# =============================================================================
# 이 스크립트는 PostgreSQL 컨테이너가 데이터 디렉터리가 비어 있는 상태로 처음
# 기동할 때 한 번만 실행됨
# 이미 볼륨이 있으면 실행되지 않으므로 스크립트를 고친 뒤 다시 적용하려면 볼륨을 지워야 함
#
#   docker compose down -v && docker compose up -d
#   주의: -v 는 PostgreSQL 데이터를 전부 삭제함
#
# .sql 이 아니라 .sh 인 이유
#   비밀번호를 환경변수로 받기 위함임
#   .sql 은 변수 치환이 안 되므로 값을 파일에 직접 적어야 하는데 그러면 .env 를 고쳐도
#   계정 비밀번호는 안 바뀌어 두 값이 조용히 갈림
#   접속만 실패하고 눈으로 보면 맞아 보이는 형태가 됨
# =============================================================================

set -euo pipefail

: "${POSTGRES_USER:?POSTGRES_USER 가 필요함}"
: "${SERVICE_DB_PASSWORD:?SERVICE_DB_PASSWORD 가 필요함, .env 를 확인할 것}"

# 데이터베이스:소유 계정
# 서비스 17개 중 DB 를 소유한 10개임
#   verdict, congestion, route  무상태
#   extract                     Spring Batch 메타만 쓰고 별도 DB 없음
#   gateway, eureka, config     플랫폼
SERVICES=(
  "auth_db:auth_svc"
  "user_db:user_svc"
  "pet_db:pet_svc"
  "place_db:place_svc"
  "policy_db:policy_svc"
  "search_db:search_svc"
  "raw_db:ingest_svc"
  "report_db:report_svc"
  "review_db:review_svc"
  "notif_db:notif_svc"
)

for entry in "${SERVICES[@]}"; do
  db="${entry%%:*}"
  role="${entry##*:}"

  echo "[init-db] creating ${db} / ${role}"

  psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname postgres <<-EOSQL
    CREATE DATABASE ${db};
    CREATE USER ${role} WITH PASSWORD '${SERVICE_DB_PASSWORD}';

    -- PostgreSQL 은 기본적으로 PUBLIC 에 CONNECT 를 줌
    -- 이 줄이 없으면 auth_svc 가 place_db 에 그냥 접속할 수 있어 계정 격리가 성립하지 않음
    -- Database per Service 를 문서가 아니라 권한으로 강제하는 자리임
    REVOKE CONNECT ON DATABASE ${db} FROM PUBLIC;

    -- ALL PRIVILEGES 에 CONNECT / CREATE / TEMPORARY 가 포함됨
    GRANT ALL PRIVILEGES ON DATABASE ${db} TO ${role};
EOSQL

  # PostgreSQL 15 부터 public 스키마의 기본 CREATE 권한이 PUBLIC 에서 제거되었음
  # 이 줄이 없으면 Flyway 가 첫 마이그레이션에서 테이블을 만들지 못함
  psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${db}" <<-EOSQL
    GRANT ALL ON SCHEMA public TO ${role};
EOSQL
done

echo "[init-db] done: ${#SERVICES[@]} databases"
