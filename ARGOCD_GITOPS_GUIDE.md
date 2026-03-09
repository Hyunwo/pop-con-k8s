# ArgoCD + GitOps 연동 가이드

k3s 위에 ArgoCD를 설치하고, GitHub 레포(gitops)를 GitOps 저장소로 연결하는 전체 가이드입니다.
실제 구현을 기준으로 작성되었습니다.

---

## 전체 아키텍처

```
[ 개발자 ]
    │ git push (코드 변경)
    ▼
[ pop-con-backend / pop-con-frontend ]  ← 앱 소스 레포
    │ GitHub Actions: 빌드 → ECR 이미지 푸시 → GitOps 레포 이미지 태그 업데이트
    ▼
[ gitops ]  ← GitOps 레포 (팀 레포, main 브랜치 기준)
    │ manifest 변경 감지
    ▼
[ ArgoCD ]  ← k3s 위에 설치, argocd.popcon.store 접속
    │ 자동 동기화 (Auto Sync)
    ▼
[ k3s ]  ← staging EC2 (private subnet), Traefik Ingress
    ▼
[ ALB ]  ← HTTPS 종단, Cloudflare CNAME 연결
```

**핵심 원칙**: 클러스터 상태는 항상 GitOps 레포의 manifest를 기준으로 합니다.

---

## 목차

1. [GitOps 레포 구조](#1-gitops-레포-구조)
2. [ArgoCD 설치](#2-argocd-설치)
3. [GitHub 레포 연결 (PAT 인증)](#3-github-레포-연결-pat-인증)
4. [ArgoCD Application 생성](#4-argocd-application-생성)
5. [ArgoCD 도메인 연결](#5-argocd-도메인-연결)
6. [모니터링 스택 배포](#6-모니터링-스택-배포)
7. [CI 파이프라인 연동](#7-ci-파이프라인-연동)
8. [트러블슈팅](#8-트러블슈팅)
9. [빠른 참고 명령어](#9-빠른-참고-명령어)

---

## 1. GitOps 레포 구조

```
gitops/
 ├── argocd/
 │    ├── application.yaml          ← ArgoCD Application 정의 (수동 1회 apply)
 │    ├── argocd-ingress.yaml       ← argocd.popcon.store Ingress
 │    └── argocd-insecure-cm.yaml   ← ArgoCD HTTP 모드 설정
 │
 └── staging/
      ├── kustomization.yaml        ← 이미지 태그 관리 (CI가 자동 업데이트)
      ├── namespace.yaml
      ├── ingress.yaml              ← Traefik Ingress (staging/stagingapi 도메인)
      ├── ecr-auth-cronjob.yaml     ← ECR 인증 자동 갱신
      ├── backend/
      │    ├── auth/
      │    │    ├── deployment.yaml
      │    │    └── service.yaml
      │    └── user/
      │         ├── deployment.yaml
      │         └── service.yaml
      ├── frontend/
      │    ├── deployment.yaml
      │    └── service.yaml
      ├── scripts/
      │    └── refresh-ecr-secret.sh
      └── monitoring/
           ├── argocd-apps/
           │    ├── prometheus-app.yaml   ← kube-prometheus-stack Application
           │    └── loki-app.yaml        ← loki-stack Application
           └── helm-values/
                ├── values-prometheus.yaml
                └── values-loki.yaml
```

### staging/kustomization.yaml (이미지 태그 관리)

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: popcon-staging

resources:
  - namespace.yaml
  - backend/auth/deployment.yaml
  - backend/auth/service.yaml
  - backend/user/deployment.yaml
  - backend/user/service.yaml
  - frontend/deployment.yaml
  - frontend/service.yaml
  - ingress.yaml
  - ecr-auth-cronjob.yaml

images:
  - name: auth-service
    newName: 274130523831.dkr.ecr.ap-northeast-2.amazonaws.com/auth-service
    newTag: latest    # CI 실행 시 자동 업데이트
  - name: user-service
    newName: 274130523831.dkr.ecr.ap-northeast-2.amazonaws.com/user-service
    newTag: latest
  - name: frontend
    newName: 274130523831.dkr.ecr.ap-northeast-2.amazonaws.com/frontend
    newTag: latest
```

---

## 2. ArgoCD 설치

k3s EC2 내부에서 실행합니다.

```bash
# ArgoCD 네임스페이스 생성
sudo kubectl create namespace argocd

# ArgoCD 설치 (--server-side 필수: CRD annotation 크기 제한 우회)
sudo kubectl apply -n argocd --server-side \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 설치 확인 (모두 Running 될 때까지 대기 - 약 2~3분)
sudo kubectl get pods -n argocd -w
```

> **주의**: `--server-side` 없이 설치하면 아래 에러 발생
> `"applicationsets.argoproj.io" is invalid: metadata.annotations: Too long`

### k3s flannel NetworkPolicy 제거

k3s 기본 CNI(flannel)는 NetworkPolicy를 지원하지 않습니다.
ArgoCD 설치 후 반드시 제거해야 합니다.

```bash
sudo kubectl delete networkpolicy -n argocd --all
```

> 제거하지 않으면 argocd-repo-server가 argocd-server와 통신 불가

### 초기 비밀번호 확인

```bash
sudo kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

---

## 3. GitHub 레포 연결 (PAT 인증)

ArgoCD가 private gitops 레포를 읽을 수 있도록 PAT(Personal Access Token)를 등록합니다.

### PAT 발급

```
GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
권한: repo (전체)
```

### ArgoCD에 레포 등록

ArgoCD UI → Settings → Repositories → Connect Repo

```
Connection Method: HTTPS
Repository URL: https://github.com/kt-cloud-TECHUP-T1/gitops.git
Username: <GitHub 개인 사용자명 (조직명 아님)>
Password: <발급한 PAT>
```

또는 kubectl로 등록:

```bash
sudo kubectl create secret generic gitops-repo-secret \
  -n argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/kt-cloud-TECHUP-T1/gitops.git \
  --from-literal=username=<GitHub사용자명> \
  --from-literal=password=<PAT>

sudo kubectl label secret gitops-repo-secret \
  -n argocd argocd.argoproj.io/secret-type=repository
```

---

## 4. ArgoCD Application 생성

### argocd/application.yaml

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: popcon-staging
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/kt-cloud-TECHUP-T1/gitops
    targetRevision: main
    path: staging
  destination:
    server: https://kubernetes.default.svc
    namespace: popcon-staging
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Application 적용 (1회 수동 apply)

```bash
# EC2에서 실행
sudo kubectl apply -f /home/ec2-user/gitops/argocd/application.yaml

# 동기화 상태 확인
sudo kubectl get application -n argocd
```

| 상태 | 의미 |
|------|------|
| `Synced` | GitOps 레포와 클러스터 상태 일치 |
| `OutOfSync` | 변경 감지, 동기화 예정 |
| `Healthy` | 모든 Pod 정상 |
| `Unknown` | 상태 평가 중 또는 repo 연결 문제 |

> **Unknown 상태 해결**: argocd-repo-server pod 재시작
> ```bash
> sudo kubectl delete pod -n argocd -l app.kubernetes.io/name=argocd-repo-server
> ```

---

## 5. ArgoCD 도메인 연결

Cloudflare + ALB + Traefik을 통해 `argocd.popcon.store`로 접속합니다.

### 트래픽 흐름

```
사용자 (https://argocd.popcon.store)
    ↓
Cloudflare DNS (CNAME → ALB)
    ↓
ALB (HTTPS 443 → HTTP 80, SSL 종단)
    ↓
Traefik (EC2 포트 80, host header 기반 라우팅)
    ↓
ArgoCD (HTTP 모드)
```

### ArgoCD insecure 모드 설정

ALB가 SSL을 처리하므로 ArgoCD는 HTTP로 동작합니다.

```bash
# argocd/argocd-insecure-cm.yaml
sudo kubectl apply -f /home/ec2-user/gitops/argocd/argocd-insecure-cm.yaml

# argocd/argocd-ingress.yaml
sudo kubectl apply -f /home/ec2-user/gitops/argocd/argocd-ingress.yaml

# argocd-server 재시작 (설정 적용)
sudo kubectl rollout restart deployment argocd-server -n argocd
```

### argocd-ingress.yaml 내용

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: argocd
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  rules:
    - host: argocd.popcon.store
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
```

### Cloudflare DNS 설정

```
타입: CNAME
이름: argocd
대상: t1-staging-ec2-alb-xxxx.ap-northeast-2.elb.amazonaws.com
```

> **주의**: argocd 네임스페이스는 GitOps Application 관리 대상이 아니므로
> 위 파일들은 EC2에서 직접 kubectl apply로 적용합니다 (bootstrap 방식).

---

## 6. 모니터링 스택 배포

Prometheus + Grafana + Loki + Promtail을 ArgoCD Multi-Source Application으로 배포합니다.

### 배포 방법 (1회 수동 apply)

```bash
sudo kubectl apply -f /home/ec2-user/gitops/staging/monitoring/argocd-apps/prometheus-app.yaml
sudo kubectl apply -f /home/ec2-user/gitops/staging/monitoring/argocd-apps/loki-app.yaml
```

### 상태 확인

```bash
sudo kubectl get application -n argocd
sudo kubectl get pods -n monitoring
```

### 주의사항

- `values-loki.yaml`에서 `/var/log/pods` extraVolumeMounts 중복 설정 시 Promtail DaemonSet 배포 실패
  - loki-stack 차트가 이미 `/var/log/pods`를 기본 마운트함
- k3s 환경에서 비활성화 필요한 컴포넌트 (values-prometheus.yaml에 설정):
  - `kubeControllerManager`, `kubeScheduler`, `kubeEtcd` 등

---

## 7. CI 파이프라인 연동

### 현재 상태

| 단계 | 상태 |
|------|------|
| 코드 push → GitHub Actions 트리거 | ✅ (dev 브랜치) |
| Docker 이미지 빌드 + ECR push | ✅ |
| kustomization.yaml 태그 자동 업데이트 | ❌ (미구현) |
| gitops 레포 push → ArgoCD 자동 배포 | ❌ (미구현) |

### staging 브랜치 워크플로우 추가 필요

`pop-con-backend/.github/workflows/deploy-staging.yml` 예시:

```yaml
name: CI/CD(STAGING) - Build and Deploy

on:
  push:
    branches:
      - staging

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_IAM_ROLE_ARN }}
          aws-region: ap-northeast-2

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Set short SHA
        run: echo "SHORT_SHA=${GITHUB_SHA::10}" >> $GITHUB_ENV

      - name: Build and push image to ECR
        run: |
          docker build -t ${{ steps.login-ecr.outputs.registry }}/auth-service:${{ env.SHORT_SHA }} .
          docker push ${{ steps.login-ecr.outputs.registry }}/auth-service:${{ env.SHORT_SHA }}

      - name: Update kustomization.yaml image tag
        env:
          GITOPS_TOKEN: ${{ secrets.GITOPS_TOKEN }}
        run: |
          git clone https://x-access-token:${GITOPS_TOKEN}@github.com/kt-cloud-TECHUP-T1/gitops.git
          cd gitops/staging

          kustomize edit set image \
            auth-service=274130523831.dkr.ecr.ap-northeast-2.amazonaws.com/auth-service:${{ env.SHORT_SHA }}

          git config user.email "github-actions@github.com"
          git config user.name "github-actions[bot]"
          git add kustomization.yaml
          git commit -m "chore: staging auth-service 이미지 태그 업데이트 ${{ env.SHORT_SHA }}"
          git push
```

### GITOPS_TOKEN 설정

```
pop-con-backend 레포 → Settings → Secrets → Actions → New secret
Name: GITOPS_TOKEN
Value: GitHub PAT (gitops 레포 write 권한)
```

---

## 8. 트러블슈팅

### ArgoCD CRD annotation 크기 초과

```
에러: metadata.annotations: Too long: may not be more than 262144 bytes
해결: kubectl apply --server-side 사용
```

### argocd-repo-server Completed 상태

```
증상: repo-server가 Running 대신 Completed → Application Unknown 상태
해결: sudo kubectl delete pod -n argocd -l app.kubernetes.io/name=argocd-repo-server
```

### flannel NetworkPolicy 차단

```
에러: dial tcp: connect: connection refused (argocd-repo-server)
원인: k3s flannel은 NetworkPolicy 미지원
해결: sudo kubectl delete networkpolicy -n argocd --all
```

### git dubious ownership

```
에러: fatal: detected dubious ownership in repository
해결: sudo git config --global --add safe.directory /home/ec2-user/gitops
```

### Promtail DaemonSet Missing

```
에러: DaemonSet "loki-stack-promtail" is invalid: volumeMounts must be unique
원인: values-loki.yaml에 /var/log/pods extraVolumeMount 중복
해결: values-loki.yaml에서 extraVolumes, extraVolumeMounts 섹션 제거
```

### Application Unknown 상태에서 자동 sync 안 됨

```
로그: Skipping auto-sync: application status is Unknown
해결: sudo kubectl annotate application <app-name> -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

---

## 9. 빠른 참고 명령어

```bash
# 전체 Pod 상태
sudo kubectl get pods -A

# Application 상태
sudo kubectl get application -n argocd

# Application 강제 refresh
sudo kubectl annotate application popcon-staging -n argocd argocd.argoproj.io/refresh=hard --overwrite

# repo-server 재시작
sudo kubectl delete pod -n argocd -l app.kubernetes.io/name=argocd-repo-server

# 메모리 확인
free -h

# gitops 레포 최신화
sudo git -C /home/ec2-user/gitops pull

# 모니터링 Application 등록
sudo kubectl apply -f /home/ec2-user/gitops/staging/monitoring/argocd-apps/prometheus-app.yaml
sudo kubectl apply -f /home/ec2-user/gitops/staging/monitoring/argocd-apps/loki-app.yaml

# ArgoCD 도메인 연결 관련 apply (merge 후 1회)
sudo kubectl apply -f /home/ec2-user/gitops/argocd/argocd-insecure-cm.yaml
sudo kubectl apply -f /home/ec2-user/gitops/argocd/argocd-ingress.yaml
sudo kubectl rollout restart deployment argocd-server -n argocd
```
