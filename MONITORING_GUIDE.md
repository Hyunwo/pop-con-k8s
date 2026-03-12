# 모니터링 가이드

> 환경: k3s(staging) → EKS(production) 순서로 구성
> 스택: Prometheus + Grafana + Loki (+ 추후 APM)

---

## 목차

1. [모니터링 기본 개념](#1-모니터링-기본-개념)
2. [k3s 환경에서 봐야 할 지표](#2-k3s-환경에서-봐야-할-지표)
3. [EKS 환경에서 봐야 할 지표](#3-eks-환경에서-봐야-할-지표)
4. [APM 도입 가이드](#4-apm-도입-가이드)
5. [Grafana 대시보드 활용법](#5-grafana-대시보드-활용법)
6. [알람 설정 가이드](#6-알람-설정-가이드)

---

## 1. 모니터링 기본 개념

### 모니터링의 4가지 황금 신호 (Google SRE)

| 신호 | 설명 | 예시 |
|---|---|---|
| **Latency** | 요청 처리 시간 | API 응답시간 p95 < 500ms |
| **Traffic** | 초당 요청 수 | RPS (Requests Per Second) |
| **Errors** | 에러율 | 5xx 응답 비율 < 1% |
| **Saturation** | 자원 포화도 | CPU 80% 이하, 메모리 85% 이하 |

### RED 방법론 (서비스 레벨)

- **R**ate: 초당 요청 수
- **E**rror: 에러율
- **D**uration: 응답시간

### USE 방법론 (인프라 레벨)

- **U**tilization: 사용률 (CPU, 메모리)
- **S**aturation: 포화도 (큐 대기, 스로틀링)
- **E**rrors: 에러 수

---

## 2. k3s 환경에서 봐야 할 지표

### 2-1. 노드 (EC2 인스턴스)

#### CPU
```promql
# 노드 CPU 사용률
100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```
- **임계값**: 80% 이상 지속 시 주의

#### 메모리
```promql
# 노드 메모리 사용률
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100
```
- **임계값**: 85% 이상 시 주의
- 현재 EC2: 7.7Gi → 6.5Gi 이상 사용 시 위험

#### 디스크
```promql
# 디스크 사용률
(1 - (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})) * 100
```
- **임계값**: 80% 이상 시 주의

#### 네트워크
```promql
# 네트워크 수신량 (bytes/sec)
rate(node_network_receive_bytes_total{device="eth0"}[5m])

# 네트워크 송신량 (bytes/sec)
rate(node_network_transmit_bytes_total{device="eth0"}[5m])
```

---

### 2-2. Pod / 컨테이너

#### Pod 상태
```promql
# 정상이 아닌 Pod 수
count(kube_pod_status_phase{phase!="Running", phase!="Succeeded"}) by (namespace, phase)
```
- Running, Succeeded 외의 상태(Pending, Failed, Unknown)가 있으면 확인 필요

#### 컨테이너 재시작 수
```promql
# 컨테이너 재시작 횟수 (1시간 내)
increase(kube_pod_container_status_restarts_total[1h])
```
- 1시간 내 재시작이 3회 이상이면 CrashLoopBackOff 가능성

#### 컨테이너 CPU
```promql
# 컨테이너별 CPU 사용률
rate(container_cpu_usage_seconds_total{namespace="popcon-staging"}[5m])
```

#### 컨테이너 메모리
```promql
# 컨테이너별 메모리 사용량
container_memory_working_set_bytes{namespace="popcon-staging"}
```
- `resources.limits.memory`에 가까워지면 OOMKill 위험

---

### 2-3. 서비스 (Spring Boot)

Spring Boot Actuator + Micrometer를 활성화하면 아래 지표 수집 가능.

#### 설정 방법 (백엔드 팀 작업 필요)

`build.gradle`에 추가:
```gradle
implementation 'org.springframework.boot:spring-boot-starter-actuator'
implementation 'io.micrometer:micrometer-registry-prometheus'
```

`application.yml`에 추가:
```yaml
management:
  endpoints:
    web:
      exposure:
        include: health, prometheus
  metrics:
    export:
      prometheus:
        enabled: true
```

#### HTTP 요청 지표
```promql
# API별 요청 수
rate(http_server_requests_seconds_count{namespace="popcon-staging"}[5m])

# API별 평균 응답시간
rate(http_server_requests_seconds_sum[5m])
/ rate(http_server_requests_seconds_count[5m])

# p95 응답시간
histogram_quantile(0.95, rate(http_server_requests_seconds_bucket[5m]))

# 에러율 (5xx)
rate(http_server_requests_seconds_count{status=~"5.."}[5m])
/ rate(http_server_requests_seconds_count[5m])
```

#### JVM 지표
```promql
# JVM 힙 메모리 사용량
jvm_memory_used_bytes{area="heap"}

# GC 횟수
rate(jvm_gc_pause_seconds_count[5m])

# GC 소요 시간
rate(jvm_gc_pause_seconds_sum[5m])
```
- GC가 자주 발생하면 힙 메모리 부족 신호

#### DB 커넥션 풀 (HikariCP)
```promql
# 활성 커넥션 수
hikaricp_connections_active

# 대기 중인 커넥션 수
hikaricp_connections_pending
```
- pending이 지속적으로 쌓이면 DB 병목 신호

---

### 2-4. 로그 (Loki)

Grafana Explore에서 확인.

#### 에러 로그 모니터링
```logql
# ERROR 레벨 로그
{namespace="popcon-staging"} |= "ERROR"

# 특정 Exception
{namespace="popcon-staging"} |= "Exception"

# 5xx 에러
{namespace="popcon-staging"} |= "500"
```

#### 서비스별 로그
```logql
# auth 서비스 로그
{namespace="popcon-staging", app="backend-auth"}

# user 서비스 로그
{namespace="popcon-staging", app="backend-user"}
```

---

### 2-5. k3s에서 주의할 점

- **Swap 없음**: 메모리 부족 시 바로 OOMKill 발생 → 메모리 지표 최우선
- **단일 노드**: 노드 장애 = 전체 서비스 장애 → 노드 상태 우선 확인
- **리소스 경합**: 모니터링 스택 자체도 메모리 소비 → 모니터링 Pod의 리소스도 함께 확인

---

## 3. EKS 환경에서 봐야 할 지표

k3s 지표에 **추가로** 봐야 할 것들입니다.

### 3-1. 클러스터 레벨

#### 노드 그룹
```promql
# 전체 노드 수
count(kube_node_info)

# 노드별 Pod 수
count(kube_pod_info) by (node)
```
- 노드 수가 갑자기 줄면 Scale-in으로 Pod 이동 중일 수 있음

#### HPA (Horizontal Pod Autoscaler)
```promql
# 현재 replicas vs 목표 replicas
kube_horizontalpodautoscaler_status_current_replicas
kube_horizontalpodautoscaler_status_desired_replicas
```
- desired가 current보다 높으면 스케일 아웃 진행 중

---

### 3-2. AWS 관리형 서비스 지표

CloudWatch에서 확인 (별도 설정 없이 자동 수집).

#### RDS

| 지표 | 임계값 | 조치 |
|---|---|---|
| CPUUtilization | 70% 이상 지속 | 인스턴스 업그레이드 검토 |
| DatabaseConnections | max_connections 80% | 커넥션 풀 설정 검토 |
| FreeStorageSpace | 20% 미만 | 스토리지 확장 |
| ReadLatency / WriteLatency | 100ms 이상 | 쿼리 최적화 or 읽기 복제본 추가 |

#### ALB (Application Load Balancer)

| 지표 | 설명 |
|---|---|
| RequestCount | 초당 요청 수 |
| TargetResponseTime | 응답시간 |
| HTTPCode_Target_5XX_Count | 5xx 에러 수 |
| HealthyHostCount | 정상 타겟 수 (0이면 장애) |

---

### 3-3. EKS 전환 시 추가할 것

- **Cluster Autoscaler 지표**: 스케일링 이벤트 모니터링
- **비용 모니터링**: Kubecost 또는 AWS Cost Explorer로 네임스페이스/서비스별 비용 추적
- **최신 Loki 차트**: loki-stack(deprecated) → loki 차트로 교체 (log volume 등 최신 기능)

---

## 4. APM 도입 가이드

### 4-1. APM이 필요한 시점

다음 중 하나라도 해당되면 도입 검토:
- 특정 API가 느린데 어느 코드/쿼리가 원인인지 모를 때
- 에러 발생 시 스택 트레이스를 로그에서 찾기 힘들 때
- 서비스 간 호출 흐름을 시각적으로 파악해야 할 때
- 실제 트래픽이 붙기 시작했을 때

### 4-2. 추천 스택: OpenTelemetry + Grafana Tempo

현재 Grafana를 사용 중이므로 가장 자연스러운 선택.

**구성도**
```
Spring Boot (OTel Java Agent)
    ↓ Traces (gRPC/OTLP)
Grafana Tempo (trace 저장)
    ↓
Grafana (Trace + Log 연결해서 조회)
```

**장점**
- Grafana에서 Log ↔ Trace 연결 조회 가능 (같은 요청의 로그와 트레이스를 한 화면에서)
- 벤더 종속 없음 (OpenTelemetry 표준)
- EKS에서도 동일한 설정 재사용 가능

### 4-3. APM에서 볼 수 있는 것

#### Trace (분산 추적) 예시
```
POST /auth/login (전체 800ms)
├── Spring Security 필터 (10ms)
├── UserRepository.findByEmail() (750ms) ← 여기가 병목!
│   └── SELECT * FROM users WHERE email = ?
└── JWT 생성 (40ms)
```

로그만 봤을 때는 "800ms 걸렸다"만 알 수 있지만,
APM을 쓰면 "DB 쿼리가 750ms"라는 것까지 알 수 있음.

### 4-4. 도입 시점 권장

| 시점 | 권장 |
|---|---|
| 지금 (k3s staging) | 보류 - 서비스 완성 우선, 메모리 부담 |
| 서비스 오픈 후 | 느린 API 발생 시 도입 검토 |
| EKS 전환 시 | Tempo + OTel agent 함께 구성 권장 |

---

## 5. Grafana 대시보드 활용법

### 5-1. 기본 제공 대시보드 (kube-prometheus-stack 자동 생성)

| 대시보드 | 용도 |
|---|---|
| Kubernetes / Compute Resources / Cluster | 클러스터 전체 리소스 |
| Kubernetes / Compute Resources / Namespace | 네임스페이스별 리소스 |
| Kubernetes / Compute Resources / Pod | Pod별 CPU/메모리 |
| Node Exporter / Full | 노드 상세 지표 |
| Kubernetes / Networking | 네트워크 트래픽 |

### 5-2. 추가 권장 대시보드

Grafana → Dashboards → Import → ID 입력으로 설치 가능.

| 대시보드 | ID | 용도 |
|---|---|---|
| Spring Boot Statistics | `12685` | API 응답시간, 에러율, JVM |
| JVM Micrometer | `4701` | GC, 힙 메모리, 스레드 |

### 5-3. Log + Metric 연계해서 보는 방법

1. Grafana → Explore → Split view 활성화
2. 왼쪽: Prometheus → 에러 급증 시점 확인
3. 오른쪽: Loki → 같은 시간대 `{namespace="popcon-staging"} |= "ERROR"` 조회
4. 두 화면의 시간 범위가 연동되어 원인 파악 용이

---

## 6. 알람 설정 가이드

### 6-1. 우선순위별 알람

#### Critical (즉시 대응)

| 조건 | PromQL |
|---|---|
| Pod CrashLoopBackOff | `increase(kube_pod_container_status_restarts_total[15m]) > 3` |
| 노드 다운 | `up{job="node-exporter"} == 0` |
| 5xx 에러율 5% 초과 | `rate(http_server_requests_seconds_count{status=~"5.."}[5m]) / rate(http_server_requests_seconds_count[5m]) > 0.05` |
| 메모리 90% 초과 | `(1 - node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes) > 0.9` |

#### Warning (30분 내 대응)

| 조건 | PromQL |
|---|---|
| CPU 80% 초과 5분 지속 | `avg(rate(node_cpu_seconds_total{mode!="idle"}[5m])) > 0.8` |
| 메모리 85% 초과 | `(1 - node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes) > 0.85` |
| p95 응답시간 1초 초과 | `histogram_quantile(0.95, rate(http_server_requests_seconds_bucket[5m])) > 1` |
| PVC 사용량 80% 초과 | `kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.8` |

### 6-2. Discord 알람 연동

`values-prometheus.yaml`의 alertmanager 설정 주석 해제 후 webhook URL 입력:

```yaml
alertmanager:
  config:
    global:
      resolve_timeout: 5m
    route:
      receiver: discord-notifications
      group_by: ['alertname', 'namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
    receivers:
      - name: discord-notifications
        discord_configs:
          - webhook_url: "https://discord.com/api/webhooks/YOUR/WEBHOOK"
            title: "[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}"
            message: "{{ range .Alerts }}{{ .Annotations.description }}\n{{ end }}"
```

Discord 웹훅 발급: 채널 편집 → 연동 → 웹후크 → 새 웹후크

---

## 체크리스트

### 서비스 오픈 전 (현재)
- [x] Prometheus + Grafana + Loki 구축
- [ ] Spring Boot Actuator + Micrometer 활성화 (백엔드 팀)
- [ ] 기본 알람 설정 (CrashLoopBackOff, 메모리 90%)
- [ ] Discord 알람 연동

### 서비스 오픈 후
- [ ] 실제 트래픽 기반으로 임계값 조정
- [ ] Spring Boot 대시보드 추가 (ID: 12685, 4701)
- [ ] APM 도입 검토 (병목 구간 발생 시)

### EKS 전환 시
- [ ] CloudWatch + Prometheus 연동
- [ ] RDS, ALB 지표 추가
- [ ] Cluster Autoscaler 지표 추가
- [ ] 비용 모니터링 도구 추가 (Kubecost)
- [ ] 최신 Loki 차트로 교체
- [ ] APM (OpenTelemetry + Tempo) 도입
