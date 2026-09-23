#!/bin/bash
# =============================================================================
# Lightsail 앞단 nginx 를 설치 · 갱신함
# =============================================================================
# 같은 폴더의 파일을 제자리에 놓고, 검사를 통과하면 nginx 를 다시 읽힘
# 여러 번 돌려도 결과가 같음 (설정을 고친 뒤 다시 돌리면 갱신됨)
#
#   paw-trail.conf        → /etc/nginx/sites-available/paw-trail.conf (sites-enabled 에 연결)
#   cloudflare-realip.sh  → /usr/local/sbin/pawtrail-cloudflare-realip (실행해 대역 파일 둘을 만듦)
#   maintenance.html      → /var/www/paw-trail-maint/maintenance.html
#
# Ubuntu 기본 사이트(sites-enabled/default)는 지움
# 인증서(/etc/ssl/paw-trail)는 이 스크립트가 만들지 않음 — 먼저 있어야 함
#
# 쓰는 법   sudo bash install.sh
# =============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "sudo 로 실행할 것: sudo bash $0" >&2; exit 1; }
D=$(cd "$(dirname "$0")" && pwd)

for f in paw-trail.conf cloudflare-realip.sh maintenance.html; do
  [ -f "$D/$f" ] || { echo "$D/$f 가 없음" >&2; exit 1; }
done
if [ ! -f /etc/ssl/paw-trail/origin.pem ] || [ ! -f /etc/ssl/paw-trail/origin.key ]; then
  echo "인증서가 없음 (/etc/ssl/paw-trail/origin.pem · origin.key)" >&2
  exit 1
fi

install -d -m 755 /var/www/paw-trail /var/www/paw-trail-maint
install -m 644 "$D/maintenance.html" /var/www/paw-trail-maint/maintenance.html

# 프론트를 올리기 전에도 첫 화면이 나오게 자리만 채움
# 이미 있으면 건드리지 않음 (프론트 빌드를 올리면 덮어씀)
if [ ! -f /var/www/paw-trail/index.html ]; then
  cat > /var/www/paw-trail/index.html <<'HTML'
<!doctype html>
<html lang="ko">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>함께하개</title></head>
<body style="font-family: sans-serif; text-align: center; padding: 4rem 1rem;">함께하개가 곧 열려요.</body>
</html>
HTML
  chmod 644 /var/www/paw-trail/index.html
fi

install -m 755 "$D/cloudflare-realip.sh" /usr/local/sbin/pawtrail-cloudflare-realip
/usr/local/sbin/pawtrail-cloudflare-realip --no-reload

install -m 644 "$D/paw-trail.conf" /etc/nginx/sites-available/paw-trail.conf
ln -sfn /etc/nginx/sites-available/paw-trail.conf /etc/nginx/sites-enabled/paw-trail.conf
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx
echo "nginx 설치 · 갱신 끝"
