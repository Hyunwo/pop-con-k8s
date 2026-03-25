# Pop-Con 클라우드/인프라 현황 및 Prod 전환 계획

> 작성일: 2026-03-20
> 대상: 클라우드/인프라 팀

---

## 1. 전체 아키텍처 현황

### 인프라 (AWS + Terraform)

```
VPC
  ├── Public Subnet  → Bastion, NAT Gateway
  └── Private Subnet → EC2(k3s), RDS, ElastiCache

EC2 (k3s)           → 현재 Staging 서버
RDS (MySQL 8.0)     → 데이터베이스
ElastiCache (Redis) → 대기열, 세션, 캐시
ECR                 → Docker 이미지 저장소 (4개 서비스)
SSM Parameter Store → 환경변수 저장
Lambda              → 09~18시 외 자동 서버 ON/OFF
Bastion             → 운영자 SSH 접근용
Cloudflare          → DNS, WAF, CDN (Free 플랜)
```

**Terraform으로 관리 중**: VPC, EC2, RDS, ElastiCache, ECR, SSM, Lambda, Bastion
**미생성**: EKS (Prod 전환 시 필요)

---

### 클러스터 (k3s Staging)

```
popcon-staging 네임스페이스
  ├── backend-auth    (Running) ← auth-service
  ├── backend-user    (Running) ← user-service
  ├── backend-popup   (Running) ← popup-service
  ├── frontend        (Running)
  └── redis-test      (Unknown) ← 테스트용 잔여 pod, 삭제 필요

monitoring 네임스페이스
  ├── Grafana         (Running) ← 대시보드
  ├── Prometheus      (Running) ← 메트릭 수집
  ├── Loki            (Running) ← 로그 수집
  ├── Promtail        (Running) ← pod 로그 → Loki 전달
  └── Alertmanager    (Running)

argocd 네임스페이스
  └── ArgoCD          (Running) ← GitOps 배포 관리
```

> **미배포**: auction-service (gitops 파일 준비됨, 서비스 개발 중)

---

### GitOps 구조

```
gitops/
  staging/
    backend/
      common/         → 공통 ConfigMap + ExternalSecret
      auth/           → deployment, service, configmap, external-secret
      user/           → deployment, service, external-secret
      popup/          → deployment, service
      auction/        → deployment, service (미배포)
    frontend/         → deployment, service, configmap, external-secret
    monitoring/
      argocd-apps/    → loki, prometheus ArgoCD Application
      helm-values/    → values-loki.yaml, values-prometheus.yaml
    ingress.yaml      → Traefik 라우팅
    secret-store.yaml → SSM ↔ K8s 연결 (External Secrets Operator)
    kustomization.yaml
```

---

### 환경변수 관리

| 구분 | 저장 방식 | 예시 |
|------|---------|------|
| 비민감 설정 | ConfigMap (gitops 관리) | DB_HOST, REDIS_HOST, OAUTH_BASE_URL |
| 민감 설정 | SSM SecureString → K8s Secret 자동 동기화 | DB_PASSWORD, JWT_SECRET, OAuth 키 |
| 외부 연동 키 | SSM (콘솔에서 직접 입력) | KAKAO_CLIENT_ID, PORTONE_API_SECRET |

**SSM → K8s Secret 동기화**: External Secrets Operator (1시간 주기 자동 갱신)

**SSM 경로 구조**
```
/popcon/staging/DB_HOST          → 평문 (String)
/popcon/staging/DB_PASSWORD      → 암호화 (SecureString, Terraform 관리)
/popcon/staging/JWT_SECRET       → 암호화 (SecureString, 콘솔 직접 입력)
/popcon/staging/KAKAO_CLIENT_ID  → 암호화 (SecureString, 콘솔 직접 입력)
```

---

### CI/CD 파이프라인

```
PR 생성 (staging 브랜치 대상)
  → ci-pr.yml
      테스트 + Docker 빌드 검증 (4개 서비스 병렬)
      Discord 알림

staging 브랜치 머지
  → staging-ci.yml
      변경된 서비스만 감지 (auth/user/popup/auction)
      Gradle 빌드 + 테스트
      ECR 푸시 (SHORT_SHA 태그)
      gitops 레포에 repository_dispatch 이벤트 전송

gitops 레포
  → deploy-staging.yml
      kustomize로 이미지 태그 자동 업데이트
      git commit & push

ArgoCD
  → 변경 감지 → k3s 자동 배포 (Rolling Update)
```

---

### 보안 (Cloudflare)

**적용된 WAF 룰 (6개)**

| 룰 | 목적 |
|----|------|
| SQLi 차단 | 데이터베이스 탈취 시도 방어 |
| XSS 차단 | 악성 스크립트 삽입 공격 방어 |
| 경로 탐색 차단 | 서버 내부 파일 접근 차단 |
| 악성 봇/스캐너 차단 | 자동화 공격 도구 차단 |
| 관리자 페이지 보호 | /swagger 팀 외부 접근 차단 |
| Rate Limit | /reservations 봇 대량 요청 방지 |

**도메인**
```
staging.popcon.store    → 프론트엔드
stagingapi.popcon.store → 백엔드 API
  ├── /auth  → backend-auth-svc
  ├── /user  → backend-user-svc
  └── /popup → backend-popup-svc
```

---

### 모니터링

| 도구 | 역할 | 상태 |
|------|------|------|
| Prometheus | 메트릭 수집 | Running |
| Grafana | 대시보드 시각화 | Running |
| Loki | 로그 수집/저장 | Running |
| Promtail | pod 로그 → Loki 전달 | Running |
| Alertmanager | 알람 관리 | Running |

**자동 생성된 대시보드**: Kubernetes 노드/pod/네임스페이스 (kube-prometheus-stack 기본 포함)
**직접 생성 필요**: Spring Boot 메트릭, 대기열 현황, 비즈니스 메트릭

---

## 2. Staging vs Prod 비교

| 항목 | Staging (현재) | Prod (준비 필요) |
|------|--------------|----------------|
| **서버** | EC2 + k3s | EKS |
| **도메인** | staging.popcon.store | popcon.store |
| **API 도메인** | stagingapi.popcon.store | api.popcon.store |
| **Cloudflare** | Free | Pro ($20/월) |
| **replicas** | 1 고정 | HPA 자동 확장 |
| **CI/CD** | staging-ci.yml | prod-ci.yml (미생성) |
| **GitOps** | gitops/staging/ | gitops/prod/ (미생성) |
| **SSM 경로** | /popcon/staging/ | /popcon/prod/ (미생성) |
| **Terraform** | ec2-k3s 모듈 | eks 모듈 (미생성) |
| **ArgoCD** | k3s 내부 설치 | EKS 연결 필요 |
| **모니터링 대시보드** | 기본 대시보드 | 앱 대시보드 추가 필요 |
| **스케줄러 처리** | replicas:1 안전 | HPA 전 분리 필요 |

---

## 3. Prod 전환 체크리스트

### Terraform
- [x] EKS 모듈 작성 (클러스터, 노드그룹, IRSA) ← `modules/eks/` 완료
- [x] ALB Ingress Controller IRSA 설정 ← `modules/eks/irsa.tf` 완료
- [x] env/prod/ 생성 (RDS, ElastiCache, SSM 분리) ← 완료
- [ ] modules/vpc/ 모듈 생성 및 prod 전용 VPC 구성 (진행 예정)

### GitOps
- [ ] gitops/prod/ 디렉토리 생성
- [ ] prod ingress (api.popcon.store, popcon.store)
- [ ] HPA 설정 추가 (각 서비스별)
- [ ] prod ArgoCD Application 등록

### CI/CD
- [ ] prod-ci.yml 워크플로우 추가 (main 브랜치 트리거)
- [ ] 수동 승인(Manual Approval) 게이트 추가
- [ ] prod ECR 태그 전략 결정 (버전 태그 권장)

### Cloudflare
- [ ] Pro 플랜 전환
- [ ] api.popcon.store, popcon.store 도메인 추가
- [ ] /queue/status Rate Limit 추가 (대기열 폴링 방어)
- [ ] prod Swagger 차단 (WAF Rule 또는 앱 설정)

### 백엔드 협의
- [ ] 스케줄러 분리 또는 Redis 분산 락 구현 확인 (HPA 전 필수)
- [ ] /queue API 담당 서비스 확인 (Ingress 라우팅 추가)
- [ ] queue 운영 설정값 ConfigMap 추가 (폴링 주기, 최대 활성 인원 등)

### 모니터링
- [ ] Spring Boot 메트릭 대시보드 추가
- [ ] 대기열 현황 대시보드 추가 (대기 인원, 활성 인원)
- [ ] 알람 설정 (pod CrashLoopBackOff, 메모리 임계치 등)

### 사전 검증
- [ ] k6 부하 테스트 (15,000명 동시 접속 시나리오)
- [ ] ElastiCache 메모리 용량 검토 (대기열 자료구조 규모)
- [ ] Redis test pod 삭제 (`kubectl delete pod redis-test -n popcon-staging --force`)

---

## 4. 주요 트러블슈팅 이력

| 문제 | 원인 | 해결 |
|------|------|------|
| Grafana CrashLoopBackOff | loki-stack과 kube-prometheus-stack의 isDefault 충돌 | sidecar 비활성화 + additionalDataSources 직접 명시 |
| ArgoCD repo-server Unknown | k3s 부팅 후 네트워크 준비 전 GitHub 연결 시도 | systemd 서비스로 90초 후 자동 pod 재시작 |
| backend CrashLoopBackOff | SPRING_PROFILES_ACTIVE=prod인데 application-prod.yml 없어 localhost Redis 연결 | Secret 값을 staging으로 수정 |
| Probe 401 오류 | Spring Security가 /actuator/health 차단 | SecurityConfig에서 /actuator/** permitAll() 추가 |
| loki-stack volume_enabled 오류 | loki-stack 2.10.2 미지원 필드 | revert commit으로 제거 |
| git merge conflict | 팀원 kustomization 구조 변경과 로컬 수정 충돌 | git checkout HEAD로 팀원 버전 복구 후 재작업 |
