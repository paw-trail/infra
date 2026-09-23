#!/bin/bash
# =============================================================================
# Cloudflare 주소 대역을 받아 nginx 가 읽는 두 파일을 만듦
# =============================================================================
#   /etc/nginx/conf.d/cloudflare-realip.conf
#     이 대역에서 온 요청만 CF-Connecting-IP 를 진짜 사용자 IP 로 믿음
#     대역 밖에서 온 요청이 이 헤더를 보내도 무시됨 (IP 를 속일 수 없음)
#   /etc/nginx/snippets/cloudflare-ranges.inc
#     paw-trail.conf 의 geo 가 읽음 (Cloudflare 를 거쳐 온 요청인지 가림)
#
# 대역은 Cloudflare 가 가끔 바꾸므로 파일에 적어 두지 않고 받아 온 값으로 만듦
#   받은 목록이 비었거나 모양이 이상하면 옛 파일을 그대로 두고 멈춤
#   새 파일로 nginx -t 가 실패하면 옛 파일로 되돌림
#
# 쓰는 법
#   sudo pawtrail-cloudflare-realip              만들고 nginx 를 다시 읽힘
#   sudo pawtrail-cloudflare-realip --no-reload  만들기만 함 (install.sh 가 씀)
# =============================================================================
set -euo pipefail

REALIP=/etc/nginx/conf.d/cloudflare-realip.conf
RANGES=/etc/nginx/snippets/cloudflare-ranges.inc

[ "$(id -u)" -eq 0 ] || { echo "sudo 로 실행할 것" >&2; exit 1; }

v4=$(curl -fsS --max-time 15 https://www.cloudflare.com/ips-v4)
v6=$(curl -fsS --max-time 15 https://www.cloudflare.com/ips-v6)

# 한 줄에 대역 하나인 모양만 남김
v4=$(printf '%s\n' "$v4" | tr -d '\r' | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' || true)
v6=$(printf '%s\n' "$v6" | tr -d '\r' | grep -E '^[0-9a-f:]+/[0-9]{1,3}$' || true)
n4=$(printf '%s' "$v4" | grep -c . || true)
n6=$(printf '%s' "$v6" | grep -c . || true)

if [ "$n4" -lt 10 ] || [ "$n6" -lt 5 ]; then
  echo "대역 목록이 이상함 (IPv4 ${n4}개 · IPv6 ${n6}개) — 파일을 바꾸지 않음" >&2
  exit 1
fi

stamp=$(date '+%Y-%m-%d %H:%M')
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

{
  echo "# cloudflare-realip.sh 가 만듦 (${stamp}) · 손으로 고치지 말 것"
  printf '%s\n%s\n' "$v4" "$v6" | sed 's/^/set_real_ip_from /; s/$/;/'
  echo "real_ip_header CF-Connecting-IP;"
} > "$tmp/realip.new"

{
  echo "# cloudflare-realip.sh 가 만듦 (${stamp}) · 손으로 고치지 말 것"
  printf '%s\n%s\n' "$v4" "$v6" | sed 's/$/ 1;/'
} > "$tmp/ranges.new"

# 옛 파일을 챙겨 두고 새 파일로 바꾼 뒤 검사함
[ -f "$REALIP" ] && cp -p "$REALIP" "$tmp/realip.old"
[ -f "$RANGES" ] && cp -p "$RANGES" "$tmp/ranges.old"
install -d -m 755 "$(dirname "$RANGES")"
install -m 644 "$tmp/realip.new" "$REALIP"
install -m 644 "$tmp/ranges.new" "$RANGES"

if ! out=$(nginx -t 2>&1); then
  echo "$out" >&2
  if [ -f "$tmp/realip.old" ]; then install -m 644 "$tmp/realip.old" "$REALIP"; else rm -f "$REALIP"; fi
  if [ -f "$tmp/ranges.old" ]; then install -m 644 "$tmp/ranges.old" "$RANGES"; else rm -f "$RANGES"; fi
  echo "nginx -t 가 실패해 옛 파일로 되돌림" >&2
  exit 1
fi

echo "Cloudflare 대역 IPv4 ${n4}개 · IPv6 ${n6}개 → ${REALIP} · ${RANGES}"

if [ "${1:-}" != "--no-reload" ]; then
  systemctl reload nginx
  echo "nginx 를 다시 읽힘"
fi
