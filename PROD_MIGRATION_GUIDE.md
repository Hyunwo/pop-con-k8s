# Prod 전환 가이드

> 작성일: 2026-03-20
> 현재 Staging(k3s) → Production(EKS) 전환을 위한 단계별 작업 가이드

---

## 전환 전 확인사항 (백엔드 팀 협의 필수)

Prod 전환 전 반드시 백엔드 팀에 확인해야 할 항목입니다.

| 확인 항목 | 이유 |
|---------|------|
| 스케줄러 중복 실행 방지 처리 여부 | HPA로 pod가 늘어나면 스케줄러가 동시에 실행됨 |
| `/queue` API가 어느 서비스에 포함되는가 | Ingress 라우팅 추가 필요 |
| queue 운영 설정값 (폴링 주기, 최대 활성 인원) | ConfigMap에 추가 필요 |
| auction-service 배포 준비 완료 여부 | gitops prod에 포함 여부 결정 |

---

## 1단계: Terraform — EKS 인프라 구성

### 1-1. EKS 모듈 작성

`terraform-infra/modules/eks/` 디렉토리를 새로 생성합니다.

```
terraform-infra/
  modules/
    eks/            ← 신규 생성
      main.tf       (EKS 클러스터, 노드그룹)
      alb.tf        (ALB Ingress Controller IAM)
      irsa.tf       (서비스 계정별 IAM 역할)
      outputs.tf
      variables.tf
```

**EKS 구성 시 포함할 것**
- EKS 클러스터 (Kubernetes 1.29+)
- Managed Node Group (EC2 Auto Scaling)
- ALB Ingress Controller (Traefik 대신 AWS ALB 사용)
- IRSA (IAM Roles for Service Accounts)
  - External Secrets Operator용 SSM 읽기 권한
  - ECR 이미지 pull 권한

### 1-2. env/prod/ 생성

Staging과 분리된 Prod 환경을 구성합니다.

```
terraform-infra/
  env/
    staging/    (현재 k3s 환경)
    prod/       ← 신규 생성
      main.tf
      variables.tf
      terraform.tfvars
```

**Staging과 달라지는 점**

| 항목 | Staging | Prod |
|------|---------|------|
| 서버 | EC2 + k3s | EKS |
| RDS 인스턴스 | 소형 | 중형 이상 |
| ElastiCache | 단일 노드 | 클러스터 모드 권장 |
| SSM 경로 | /popcon/staging/ | /popcon/prod/ |
| Lambda 스케줄러 | 있음 (비업무시간 중지) | 제거 (24시간 운영) |

### 1-3. Prod SSM 파라미터 추가

Terraform 적용 후 AWS 콘솔에서 직접 값을 입력해야 하는 항목들입니다.

```bash
# Terraform이 키만 생성하고 값은 콘솔에서 직접 입력
/popcon/prod/JWT_SECRET
/popcon/prod/KAKAO_CLIENT_ID
/popcon/prod/KAKAO_CLIENT_SECRET
/popcon/prod/NAVER_CLIENT_ID
/popcon/prod/NAVER_CLIENT_SECRET
/popcon/prod/PORTONE_STORE_ID
/popcon/prod/PORTONE_API_SECRET
```

> Staging과 Prod의 OAuth 앱은 **별도 등록 필요** (카카오, 네이버 개발자 콘솔에서 prod 도메인 추가)

---

## 2단계: GitOps — prod 디렉토리 구성

### 2-1. 디렉토리 구조 생성

Staging 구조를 기반으로 prod를 생성합니다.

```
gitops/
  staging/          (현재)
  prod/             ← 신규 생성
    kustomization.yaml
    namespace.yaml
    secret-store.yaml
    ingress.yaml
    backend/
      common/
        configmap-common.yaml    (prod DB/Redis 주소)
        external-secret-common.yaml
        kustomization.yaml
      auth/
      user/
      popup/
      auction/
    frontend/
    monitoring/
```

### 2-2. Namespace 변경

```yaml
# prod/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: popcon-prod    # staging → prod
```

### 2-3. ConfigMap — prod 주소로 변경

```yaml
# prod/backend/common/configmap-common.yaml
data:
  DB_HOST: "{prod RDS 주소}"
  DB_PORT: "3306"
  DB_NAME: "popcon"
  REDIS_HOST: "{prod ElastiCache 주소}"
  REDIS_PORT: "6379"
  SPRING_PROFILES_ACTIVE: "prod"
```

### 2-4. Ingress — prod 도메인으로 변경

```yaml
# prod/ingress.yaml
spec:
  rules:
    - host: popcon.store           # staging.popcon.store → popcon.store
      http:
        paths:
          - path: /
            backend:
              service:
                name: frontend-svc

    - host: api.popcon.store       # stagingapi → api
      http:
        paths:
          - path: /auth
            backend:
              service:
                name: backend-auth-svc
          - path: /user
            backend:
              service:
                name: backend-user-svc
          - path: /popup
            backend:
              service:
                name: backend-popup-svc
          - path: /auction
            backend:
              service:
                name: backend-auction-svc
          - path: /queue           # 대기열 API (백엔드 담당 서비스 확인 후 추가)
            backend:
              service:
                name: backend-???-svc
```

### 2-5. HPA 추가

각 서비스 디렉토리에 HPA를 추가합니다.

```yaml
# prod/backend/auth/hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: backend-auth-hpa
  namespace: popcon-prod
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: backend-auth
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 70
```

> **주의**: 스케줄러가 포함된 서비스는 백엔드 팀의 분산 락 구현 확인 후 HPA 적용

### 2-6. Deployment — prod 리소스 상향

```yaml
# prod deployment는 staging보다 리소스 상향
resources:
  requests:
    cpu: "250m"      # staging: 150m
    memory: "768Mi"  # staging: 512Mi
  limits:
    cpu: "1000m"     # staging: 500m
    memory: "1Gi"    # staging: 768Mi
```

### 2-7. ArgoCD Application 등록

EKS 클러스터에 ArgoCD를 설치하고 prod Application을 등록합니다.

```yaml
# gitops/prod/argocd-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: popcon-prod
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/kt-cloud-TECHUP-T1/gitops.git
    targetRevision: HEAD
    path: prod
  destination:
    server: https://kubernetes.default.svc
    namespace: popcon-prod
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## 3단계: CI/CD — Prod 파이프라인 추가

### 3-1. prod-ci.yml 생성

`pop-con-backend/.github/workflows/prod-ci.yml`을 새로 생성합니다.

```yaml
name: CI(PROD) - Build and Push to ECR

on:
  push:
    branches:
      - main             # staging은 staging 브랜치, prod는 main 브랜치

jobs:
  build-and-push:
    # staging-ci.yml과 동일한 빌드 과정

    - name: Update GitOps deployment
      run: |
        curl -X POST \
          -H "Authorization: Bearer ${{ secrets.GITOPS_TOKEN }}" \
          https://api.github.com/repos/kt-cloud-TECHUP-T1/gitops/dispatches \
          -d '{
            "event_type": "deploy-prod",    # staging → prod
            "client_payload": { ... }
          }'
```

### 3-2. deploy-prod.yml 생성 (gitops 레포)

```yaml
# gitops/.github/workflows/deploy-prod.yml
on:
  repository_dispatch:
    types:
      - deploy-prod

jobs:
  deploy:
    steps:
      - name: Resolve service path
        run: |
          DIR="prod/backend/${NAME}"    # staging → prod 경로

      - name: Manual Approval         # prod는 자동 배포 대신 수동 승인 권장
        uses: trstringer/manual-approval@v1
        with:
          approvers: {팀장 GitHub ID}
```

> Prod는 staging과 달리 **수동 승인 후 배포**하는 것을 권장합니다.

---

## 4단계: Cloudflare 설정

### 4-1. Pro 플랜 전환

```
Cloudflare 대시보드 → 플랜 변경 → Pro ($20/월)
```

**Pro 전환 시 추가되는 기능**
- WAF 룰 5개 → 20개
- OWASP 자동 차단 강화
- 정교한 봇 탐지 엔진
- 제로데이 위협 방어
- 기술 지원 티켓

### 4-2. Prod 도메인 추가

```
popcon.store       → EKS ALB 주소
api.popcon.store   → EKS ALB 주소
```

### 4-3. WAF 추가 룰

```
/queue/status Rate Limit 추가
  → IP당 분당 60회 제한
  → 정상 유저: 3초마다 폴링 = 분당 20회이므로 여유 있음
  → 봇 공격 방어 목적

/draws/*/queue-entries Rate Limit
  → IP당 분당 10회 제한

Prod Swagger 차단
  → api.popcon.store/swagger* → Block
```

---

## 5단계: 모니터링 대시보드 추가

### 5-1. Spring Boot 메트릭 대시보드

백엔드 서비스에서 `/actuator/prometheus`로 메트릭을 노출하면 Grafana에서 시각화합니다.

```promql
# API 초당 요청 수
rate(http_server_requests_seconds_count[1m])

# API 응답 시간 (P95)
histogram_quantile(0.95, rate(http_server_requests_seconds_bucket[5m]))

# JVM 힙 메모리 사용량
jvm_memory_used_bytes{area="heap"}
```

### 5-2. 대기열 모니터링 대시보드

백엔드에서 아래 메트릭을 Prometheus로 노출해주면 됩니다.

```
queue_waiting_size    → 현재 대기 인원
queue_active_size     → 현재 활성 인원
queue_promoted_total  → 누적 승격 인원
queue_blocked_total   → 누적 차단 인원
```

---

## 6단계: 사전 검증

### 6-1. 부하 테스트 (k6)

```javascript
// k6 시나리오: 15,000명 동시 접속
export const options = {
  scenarios: {
    queue_rush: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 15000 },  // 2분 동안 15,000명으로 증가
        { duration: '5m', target: 15000 },  // 5분 유지
        { duration: '1m', target: 0 },      // 종료
      ],
    }
  }
}
```

**확인 지표**
- 응답 시간 P95 < 500ms
- 에러율 < 1%
- pod CrashLoopBackOff 없음
- ElastiCache 메모리 사용량 80% 미만

### 6-2. ElastiCache 메모리 검토

대기열 시스템이 Redis를 대량으로 사용합니다.

| 자료구조 | 15,000명 기준 |
|---------|-------------|
| queue:waiting (ZSET) | ~1.5MB |
| queue:heartbeat (ZSET) | ~1.5MB |
| queue:active (ZSET) | ~수백KB |
| queue:user (HASH × 15,000) | ~6MB |
| queue:token (HASH × 15,000) | ~6MB |
| **합계 (이벤트 1회)** | **~15MB** |

동시 이벤트가 여러 개라면 배수로 증가합니다. 현재 ElastiCache 인스턴스 타입을 확인하고 여유 메모리를 확보해야 합니다.

---

## 전체 진행 순서 요약

```
1단계 (Terraform)
  □ EKS 모듈 작성
  □ env/prod/ 생성 및 terraform apply
  □ SSM /popcon/prod/ 파라미터 추가 (콘솔 직접 입력)

2단계 (GitOps)
  □ gitops/prod/ 디렉토리 생성
  □ namespace, configmap, external-secret, ingress 작성
  □ HPA 설정 추가
  □ ArgoCD EKS 클러스터 연결 및 Application 등록

3단계 (CI/CD)
  □ pop-con-backend prod-ci.yml 추가
  □ gitops deploy-prod.yml 추가

4단계 (Cloudflare)
  □ Pro 플랜 전환
  □ api.popcon.store, popcon.store 도메인 추가
  □ /queue/status Rate Limit 추가

5단계 (모니터링)
  □ Spring Boot 메트릭 대시보드 추가
  □ 대기열 현황 대시보드 추가

6단계 (검증)
  □ k6 부하 테스트 (15,000명 시나리오)
  □ ElastiCache 메모리 확인
  □ 전체 pod 상태 정상 확인
  □ Grafana 대시보드 정상 확인
```
