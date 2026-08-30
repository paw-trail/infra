# infra

함께하개(paw-trail)의 로컬 개발 인프라를 띄우는 저장소입니다. Kafka, Redis, 관측 스택을 Docker Compose 한 벌로 관리하며, 도메인 서비스는 여기서 띄우지 않고 각자 IntelliJ에서 실행합니다.

**PostgreSQL은 평소에 띄우지 않습니다.** 팀 공용 인스턴스가 AWS EC2에 하나 있고 모두 그것을 사용합니다. 수집 API에 하루 호출 제한이 있어 데이터를 채우는 데 여러 날이 걸리고, 추출 배치는 GPU를 요구해 각자 재현할 수 없기 때문입니다. Compose에 PostgreSQL이 들어 있지만 `db` 프로파일로 분리해 두었으며, 독립된 데이터베이스가 필요할 때만 켭니다.

Kafka와 Redis를 각자 로컬에 두는 이유는 반대입니다. 공용으로 쓰면 한 사람이 발행한 이벤트를 다른 사람의 컨슈머가 가져가 버려 서로의 테스트가 섞입니다.

이 저장소에는 자바 코드가 없습니다. Compose 파일, 초기화 스크립트, 관측 도구 설정만 들어 있습니다.

---

## 1. 사전 준비

### 1-1. Docker Desktop

WSL2 백엔드로 설치합니다. Hyper-V 백엔드는 느리고 `host.docker.internal` 동작이 달라 관측 스택이 서비스를 찾지 못합니다.

설치 후 **Settings → Resources → WSL integration** 에서 다음을 확인합니다.

```
Enable integration with my default WSL distro    체크 해제
Ubuntu (또는 설치된 배포판)                        토글 OFF
```

도커 엔진은 `docker-desktop` 전용 배포판에서 동작하므로 이 항목을 꺼도 PowerShell의 `docker` 명령에는 영향이 없습니다. 켜 두면 통합 실패 팝업이 반복되며 데몬 통신이 막히는 문제가 발생합니다.

**Settings → General** 의 `Use the WSL 2 based engine` 은 켜 둡니다.

### 1-2. 저장소 클론

```powershell
git clone https://github.com/paw-trail/infra.git
cd infra
```

---

## 2. 최초 실행

### 2-1. 환경 변수 파일 생성

`.env` 는 저장소에 포함되지 않으므로 각자 만들어야 합니다.

```powershell
copy .env.example .env      # Windows
cp .env.example .env        # macOS
```

`.env` 를 열어 `CHANGE_ME` 로 표시된 값을 채웁니다.

```properties
POSTGRES_PASSWORD=CHANGE_ME
SERVICE_DB_PASSWORD=CHANGE_ME
GRAFANA_PASSWORD=CHANGE_ME
```

값에 따옴표를 붙이거나 끝에 공백을 두지 않습니다. 그대로 값의 일부가 되어 접속이 실패합니다.

### 2-2. 설정 검사

컨테이너를 띄우지 않고 Compose 파일의 문법과 변수 치환만 확인합니다.

```powershell
docker compose config
```

서비스 8개가 출력되면 정상입니다. `services: {}` 만 나오면 `.env` 의 `COMPOSE_PROFILES` 를 확인합니다(7절 참고).

### 2-3. 컨테이너 기동

```powershell
docker compose up -d
docker compose ps
```

`kafka` 와 `redis` 는 `Up (healthy)` 가 될 때까지 기다립니다. Kafka는 최초 기동 시 저장소를 포맷하므로 30초 정도 걸립니다.

PostgreSQL은 뜨지 않습니다. `db` 프로파일에 있기 때문이며 의도된 동작입니다. 로컬 데이터베이스가 필요한 경우는 6절을 참고합니다.

### 2-4. Kafka 토픽 생성

토픽은 자동 생성이 꺼져 있으므로 스크립트로 만듭니다.

```powershell
docker compose exec kafka bash /opt/scripts/create-topics.sh
```

호스트 셸이 아니라 컨테이너 안에서 실행하는 스크립트입니다. PowerShell은 `.sh` 파일을 직접 실행하지 못하므로, 이 방식이어야 Windows와 macOS에서 같은 명령을 사용할 수 있습니다.

토픽 10개(도메인 이벤트 5개 + DLQ 5개)가 생성되고 목록이 출력되면 완료입니다.

### 2-5. 확인

| 확인 대상 | 주소 | 기대 결과 |
|---|---|---|
| Kafka UI | http://localhost:9000 | 토픽 10개 |
| Prometheus | http://localhost:9090/targets | `prometheus`, `loki` 가 UP |
| Grafana | http://localhost:3000 | 데이터소스 3개 등록 |
| Zipkin | http://localhost:9411 | 화면 로딩 |

Prometheus의 `spring-services` 타깃은 서비스를 실행하기 전까지 DOWN입니다. 정상입니다.

오류 메시지가 `connect: connection refused` 라면 주소를 올바르게 찾은 뒤 연결만 실패한 것이므로 서비스를 실행하면 UP으로 바뀝니다. `no such host` 라면 주소 해석 단계에서 실패한 것이므로 설정을 확인해야 합니다.

---

## 3. 프로파일

Compose 파일은 한 벌이고, 켤 컨테이너는 프로파일로 고릅니다. 개발용과 배포용으로 파일을 나누지 않는 이유는 두 벌이 되는 순간 한쪽만 고쳐 두 파일이 서로 어긋나기 때문입니다. 배포용 차이가 커지면 파일을 복사하지 말고 override 파일(`-f base -f prod`)로 차이만 적습니다.

| 프로파일 | 구성 | 언제 켜는가 | 상태 |
|---|---|---|---|
| `infra` | kafka, redis | 거의 항상 | 구현 완료 |
| `tools` | kafka-ui | 토픽에 메시지가 실렸는지 확인할 때 | 구현 완료 |
| `observability` | prometheus, loki, zipkin, grafana | 로그·메트릭·추적을 볼 때 | 구현 완료 |
| `db` | postgres | **독립된 데이터베이스가 필요할 때만** | 구현 완료 |
| `platform` | gateway-server, eureka-server, config-server | 게이트웨이를 거친 호출을 확인할 때 | 해당 저장소 완성 후 추가 |
| `edge` | nginx | 프론트엔드와 함께 확인할 때 | 프론트엔드 통합 시 추가 |
| `pipeline` | ingest, extract | 수집·추출 배치를 돌릴 때만 | 해당 저장소 완성 후 추가 |
| `app` | 도메인 서비스 14개 | 배포 검증 때만 | 배포 검증 시 추가 |

`.env` 의 `COMPOSE_PROFILES` 가 기본 조합을 정합니다.

```properties
COMPOSE_PROFILES=infra,tools,observability
```

**여기에 `db` 가 없는 것은 의도입니다.** 평소에는 공용 PostgreSQL을 사용하므로 로컬 인스턴스가 함께 뜨면 어느 쪽에 연결되었는지 헷갈립니다.

다른 조합이 필요하면 명령에 직접 지정합니다. 이 경우 `.env` 값보다 우선합니다.

```powershell
docker compose --profile db up -d
```

프로파일 라벨이 없는 서비스는 어떤 프로파일을 켜든 항상 뜹니다. 컨테이너를 추가할 때 `profiles:` 를 빠뜨리지 않습니다.

---

## 4. 구성 요소

### 4-1. 포트

| 서비스 | 포트 | 비고 |
|---|---|---|
| PostgreSQL | 5432 | |
| Kafka | 9092 | 컨테이너 간 통신용 |
| Kafka | 29092 | **호스트에서 접속할 때 사용합니다** |
| Redis | 6379 | |
| Kafka UI | 9000 | 컨테이너 내부는 8080 |
| Prometheus | 9090 | |
| Grafana | 3000 | |
| Loki | 3100 | |
| Zipkin | 9411 | |

IntelliJ에서 실행하는 서비스는 Kafka에 **29092** 로 접속해야 합니다.

Kafka 브로커는 접속한 클라이언트에게 "다음부터는 이 주소로 오라"는 응답을 되돌려줍니다. 9092로 접속하면 `kafka:9092` 를 받는데, 이 이름은 도커 네트워크 안에서만 해석되므로 호스트에서 실행 중인 서비스는 그 주소로 다시 연결하지 못합니다. 그래서 호스트용 리스너를 따로 두고 `localhost:29092` 를 되돌려주도록 구성했습니다.

컨트롤러용 리스너(9093)도 있지만 밖으로 열지 않습니다. Kafka 내부 합의에만 쓰이며 클라이언트가 접속하는 대상이 아닙니다.

컨테이너 이름은 `pawtrail-` 접두사로 고정해 두었습니다. 여러 프로젝트를 함께 돌릴 때 구분하기 위해서입니다. 다만 이름을 고정하면 같은 서비스를 여러 개 띄울 수 없으므로, 인스턴스를 늘려야 하는 서비스를 추가할 때는 `container_name` 을 빼야 합니다.

### 4-2. 데이터베이스

평소에는 공용 인스턴스를 사용하지만, 초기화 스크립트는 이 저장소가 관리합니다. 공용 인스턴스를 다시 세울 때도 같은 스크립트를 사용하므로 `db` 프로파일과 `init-db/` 를 함께 두었습니다.

`init-db/01-databases.sh` 가 최초 기동 시 데이터베이스 10개와 전용 계정 10개를 만듭니다.

| 데이터베이스 | 계정 | 소유 서비스 |
|---|---|---|
| auth_db | auth_svc | auth |
| user_db | user_svc | user |
| pet_db | pet_svc | pet |
| place_db | place_svc | place |
| policy_db | policy_svc | policy |
| search_db | search_svc | search |
| raw_db | ingest_svc | ingest |
| report_db | report_svc | report |
| review_db | review_svc | review |
| notif_db | notif_svc | notification |

각 데이터베이스는 `REVOKE CONNECT ... FROM PUBLIC` 으로 보호되어 있어 다른 서비스 계정으로는 접속할 수 없습니다. 권한 상태는 다음으로 확인합니다.

```powershell
docker exec pawtrail-postgres psql -U pawtrail -d postgres -c "\l"
```

`Access privileges` 열이 아래와 같이 나오면 격리가 적용된 것입니다. `=` 왼쪽이 비어 있는 항목이 PUBLIC이며, 거기에 `c`(CONNECT)가 없어야 합니다.

```
 auth_db | =T/pawtrail            +
         | pawtrail=CTc/pawtrail  +
         | auth_svc=CTc/pawtrail
```

`search_db` 와 `place_db` 에는 PostGIS가, `search_db` 에는 `pg_trgm` 이 설치되어 있습니다. PostGIS는 슈퍼유저 권한이 필요해 서비스 계정의 마이그레이션으로는 만들 수 없으므로 초기화 단계에서 처리합니다.

초기화 스크립트를 `.sql` 이 아니라 `.sh` 로 둔 이유는 비밀번호를 환경 변수로 받기 위해서입니다. `.sql` 은 변수 치환이 되지 않아 값을 파일에 직접 적어야 하는데, 그러면 `.env` 를 고쳐도 계정 비밀번호는 그대로 남아 두 값이 갈립니다. 접속만 실패하고 파일을 눈으로 보면 맞아 보이는 형태가 되므로 원인을 찾기 어렵습니다.

```bash
CREATE USER ${role} WITH PASSWORD '${SERVICE_DB_PASSWORD}';
```

`.sh` 파일에 실행 권한을 줄 필요는 없습니다. PostgreSQL 이미지는 `/docker-entrypoint-initdb.d` 의 스크립트에 실행 권한이 있으면 실행하고, 없으면 현재 셸에서 읽어 들입니다. Windows에서 파일 권한이 보존되지 않아도 문제가 되지 않습니다.

### 4-3. Kafka 토픽

| 토픽 | 발행 | 소비 |
|---|---|---|
| place.updated | place | search |
| policy.changed | policy | notification, verdict |
| pet.profile.updated | pet | verdict |
| account.withdrawn | auth | user, pet, report, review, notification |
| report.reviewed | report | notification |

각 토픽에는 `{토픽}.dlq` 가 함께 생성되어 있습니다. 재시도 후에도 처리에 실패한 메시지가 이곳으로 이동합니다.

토픽 자동 생성(`auto.create.topics.enable`)은 꺼 두었고 스크립트로만 만듭니다. 켜 두면 컨슈머의 토픽명 오타가 조용히 빈 토픽을 만들어, 발행은 되는데 소비만 되지 않는 상태가 됩니다. 오류가 나지 않으므로 원인을 찾기 어렵습니다.

토픽 이름에는 `_` 를 쓰지 않습니다. Kafka가 JMX 메트릭 이름에서 `.` 과 `_` 를 같게 취급하므로 두 표기가 섞이면 메트릭이 충돌합니다.

### 4-4. 관측 스택

Prometheus는 `prometheus/prometheus.yml` 의 타깃을 수집합니다. 서비스 타깃이 `host.docker.internal` 로 되어 있는 이유는 서비스가 IntelliJ에서 실행되기 때문입니다. Prometheus 컨테이너 입장에서 `localhost` 는 자기 자신이므로 그 주소로는 서비스를 찾지 못합니다.

서비스를 추가하면 `scrape_configs` 의 `static_configs` 에 블록을 하나 더 넣습니다. 타깃마다 `labels` 를 붙여 두었으므로 Grafana에서 `application` 으로 서비스를 구분할 수 있습니다. 주소만 나열하면 어느 메트릭이 어느 서비스 것인지 구분되지 않습니다.

```yaml
  - job_name: spring-services
    metrics_path: /actuator/prometheus
    static_configs:
      - targets:
          - "host.docker.internal:8888"
        labels:
          application: config-server

      - targets:                              # 이렇게 블록째 추가합니다
          - "host.docker.internal:8084"
        labels:
          application: place-service
```

`metrics_path` 를 바꾸는 것을 잊지 않습니다. 기본값은 `/metrics` 인데 액추에이터의 경로는 `/actuator/prometheus` 라서, 그대로 두면 404만 받고 **오류 없이 아무것도 수집되지 않습니다.**

Grafana 데이터소스 3개는 `grafana/provisioning/datasources/datasources.yml` 로 자동 등록됩니다. 컨테이너를 다시 만들어도 같은 상태로 뜹니다.

Loki에는 애플리케이션이 직접 로그를 보냅니다. 공통 모듈의 logback appender가 그 역할을 하며, 인프라 쪽에는 수집 에이전트가 없습니다.

도커 로그 드라이버나 별도 수집 에이전트를 두지 않은 이유는 도메인 서비스가 IntelliJ에서 실행되기 때문입니다. 둘 다 컨테이너의 출력을 모으는 방식이라 컨테이너 밖에서 도는 프로세스의 로그는 잡지 못합니다. 애플리케이션이 직접 보내면 실행 위치와 무관하게 같은 경로로 동작합니다.

---

### 4-5. 데이터 보존

볼륨을 잡아 둔 것은 PostgreSQL뿐입니다. Kafka, Redis, Loki, Zipkin, Grafana는 컨테이너를 다시 만들면 내용이 사라집니다.

로컬에서 지난 메시지나 트레이스를 다시 볼 일이 없고, 검증할 때는 오히려 깨끗한 상태로 시작하는 편이 낫기 때문입니다. Kafka의 경우 이미지가 비루트 사용자로 동작해 빈 볼륨을 마운트하면 디렉터리가 root 소유로 만들어져 브로커가 기동에 실패한다는 문제도 있습니다.

대신 **Compose를 다시 실행해 Kafka 컨테이너가 새로 만들어지면 토픽이 사라집니다.** 토픽 생성 스크립트는 여러 번 실행해도 안전하므로 다시 돌리면 됩니다(7절 참고).

---

## 5. 자주 쓰는 명령

```powershell
# 기동 및 중지
docker compose up -d
docker compose stop
docker compose down

# 상태 확인
docker compose ps
docker compose logs -f kafka

# 토픽 재생성 (멱등하므로 여러 번 실행해도 안전합니다)
docker compose exec kafka bash /opt/scripts/create-topics.sh

# 로컬 데이터베이스가 필요할 때
docker compose --profile db up -d
docker exec -it pawtrail-postgres psql -U pawtrail -d raw_db

# 로컬 데이터베이스 내리기
docker compose --profile db down
```

`db` 프로파일로 띄운 컨테이너는 `docker compose down` 만으로는 내려가지 않습니다. 활성 프로파일에 포함되지 않아 Compose가 대상으로 잡지 않기 때문이며, `--profile db` 를 함께 지정하거나 `docker rm -f pawtrail-postgres` 로 직접 제거합니다.

데이터를 포함해 완전히 초기화하려면 볼륨까지 지웁니다. 로컬 데이터베이스의 내용이 전부 사라집니다.

```powershell
docker compose --profile db down -v
```

`docker compose` 명령은 `docker-compose.yml` 이 있는 디렉터리에서만 동작합니다. 다른 저장소 폴더에서 컨테이너를 다루려면 `docker exec pawtrail-postgres ...` 처럼 컨테이너 이름을 직접 사용합니다.

---

## 6. 서비스를 연결할 때

**접속 주소는 서비스 저장소가 아니라 `paw-trail/config` 저장소에 있습니다.** 각 서비스의 `application.yml` 에는 세 줄만 있고, 나머지는 설정 서버가 내려줍니다. 아래는 그중 이 저장소와 관련된 값들이며, 어디에 적혀 있는지를 함께 표시했습니다.

```
config/application-local.yml    app.datasource.host              ${DB_HOST}
                                spring.kafka.bootstrap-servers   localhost:29092
                                spring.data.redis.host           localhost

config/<서비스명>.yml            spring.datasource.url            jdbc:postgresql://${app.datasource.host}:5432/<서비스>_db
                                spring.datasource.username       <서비스>_svc

config/application.yml          spring.datasource.password       ${SERVICE_DB_PASSWORD}
```

데이터베이스 주소를 한 곳에만 적는 이유는, 장애로 데이터베이스를 승격했을 때 **`app.datasource.host` 한 줄만 고치면 모든 서비스가 따라오기 때문**입니다. 서비스마다 전체 주소를 적어 두면 열네 곳을 고쳐야 합니다.

Kafka는 반드시 **29092** 를 사용합니다. 9092는 컨테이너끼리 쓰는 주소입니다.

### IntelliJ 실행 구성에 넣는 환경 변수

```
DB_HOST                 팀에서 전달받은 공용 인스턴스 주소
SERVICE_DB_PASSWORD     .env 에 넣은 값과 같은 값
```

**`SERVICE_DB_PASSWORD` 는 이 저장소의 `.env` 에 넣은 값과 같아야 합니다.** 계정을 만들 때 쓰는 값과 접속할 때 쓰는 값이 같은 것이므로 이름도 같게 두었습니다.

`.env` 는 Docker Compose 가 읽는 파일이므로, IntelliJ 로 띄우는 서비스에는 실행 구성의 Environment variables 칸에 직접 넣어야 합니다.

공용 인스턴스에 접속하려면 본인의 공인 IP가 보안그룹에 등록되어 있어야 합니다. 회선이 바뀌거나 공인 IP가 갱신되면 다시 등록해야 하므로, 접속이 갑자기 되지 않을 때 이 부분을 먼저 확인합니다.

### 로컬 데이터베이스를 쓰는 경우

공용 인스턴스를 건드리지 않고 실험하거나, 마이그레이션을 처음부터 적용해 보고 싶을 때는 로컬 인스턴스를 띄웁니다.

```powershell
docker compose --profile db up -d
docker compose exec kafka bash /opt/scripts/create-topics.sh   # 필요한 경우
```

이때는 `DB_HOST` 만 바꾸면 됩니다. 설정 파일을 고칠 필요 없이 실행 구성의 환경 변수로 덮어씁니다.

```
DB_HOST                    localhost
```

**작업이 끝나면 로컬 인스턴스를 내립니다.** 두 인스턴스가 함께 떠 있으면 어느 쪽에 연결되었는지 헷갈립니다.

### 관측 스택 연결

로그를 Loki로 보내려면 `SPRING_PROFILES_ACTIVE=dev` 를 실행 구성의 환경 변수에 추가합니다. 지정하지 않으면 `local` 로 동작하며 로그는 콘솔에만 출력됩니다.

메트릭과 추적은 프로파일과 무관하게 항상 전송됩니다. Prometheus는 서비스의 `/actuator/prometheus` 를 직접 수집하고, 추적은 애플리케이션이 Zipkin으로 보냅니다.

---

## 7. 트러블슈팅

### `docker compose config` 결과가 `services: {}` 입니다

정상 동작입니다. 모든 서비스에 프로파일 라벨이 붙어 있는데 활성 프로파일이 하나도 없으면 매칭되는 서비스가 없습니다.

`.env` 파일이 있는지, `COMPOSE_PROFILES` 값이 채워져 있는지 확인합니다. `"POSTGRES_USER" variable is not set` 경고가 함께 나온다면 `.env` 가 없는 것입니다.

### 애플리케이션 로그에 `UNKNOWN_TOPIC_OR_PARTITION` 이 반복됩니다

`docker compose up -d` 로 Kafka 컨테이너가 다시 만들어지면서 토픽이 사라진 상태입니다. 다른 서비스를 추가하려고 명령을 다시 실행한 것만으로도 발생합니다.

토픽 생성 스크립트를 다시 실행하면 해결됩니다. 애플리케이션을 재시작할 필요는 없습니다. 컨슈머가 메타데이터를 계속 조회하고 있어 토픽이 생기는 즉시 연결됩니다.

```powershell
docker compose exec kafka bash /opt/scripts/create-topics.sh
```

이 메시지는 `ERROR` 가 아니라 `WARN` 으로 출력되므로 놓치기 쉽습니다.

### PostgreSQL이 뜨지 않습니다

`db` 프로파일에 있으므로 `docker compose up -d` 만으로는 뜨지 않습니다. 의도된 동작이며, 평소에는 공용 인스턴스를 사용합니다.

로컬 인스턴스가 필요하다면 프로파일을 지정합니다.

```powershell
docker compose --profile db up -d
```

### 데이터베이스가 만들어지지 않았습니다

`init-db/` 의 스크립트는 데이터 디렉터리가 비어 있을 때만 실행됩니다. 볼륨이 남아 있으면 스크립트를 고쳐도 반영되지 않습니다.

```powershell
docker compose --profile db down -v
docker compose --profile db up -d
```

`-v` 는 로컬 PostgreSQL 데이터를 전부 삭제합니다. 공용 인스턴스에는 영향이 없습니다.

### Flyway가 `Detected applied migration not resolved locally` 로 실패합니다

데이터베이스 이력에는 마이그레이션이 적용되어 있는데 클래스패스에서 해당 스크립트를 찾지 못한 상태입니다. 공통 모듈 jar가 의존성에서 빠졌을 때 발생합니다.

애플리케이션 로그에 `Found 0 JPA repository interfaces` 가 함께 나오면 같은 원인입니다. 정상이라면 2개가 잡힙니다.

```powershell
./gradlew dependencies --configuration runtimeClasspath | findstr pawtrail
```

공통 모듈이 나오지 않으면 `GPR_USER` 와 `GPR_TOKEN` 환경 변수를 확인하고 IntelliJ의 Gradle 창에서 새로고침합니다.

### Kafka UI에서 오프셋을 리셋할 수 없습니다

`Group's offsets can be reset only if group is inactive` 메시지가 나오면 컨슈머가 아직 연결되어 있는 상태입니다.

애플리케이션을 중지하고 세션 타임아웃(기본 45초)이 지날 때까지 기다립니다. Consumers 화면에서 해당 그룹이 `EMPTY` 로 바뀌면 리셋할 수 있습니다.

### Grafana 좌측에 Connections 메뉴가 없습니다

로그인하지 않은 상태입니다. 익명 열람이 켜져 있으나 Viewer 권한이므로 데이터소스 메뉴가 보이지 않습니다.

우측 상단 `Sign in` 을 눌러 `.env` 의 `GRAFANA_USER` 와 `GRAFANA_PASSWORD` 로 로그인합니다.

### `docker compose up -d` 가 Starting 에서 멈춰 있습니다

`docker compose ps` 가 빈 목록을 반환하고 `docker ps -a` 로는 컨테이너가 `Created` 상태로 보인다면 Docker Desktop의 WSL 통합 실패입니다. `docker rm -f` 나 `stop` 도 응답하지 않습니다.

조회 명령은 동작하는데 상태를 바꾸는 명령만 멈추는 것이 이 문제의 특징입니다.

해결 순서는 다음과 같습니다.

```powershell
# 1. 실행 중인 명령을 Ctrl+C 로 중단합니다
# 2. WSL 을 내립니다
wsl --shutdown

# 3. 그래도 멈춰 있으면 프로세스를 종료합니다
Get-Process *docker* | Stop-Process -Force
wsl --shutdown

# 4. Docker Desktop 을 다시 실행합니다
```

다시 실행한 뒤 **Settings → Resources → WSL integration** 에서 배포판 통합을 끕니다(1-1절 참고). 이 설정을 끄지 않으면 팝업이 반복되며 같은 상태로 돌아갑니다.

문제가 계속되면 범위를 좁힙니다.

```powershell
docker run --rm hello-world                                   # 도커 자체
docker run --rm -v C:\Tour_Prj\infra\init-db:/t:ro alpine ls /t   # 볼륨 마운트
docker compose up -d                                          # 이 저장소
```

첫 번째에서 실패하면 Compose 파일과 무관한 문제입니다.

---

## 8. 환경별 주의사항

### Windows

**줄바꿈** — 저장소에 `.gitattributes` 가 있어 모든 텍스트 파일이 LF로 유지됩니다. 셸 스크립트가 CRLF로 저장되면 컨테이너 안에서 `exec ...: no such file or directory` 로 실패하며, 파일이 분명히 존재하는데 없다고 나오므로 원인을 찾기 어렵습니다.

작업 파일의 상태는 다음으로 확인합니다. `i/` 는 저장소, `w/` 는 디스크입니다.

```powershell
git ls-files --eol
```

전부 `i/lf w/lf` 여야 합니다. `w/crlf` 가 보이면 아래로 정리합니다. 커밋하지 않은 변경은 사라지므로 반드시 커밋 후에 실행합니다.

```powershell
git rm --cached -r .
git reset --hard
```

**편집기** — 이 저장소의 파일은 IntelliJ로 편집합니다. 메모장으로 만든 셸 스크립트는 CRLF, BOM, `.txt` 확장자 자동 부착 세 가지 문제가 모두 같은 오류 메시지로 나타나 구분되지 않습니다. 저장소에 `.editorconfig` 가 있어 IntelliJ는 별도 설정 없이 LF로 저장합니다.

### macOS (Apple Silicon)

`postgis/postgis` 이미지는 amd64만 제공하므로 Compose에 `platform: linux/amd64` 를 명시해 두었습니다. 에뮬레이션으로 동작하며 로컬 개발에는 지장이 없습니다.

평소 개발에서는 PostgreSQL을 로컬에 띄우지 않고 공용 인스턴스를 사용하므로 영향이 적습니다. Testcontainers를 사용하는 통합 테스트에서만 에뮬레이션 속도를 체감할 수 있습니다.

나머지 이미지(Kafka, Redis, Prometheus, Grafana, Loki, Zipkin, Kafka UI)는 arm64를 지원합니다.

---

## 9. 디렉터리 구조

```
infra/
├── docker-compose.yml       한 벌, 프로파일 8개로 구성을 고릅니다
├── .env.example             복사해 .env 로 사용합니다
├── .gitattributes           줄바꿈 규칙
├── .editorconfig            편집기 규칙
├── init-db/                 db 프로파일과 공용 인스턴스 구축에 모두 사용합니다
│   ├── 01-databases.sh      데이터베이스 10개와 전용 계정 생성
│   └── 02-extensions.sh     PostGIS, pg_trgm 설치
├── kafka/
│   └── create-topics.sh     토픽 5개와 DLQ 5개 생성
├── prometheus/
│   └── prometheus.yml       수집 타깃
└── grafana/
    └── provisioning/
        └── datasources/
            └── datasources.yml   데이터소스 자동 등록
```
