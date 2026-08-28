#!/bin/bash
# =============================================================================
# 토픽 생성
# =============================================================================
# 실행 (Windows PowerShell 과 macOS 동일)
#
#   docker compose exec kafka bash /opt/scripts/create-topics.sh
#
# 호스트 셸이 아니라 컨테이너 안에서 도는 스크립트임
# PowerShell 은 .sh 를 직접 실행하지 못하므로 이 방식이어야 두 사람이 같은 명령을 씀
#
# 멱등함(--if-not-exists)
# 여러 번 돌려도 안전하므로 compose 를 down 한 뒤 다시 올렸을 때 그냥 재실행하면 됨
#
# 자동 생성(auto.create.topics.enable)을 꺼둔 이유
#   켜두면 컨슈머의 토픽명 오타가 조용히 빈 토픽을 만들어 발행은 되는데 소비만 안 되는 상태가 됨
#   에러가 나지 않아 원인을 찾기가 매우 어려움
# =============================================================================

set -euo pipefail

BOOTSTRAP="${BOOTSTRAP:-localhost:9092}"
PARTITIONS="${PARTITIONS:-3}"
# 브로커가 1대이므로 복제본도 1 임
# 2 이상을 주면 생성이 실패함
REPLICATION="${REPLICATION:-1}"

KAFKA_BIN="/opt/kafka/bin"

# 도메인 이벤트 5개
#   place.updated        place  -> search                    색인 갱신
#   policy.changed       policy -> notification, verdict      조건 변경 알림, 판정 캐시 무효화
#   pet.profile.updated  pet    -> verdict                    판정 캐시 무효화
#   account.withdrawn    auth   -> user, pet, report, review, notification
#   report.reviewed      report -> notification               제보 처리 결과 통보
TOPICS=(
  "place.updated"
  "policy.changed"
  "pet.profile.updated"
  "account.withdrawn"
  "report.reviewed"
)

create_topic() {
  local name="$1"
  echo "[kafka] create ${name} (partitions=${PARTITIONS}, rf=${REPLICATION})"
  "${KAFKA_BIN}/kafka-topics.sh" \
    --bootstrap-server "${BOOTSTRAP}" \
    --create --if-not-exists \
    --topic "${name}" \
    --partitions "${PARTITIONS}" \
    --replication-factor "${REPLICATION}"
}

for topic in "${TOPICS[@]}"; do
  create_topic "${topic}"
  # DeadLetterPublishingRecoverer 가 재시도 3회 실패 후 여기로 보냄
  # 파티션 수를 원본과 맞춰야 원본 파티션 번호가 그대로 보존됨
  create_topic "${topic}.dlq"
done

echo
echo "[kafka] 생성된 토픽 목록"
"${KAFKA_BIN}/kafka-topics.sh" --bootstrap-server "${BOOTSTRAP}" --list
