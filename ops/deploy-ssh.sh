#!/bin/sh
# =============================================================================
# SSH 강제 명령 — Jenkins 의 배포 키로 들어오면 이것만 돎 (셸은 안 열림)
# =============================================================================
# authorized_keys 의 command= 가 이 파일을 가리킴 (ops/install.sh 가 씀)
# 요청한 명령(SSH_ORIGINAL_COMMAND)을 「<서비스> <판>」 두 단어로만 받아 검사한 뒤
# root 배포 스크립트 하나를 sudo 로 부름 — sudoers 에 허락된 것도 이 하나뿐
# 검사는 root 스크립트가 한 번 더 함
# =============================================================================
set -eu
set -f
# shellcheck disable=SC2086
set -- ${SSH_ORIGINAL_COMMAND:-}
if [ "$#" -ne 2 ]; then
  echo "쓰는 법: <서비스> <판>   예) weather-service v0.1.0" >&2
  exit 2
fi
case "$1" in
  ""|*[!a-z0-9-]*) echo "서비스 이름이 이상함" >&2; exit 2 ;;
esac
case "$2" in
  v*) ;;
  *) echo "판은 vX.Y.Z 모양이어야 함" >&2; exit 2 ;;
esac
exec sudo -n /usr/local/sbin/pawtrail-deploy "$1" "$2"
