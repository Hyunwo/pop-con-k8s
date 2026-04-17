# Kiali 사용 가이드

## 1. 접속

**URL**: `https://kiali.popcon.store`

로그인 창이 나오면 **Anonymous** 로 접속합니다.

---

## 2. 서비스 그래프 보기

1. 왼쪽 메뉴 → **Graph** 클릭
2. 상단 **Namespace** 드롭다운 → `popcon-prod` 선택
3. 상단 시간 범위 설정 (기본 Last 1m, 트래픽 확인 시 Last 1h 권장)

**Display 옵션** (우측 상단)에서 아래 항목을 켜두면 유용합니다:

| 옵션 | 효과 |
|---|---|
| `Traffic Distribution` | 각 연결선에 트래픽 비율 표시 |
| `Security` | mTLS 적용 여부 🔑 아이콘 표시 |
| `Virtual Services` | VirtualService 적용 여부 표시 |

---

## 3. 그래프 읽는 법

### 선 색상

| 색상 | 의미 |
|---|---|
| 초록색 | 정상 트래픽 |
| 노란색 | 에러 발생 중인 트래픽 |
| 빨간색 | 높은 에러율 |
| 파란색 | TCP 트래픽 (DB, Redis 등) |

### 노드 표시

| 표시 | 의미 |
|---|---|
| 삼각형 노드 | VirtualService가 있는 서비스 |
| 사각형 노드 | VirtualService 없는 서비스 |
| 🔑 아이콘 | mTLS 적용됨 |

### 외부 노드

| 노드명 | 의미 |
|---|---|
| `rds-mysql` | AWS RDS DB 연결 |
| `elasticache-redis` | AWS ElastiCache Redis 연결 |
| `PassthroughCluster` | ServiceEntry 미등록 외부 호출 |

---

## 4. 특정 서비스 상세 보기

그래프에서 노드 클릭 → 우측 상세 패널에서 확인

| 탭 | 내용 |
|---|---|
| **Traffic** | 인바운드/아웃바운드 트래픽 및 응답코드 상세 |
| **Logs** | 해당 서비스 로그 (Loki 연동) |
| **Traces** | Jaeger 분산 트레이싱으로 이동 |

---

## 5. 에러 트래픽 확인

1. 노란색/빨간색 선이 보이면 해당 연결선 클릭
2. 우측 패널 → **Traffic** 탭에서 에러 응답코드 확인
3. **Traces** 탭 → Jaeger로 이동해 상세 트레이스 확인

---

## 6. 알려진 경고 (무시해도 되는 것)

| 경고 | 이유 | 조치 |
|---|---|---|
| `KIA1317 - No Waypoint` | Ambient 모드 기준 경고 | 무시 (우리 프로젝트는 Sidecar 모드) |