# =============================================================================
# 함께하개 Jenkins agent — 데스크톱의 Docker Desktop 에서 도는 빌드용 컨테이너
# =============================================================================
# 담는 것   JDK 21 (바탕 이미지) · git (바탕 이미지) · docker CLI · buildx · Node 22
# 도커      엔진은 깔지 않고 호스트(Docker Desktop)의 소켓을 넘겨받아 씀
#           이미지 굽기(buildx 멀티아치)와 테스트의 Testcontainers 가 이 소켓을 씀
# 본체      http://10.8.0.1:8080/ 에 WebSocket 으로 붙음 (WireGuard 터널 안)
#
# 서비스들의 툴체인이 JDK 21 이라 바탕 이미지도 jdk21 을 씀
# Node 는 데스크톱 개발 환경과 같은 판으로 고정함
# =============================================================================
FROM jenkins/inbound-agent:jdk21

USER root

# docker CLI · buildx — 도커 공식 저장소에서 받음
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg xz-utils \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin \
 && rm -rf /var/lib/apt/lists/*

# Node 22 — 공식 배포본을 그대로 풀어 넣음
ARG NODE_VERSION=22.22.2
RUN curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    | tar -xJ -C /usr/local --strip-components=1 \
 && node -v \
 && npm -v

# root 로 둠 — 넘겨받은 도커 소켓이 root 전용이라 jenkins 사용자로는 못 씀
# 소켓을 쓸 수 있으면 어차피 호스트 도커 전체를 다룰 수 있으므로 사용자를 나눠도 막아 주는 것이 없음
USER root
