#!/bin/bash
# =============================================================================
# 확장(extension) 설치
# =============================================================================
# 왜 여기서 만드는가
#   PostGIS 는 신뢰(trusted) 확장이 아니라 CREATE EXTENSION 에 슈퍼유저 권한이 필요함
#   서비스 전용 계정에는 그 권한이 없으므로 각 서비스의 Flyway 마이그레이션에서 만들 수 없음
#   슈퍼유저로 도는 init 스크립트가 유일하게 가능한 자리임
#
# 왜 .sh 인가
#   initdb 가 실행하는 .sql 은 기본 데이터베이스 하나만 대상으로 함
#   DB 가 10개라 대상을 지정해 돌려야 하므로 스크립트로 감쌌음
#
# 파일 이름이 02 인 이유
#   01 이 데이터베이스를 먼저 만들어야 여기서 접속할 수 있으며 사전순으로 실행됨
# =============================================================================

set -euo pipefail

: "${POSTGRES_USER:?POSTGRES_USER 가 필요함}"

# PostGIS 가 필요한 DB
#   search_db  search_index.geom (geography Point, GIST 인덱스) 로 거리 계산에 씀
#   place_db   장소 좌표를 공간 타입으로 다루게 될 경우를 대비해 미리 열어 둠
POSTGIS_DATABASES=(
  "search_db"
  "place_db"
)

for db in "${POSTGIS_DATABASES[@]}"; do
  echo "[init-db] enabling postgis on ${db}"
  psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${db}" <<-'EOSQL'
    CREATE EXTENSION IF NOT EXISTS postgis;
EOSQL
done

# 한글 부분 일치 검색용임
# 원래 후보는 pg_bigm(2글자 단위)이었으나 postgis 이미지에 포함돼 있지 않아 커스텀 이미지를 빌드해야 함
# 우선 기본 제공되는 pg_trgm(3글자 단위)을 넣어두고
# search 서비스를 구현할 때 정확도를 보고 커스텀 이미지 여부를 결정함
echo "[init-db] enabling pg_trgm on search_db"
psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "search_db" <<-'EOSQL'
  CREATE EXTENSION IF NOT EXISTS pg_trgm;
EOSQL

echo "[init-db] extensions done"
