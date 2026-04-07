# Pop-Con 클라우드/인프라 현황

> 최종 업데이트: 2026-04-07
> 대상: 클라우드/인프라 팀

---

## 1. 전체 아키텍처 현황

### 인프라 (AWS + Terraform)

```
VPC (prod)
  ├── Public Subnet  → ALB, NAT Gateway
  └── Private Subnet → EKS Worker Node, RDS, ElastiCache

EKS (v1.35.2)          → Prod 클러스터 (운영 중)
  ├── Karpenter         → 워커 노드 오토스케일링 (t3a.large spot)
  └── EKS 관리형 nodegroup → system 노드 (t3a.medium, 고정)
RDS (MySQL 8.0)         → 데이터베이스 (t1-prod-rds)
ElastiCache (Redis)     → 대기열, 세션, 캐시 (t1-prod-redis)
ECR                     → Docker 이미지 저장소
SSM Parameter Store     → 환경변수 저장 (/popcon/prod/)
ALB                     → 외부 트래픽 진입점 (HTTPS:443)
Cloudflare              → DNS, WAF, CDN (Free 플랜)
```

**Terraform으로 관리**: VPC, EKS, RDS, ElastiCache, ECR, SSM, ALB, Karpenter IRSA

---

## 2. 클러스터 현황

### 노드

| 노드 | 역할 | 타입 | AZ | CPU | Memory |
|------|------|------|----|-----|--------|
| ip-10-1-10-70 | Karpenter 관리 | t3a.large spot | ap-northeast-2a | 31% | 80% |
| ip-10-1-20-230 | Karpenter 관리 | t3a.large spot | ap-northeast-2c | 7% | 51% |
| ip-10-1-20-167 | system (EKS 관리형, 고정) | t3a.medium | ap-northeast-2c | 11% | 82% |

### 네임스페이스별 파드 현황

**popcon-prod** (애플리케이션)
```
backend-anti-macro   2/2  Running  (각 노드 분산)
backend-auction      2/2  Running  (각 노드 분산)
backend-auth         2/2  Running  (각 노드 분산)
backend-draw         2/2  Running  (각 노드 분산)
backend-popup        2/2  Running  (각 노드 분산)
backend-queue        2/2  Running  (각 노드 분산)
backend-queue-worker 2/2  Running  (각 노드 분산)
backend-user         2/2  Running  (각 노드 분산)
frontend             1/1  Running
```

**monitoring**
```
alertmanager-kube-prometheus-stack-prod-alertmanager-0  2/2  Running
kube-prometheus-stack-prod-grafana                      3/3  Running
kube-prometheus-stack-prod-operator                     1/1  Running
kube-prometheus-stack-prod-prometheus-node-exporter     1/1  Running (노드마다)
kube-prometheus-stack-prod-kube-state-metrics           1/1  Running
loki-stack-prod-0                                       1/1  Running
loki-stack-prod-promtail                                1/1  Running (노드마다)
prometheus-kube-prometheus-stack-prod-prometheus-0      2/2  Running
reloader-prod-reloader                                  1/1  Running
```

**istio-system** (설치 완료, sidecar injection 진행 예정)
```
istiod  1/1  Running
```

---

## 3. GitOps 구조

```
gitops/prod/
  kustomization.yaml
  namespace.yaml         → popcon-prod 네임스페이스
  secret-store.yaml      → SSM ↔ K8s 연결 (External Secrets Operator)
  ingress.yaml           → ALB Ingress (api.popcon.store, popcon.store)
  backend/
    common/              → 공통 ConfigMap + ExternalSecret
    auth/                → deployment, service, hpa, pdb
    user/                → deployment, service, hpa, pdb
    popup/               → deployment, service, hpa, pdb
    auction/             → deployment, service, hpa, pdb
    draw/                → deployment, service, hpa, pdb
    queue/               → deployment, service, hpa, pdb
    queue-worker/        → deployment, service, pdb
    anti-macro/          → deployment, service, pdb
  frontend/              → deployment, service
  monitoring/
    argocd-apps/         → kube-prometheus-stack, loki-stack ArgoCD Application
    helm-values/         → values-*.yaml
  karpenter/
    nodepool.yaml        → t3a.large spot 전용 (xlarge 제거됨)
    ec2nodeclass.yaml
  istio/
    kustomization.yaml
    argocd-apps/
      istio-base-app.yaml → istio-base v1.29.1
      istiod-app.yaml     → istiod v1.29.1
    helm-values/
      values-istiod.yaml
```

---

## 4. ArgoCD Application 현황

| Application | 상태 | 버전/차트 |
|-------------|------|---------|
| backend-auth-prod | Synced/Healthy | - |
| backend-user-prod | Synced/Healthy | - |
| backend-popup-prod | Synced/Healthy | - |
| backend-auction-prod | Synced/Healthy | - |
| backend-draw-prod | Synced/Healthy | - |
| backend-queue-prod | Synced/Healthy | - |
| backend-queue-worker-prod | Synced/Healthy | - |
| backend-anti-macro-prod | Synced/Healthy | - |
| frontend-prod | Synced/Healthy | - |
| kube-prometheus-stack-prod | Synced/Healthy | kube-prometheus-stack |
| loki-stack-prod | Synced/Healthy | loki-stack |
| istio-base-prod | Synced/Healthy | istio/base v1.29.1 |
| istiod-prod | Synced/Healthy | istio/istiod v1.29.1 |

---

## 5. 환경변수 관리

| 구분 | 저장 방식 | 예시 |
|------|---------|------|
| 비민감 설정 | ConfigMap (gitops 관리) | DB_HOST, REDIS_HOST, OAUTH_BASE_URL |
| 민감 설정 | SSM SecureString → K8s Secret 자동 동기화 | DB_PASSWORD, JWT_SECRET |
| 외부 연동 키 | SSM (콘솔 직접 입력) | KAKAO_CLIENT_ID, PORTONE_API_SECRET |

**SSM 경로**: `/popcon/prod/*`
**동기화 주기**: External Secrets Operator 1시간 자동 갱신

---

## 6. CI/CD 파이프라인

```
팀원 코드 push (pop-con-backend / pop-con-frontend)
    │
    ▼
GitHub Actions
    ├─ Docker 이미지 빌드 + ECR push
    └─ gitops 레포 image tag 자동 업데이트
            │
            ▼
        ArgoCD (Auto Sync, selfHeal)
            └─ EKS 클러스터 자동 배포 (Rolling Update)
```

---

## 7. 보안

**Cloudflare WAF (6개 룰)**

| 룰 | 목적 |
|----|------|
| SQLi 차단 | DB 탈취 시도 방어 |
| XSS 차단 | 악성 스크립트 삽입 방어 |
| 경로 탐색 차단 | 서버 내부 파일 접근 차단 |
| 악성 봇/스캐너 차단 | 자동화 공격 도구 차단 |
| 관리자 페이지 보호 | /swagger 팀 외부 접근 차단 |
| Rate Limit | /reservations 봇 대량 요청 방지 |

**도메인**
```
popcon.store        → 프론트엔드
api.popcon.store    → 백엔드 API
```

---

## 8. 모니터링

| 도구 | 역할 | 상태 |
|------|------|------|
| Prometheus | 메트릭 수집 | Running |
| Grafana | 대시보드 시각화 | Running |
| Loki | 로그 수집/저장 | Running |
| Promtail | pod 로그 → Loki 전달 | Running |
| Alertmanager | 알람 관리 | Running |
| Reloader | ConfigMap/Secret 변경 시 자동 rollout | Running |

---

## 9. 고가용성 설정

| 항목 | 설정 |
|------|------|
| Pod 분산 | topologySpreadConstraints (maxSkew: 1, whenUnsatisfiable: DoNotSchedule) |
| Pod 보호 | PodDisruptionBudget (minAvailable: 1) — 전 서비스 적용 |
| 노드 분산 | Karpenter NodePool (2 AZ: ap-northeast-2a, ap-northeast-2c) |
| 인스턴스 타입 | t3a.large spot 전용 (xlarge 제거 완료) |
| 노드 SPOF 방지 | Karpenter 관리 노드 2개 (AZ 분산) |

---

## 10. 트러블슈팅 이력

| 문제 | 원인 | 해결 |
|------|------|------|
| t3a.xlarge 단일 SPOF | Karpenter consolidation이 large 대신 xlarge 통합 | NodePool에서 xlarge 제거 → Karpenter Drifted → 2× large 교체 |
| 파드 한 노드 집중 (15개 → 노드1) | topologySpreadConstraints ScheduleAnyway 한계 | DoNotSchedule로 변경 |
| Rolling restart 중 CPU 103% | 15개 파드 동시 JVM 초기화 | DoNotSchedule 적용 후 분산 배치로 해소 |
| istiod-prod OutOfSync | 인증서 갱신 시 caBundle 변경 | ignoreDifferences jqPathExpression 추가 |
| istio-base-prod OutOfSync | istiod 자동 생성 ValidatingWebhookConfiguration | ignoreDifferences webhooks 추가 |
| Loki S3 BucketRegionError | S3 버킷 리전 설정 오류 | 미해결 (로그 수집은 정상, 장기 보관 S3 전송 실패) |

---

## 11. 진행 중 / 예정 작업

| 작업 | 상태 | 비고 |
|------|------|------|
| Istio 설치 | ✅ 완료 | istio-base, istiod v1.29.1 |
| sidecar injection 활성화 | 🔄 진행 예정 | namespace label + rolling restart |
| PeerAuthentication permissive | ⏳ 예정 | sidecar injection 완료 후 |
| VirtualService / DestinationRule | ⏳ 예정 | retry, timeout, circuit breaker |
| Kiali / Jaeger 설치 | ⏳ 예정 | 관측성 도구 |
| strict mTLS 전환 | ⏳ 예정 | permissive 검증 완료 후 |
| Loki S3 오류 해결 | ⏳ 예정 | 버킷 리전 설정 수정 필요 |
