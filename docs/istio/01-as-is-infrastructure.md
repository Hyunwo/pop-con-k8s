# 현재 인프라 현황 (As-Is)

## 클러스터 구성

| 항목 | 내용 |
|------|------|
| EKS 버전 | v1.35.2 |
| 리전 | ap-northeast-2 (서울) |
| 노드 오토스케일링 | Karpenter v1 |
| 인스턴스 타입 | t3a.large (spot, 2 vCPU / 8GB) |
| AZ | ap-northeast-2a, ap-northeast-2c |

### 노드 현황

| 노드 | 역할 | 타입 | AZ | CPU | Memory |
|------|------|------|----|-----|--------|
| ip-10-1-10-70 | Karpenter 관리 | t3a.large spot | 2a | 5% | 29% |
| ip-10-1-20-230 | Karpenter 관리 | t3a.large spot | 2c | 9% | 87% |
| ip-10-1-20-167 | system (고정) | t3a.large | 2c | 6% | 86% |

> ip-10-1-20-230에 prod 파드 대부분이 집중되어 있음 (TopologySpreadConstraints ScheduleAnyway 한계)

---

## 네임스페이스

| 네임스페이스 | 용도 |
|-------------|------|
| popcon-prod | 애플리케이션 (백엔드 8개, 프론트엔드 1개) |
| monitoring | Prometheus, Grafana, Loki, Promtail, Reloader |
| argocd | GitOps CD |
| kube-system | Karpenter, CoreDNS, ALB Controller, EBS CSI |
| external-secrets | External Secrets Operator (SSM → K8s Secret) |

---

## 서비스 목록

| 서비스 | 언어/프레임워크 | 포트 | Replica | 외부 경로 |
|--------|--------------|------|---------|---------|
| frontend | Next.js | 3000 | 1 | popcon.store/ |
| backend-auth | Spring Boot | 8080 | 2 | api.popcon.store/auth |
| backend-user | Spring Boot | 8080 | 2 | api.popcon.store/users, /billing, /history |
| backend-popup | Spring Boot | 8080 | 2 | api.popcon.store/popups, /magazines |
| backend-auction | Spring Boot | 8080 | 2 | api.popcon.store/auctions |
| backend-draw | Spring Boot | 8080 | 2 | api.popcon.store/draws |
| backend-queue | Spring Boot | 8080 | 2 | api.popcon.store/queues |
| backend-queue-worker | Spring Boot | 8080 | 2 | 내부 전용 |
| backend-anti-macro | Spring Boot | 8080 | 2 | api.popcon.store/anti-macro |

---

## 트래픽 흐름 (As-Is)

```
사용자 (HTTPS)
    │
    ▼
Cloudflare (CDN/DNS)
    │
    ▼
AWS ALB (internet-facing, HTTPS:443)
    │
    ├─ popcon.store        → frontend-svc:3000
    └─ api.popcon.store
        ├─ /auth           → backend-auth-svc:8080
        ├─ /users          → backend-user-svc:8080
        ├─ /billing        → backend-user-svc:8080
        ├─ /history        → backend-user-svc:8080
        ├─ /popups         → backend-popup-svc:8080
        ├─ /magazines      → backend-popup-svc:8080
        ├─ /draws          → backend-draw-svc:8080
        ├─ /auctions       → backend-auction-svc:8080
        ├─ /queues         → backend-queue-svc:8080
        └─ /anti-macro     → backend-anti-macro-svc:8080
```

### 서비스 간 내부 통신

```
backend-queue-svc     → backend-queue-worker-svc (대기열 처리)
backend-*-svc         → backend-anti-macro-svc (어뷰징 방지)
backend-*-svc         → RDS MySQL (t1-prod-rds, 3306)
backend-*-svc         → ElastiCache Redis (t1-prod-redis, 6379)
```

> 모든 서비스 간 통신은 **HTTP 평문 (ClusterIP)**, mTLS 없음

---

## 리소스 현황

| 서비스 | CPU Request | CPU Limit | Memory Request | Memory Limit | 실제 사용 |
|--------|------------|-----------|---------------|-------------|---------|
| backend-auth | 100m | 500m | 256Mi | 768Mi | ~390Mi |
| backend-user | 100m | 500m | 256Mi | 768Mi | ~380Mi |
| backend-popup | 100m | 500m | 256Mi | 768Mi | ~410Mi |
| backend-auction | 100m | 500m | 256Mi | 768Mi | ~415Mi |
| backend-draw | 100m | 500m | 256Mi | 768Mi | ~410Mi |
| backend-queue | 100m | 500m | 256Mi | 768Mi | ~305Mi |
| backend-queue-worker | 100m | 500m | 256Mi | 768Mi | ~310Mi |
| backend-anti-macro | 50m | 250m | 128Mi | 512Mi | ~26Mi |
| frontend | - | - | - | - | ~51Mi |

> JVM 설정: `-XX:InitialRAMPercentage=75 -XX:MaxRAMPercentage=75` → limit의 75% = 최대 576Mi 힙

---

## CI/CD 구조

```
팀원 코드 push (pop-con-backend / pop-con-frontend)
    │
    ▼
GitHub Actions
    ├─ Docker 이미지 빌드
    ├─ ECR push
    └─ gitops 레포 deployment.yaml image tag 자동 업데이트
            │
            ▼
        ArgoCD (Auto Sync)
            └─ EKS 클러스터 자동 배포
```

---

## 현재 인프라 한계

| 항목 | 현재 상태 |
|------|---------|
| 서비스 간 암호화 | ❌ HTTP 평문 |
| 서비스 간 인증 | ❌ 없음 |
| 트래픽 관리 | ❌ retry, circuit breaker, canary 불가 |
| 분산 트레이싱 | ❌ 없음 |
| 서비스 간 레이턴시 관측 | ❌ 불가 |
| 파드 분산 보장 | ⚠️ ScheduleAnyway로 한 노드 쏠림 가능 |
