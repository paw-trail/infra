#!/bin/bash
# =============================================================================
# Lightsail 앞단 nginx 를 설치 · 갱신함
# =============================================================================
# 같은 폴더의 파일을 제자리에 놓고, 검사를 통과하면 nginx 를 다시 읽힘
# 여러 번 돌려도 결과가 같음 (설정을 고친 뒤 다시 돌리면 갱신됨)
#
#   paw-trail.conf        → /etc/nginx/sites-available/paw-trail.conf (sites-enabled 에 연결)
#   grafana.conf          → /etc/nginx/sites-available/grafana.conf (sites-enabled 에 연결)
#                           grafana.paw-trail.click → WireGuard 터널 → 미니 PC 의 Grafana
#   cloudflare-realip.sh  → /usr/local/sbin/pawtrail-cloudflare-realip (실행해 대역 파일 둘을 만듦)
#   maintenance.html      → /var/www/paw-trail-maint/maintenance.html
#   frontend-deploy.sh    → /usr/local/sbin/pawtrail-frontend-deploy (Jenkins 프론트 배포)
#                           jenkins 계정이 sudo 로 부를 수 있는 것은 이 스크립트 하나 (/etc/sudoers.d/pawtrail-frontend-deploy)
#
# Ubuntu 기본 사이트(sites-enabled/default)는 지움
# 인증서(/etc/ssl/paw-trail)는 이 스크립트가 만들지 않음 — 먼저 있어야 함
#
# 쓰는 법   sudo bash install.sh
# =============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "sudo 로 실행할 것: sudo bash $0" >&2; exit 1; }
D=$(cd "$(dirname "$0")" && pwd)

for f in paw-trail.conf grafana.conf cloudflare-realip.sh maintenance.html frontend-deploy.sh; do
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
install -m 644 "$D/grafana.conf" /etc/nginx/sites-available/grafana.conf
ln -sfn /etc/nginx/sites-available/grafana.conf /etc/nginx/sites-enabled/grafana.conf
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx
echo "nginx 설치 · 갱신 끝"

# Jenkins 프론트 배포
#   Jenkins 가 아직 없으면 스크립트만 놓고 sudo 규칙은 건너뜀 (손 배포는 sudo 로 그대로 씀)
install -m 755 "$D/frontend-deploy.sh" /usr/local/sbin/pawtrail-frontend-deploy
if id jenkins >/dev/null 2>&1; then
  SUDOERS=$(mktemp)
  echo 'jenkins ALL=(root) NOPASSWD: /usr/local/sbin/pawtrail-frontend-deploy' > "$SUDOERS"
  visudo -cf "$SUDOERS" >/dev/null
  install -m 440 "$SUDOERS" /etc/sudoers.d/pawtrail-frontend-deploy
  rm -f "$SUDOERS"
  echo "프론트 배포 — pawtrail-frontend-deploy · jenkins 는 이 스크립트 하나만 sudo"
else
  echo "프론트 배포 — pawtrail-frontend-deploy (jenkins 계정이 없어 sudo 규칙은 건너뜀)"
fi
