# ArgoCD + GitOps 연동 가이드

k3s 위에 ArgoCD를 설치하고, GitHub 레포(gitops)를 GitOps 저장소로 연결하는 전체 가이드입니다.
이 구조는 EKS로 전환 시에도 동일하게 사용됩니다.

---

## 전체 아키텍처

```
[ 개발자 ]
    │ git push (코드 변경)
    ▼
[ pop-con-backend / pop-con-frontend ]  ← 앱 소스 레포
    │ GitHub Actions: 빌드 → 이미지 푸시 → GitOps 레포 이미지 태그 업데이트
    ▼
[ gitops ]  ← GitOps 레포 (팀 레포)
    │ manifest 변경 감지
    ▼
[ ArgoCD ]  ← k3s 위에 설치
    │ 자동 동기화 (Auto Sync)
    ▼
[ k3s / EKS ]  ← 실제 배포 환경
```

**핵심 원칙**: 클러스터 상태는 항상 GitOps 레포의 manifest를 기준으로 합니다.
`kubectl apply`를 직접 실행하지 않습니다.

---

## 목차

1. [GitOps 레포 구조 재편성](#1-gitops-레포-구조-재편성)
2. [ArgoCD 설치](#2-argocd-설치)
3. [ArgoCD 접속 및 초기 설정](#3-argocd-접속-및-초기-설정)
4. [ArgoCD Application 생성](#4-argocd-application-생성)
5. [CI 파이프라인 연동 (이미지 태그 자동 업데이트)](#5-ci-파이프라인-연동)
6. [배포 흐름 확인](#6-배포-흐름-확인)
7. [EKS 전환 시 변경사항](#7-eks-전환-시-변경사항)

---

## 1. GitOps 레포 구조 재편성

현재 `k8s/` 폴더를 환경별로 분리합니다.
**Kustomize**를 사용합니다 (kubectl에 내장, 별도 설치 불필요).

### 목표 구조

```
gitops/
 ├── docker-compose.yml          ← 기존 (Docker 배포용)
 ├── deploy.sh
 ├── k8s/
 │    ├── base/                      ← 공통 manifest (환경 무관)
 │    │    ├── kustomization.yaml
 │    │    ├── namespace.yaml
 │    │    ├── configmap.yaml
 │    │    ├── secret.yaml
 │    │    ├── mysql.yaml
 │    │    ├── redis.yaml
 │    │    └── backend.yaml
 │    │
 │    └── overlays/
 │         ├── dev/                  ← dev 환경 (현재 k3s)
 │         │    ├── kustomization.yaml
 │         │    └── backend-patch.yaml   (이미지 태그, 리소스 등 오버라이드)
 │         │
 │         └── prod/                 ← prod 환경 (추후 EKS)
 │              ├── kustomization.yaml
 │              └── backend-patch.yaml
 │
 └── argocd/
      └── application.yaml          ← ArgoCD Application 정의
```

### base/kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - namespace.yaml
  - secret.yaml
  - configmap.yaml
  - mysql.yaml
  - redis.yaml
  - backend.yaml
```

### overlays/dev/kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: popcon

resources:
  - ../../base

# 이미지 태그 오버라이드 (CI가 이 값을 업데이트)
images:
  - name: 654654578161.dkr.ecr.ap-northeast-2.amazonaws.com/dev-app
    newTag: backend-latest    # CI 실행 시 backend-<git-sha> 로 자동 변경
```

### overlays/dev/backend-patch.yaml

dev 환경에서만 다른 설정이 있을 경우 여기서 오버라이드합니다.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: popcon-backend
  namespace: popcon
spec:
  replicas: 1                # prod은 2~3으로 설정
  template:
    spec:
      containers:
        - name: backend
          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "1Gi"
              cpu: "500m"
```

### overlays/prod/kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: popcon

resources:
  - ../../base

images:
  - name: 654654578161.dkr.ecr.ap-northeast-2.amazonaws.com/dev-app
    newTag: backend-latest
```

> **Kustomize 로컬 확인 방법**
> ```bash
> kubectl kustomize k8s/overlays/dev    # 렌더링 결과 확인
> kubectl apply -k k8s/overlays/dev     # 직접 적용 (ArgoCD 없을 때)
> ```

---

## 2. ArgoCD 설치

k3s EC2 내부에서 실행합니다.

```bash
# ArgoCD 네임스페이스 생성 및 설치
sudo kubectl create namespace argocd
sudo kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 설치 확인 (모두 Running 될 때까지 대기 - 약 2분)
sudo kubectl get pods -n argocd -w
```

### 외부 접근을 위한 NodePort 설정

```bash
sudo kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "NodePort", "ports": [{"port": 443, "nodePort": 30443, "protocol": "TCP"}]}}'

# 접속 확인
sudo kubectl get svc -n argocd argocd-server
```

> EC2 Security Group에서 포트 **30443** 인바운드 허용 필요 (AWS 콘솔에서 추가)

---

## 3. ArgoCD 접속 및 초기 설정

### 초기 비밀번호 확인

```bash
# 초기 admin 비밀번호
sudo kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

### 웹 UI 접속

```
https://<EC2-Public-IP>:30443
```

- Username: `admin`
- Password: 위에서 확인한 값

### ArgoCD CLI 설치 (선택 - EC2 내부)

```bash
curl -sSL -o argocd \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd
sudo mv argocd /usr/local/bin/

# 로그인
argocd login localhost:30443 --username admin --password <password> --insecure
```

### 비밀번호 변경 (권장)

```bash
argocd account update-password
```

---

## 4. ArgoCD Application 생성

ArgoCD가 어떤 레포의 어떤 경로를 바라볼지 정의합니다.

### argocd/application.yaml

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: popcon-dev
  namespace: argocd
  # App 삭제 시 k8s 리소스도 함께 삭제 (주의: 운영에서는 설정 검토 필요)
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default

  source:
    repoURL: https://github.com/kt-cloud-TECHUP-T1/gitops.git
    targetRevision: main              # 바라볼 브랜치
    path: k8s/overlays/dev            # Kustomize overlay 경로

  destination:
    server: https://kubernetes.default.svc   # 현재 클러스터 (자기 자신)
    namespace: popcon

  syncPolicy:
    automated:
      prune: true       # GitOps 레포에서 삭제된 리소스는 클러스터에서도 삭제
      selfHeal: true    # 클러스터에서 직접 변경된 내용을 GitOps 기준으로 되돌림
    syncOptions:
      - CreateNamespace=true
```

### Application 적용

```bash
# GitOps 레포 클론 후
sudo kubectl apply -f argocd/application.yaml

# 동기화 상태 확인
sudo kubectl get application -n argocd
```

또는 ArgoCD 웹 UI에서:
1. `+ NEW APP` 클릭
2. Application Name: `popcon-dev`
3. Repository URL: `https://github.com/kt-cloud-TECHUP-T1/gitops.git`
4. Path: `k8s/overlays/dev`
5. Cluster: `https://kubernetes.default.svc`
6. Namespace: `popcon`
7. Sync Policy: `Automatic` 체크

---

## 5. CI 파이프라인 연동

### 흐름

```
코드 push → GitHub Actions
  → Docker 빌드 → ECR 푸시 (backend-<sha> 태그)
  → gitops 레포의 kustomization.yaml 이미지 태그 업데이트
  → ArgoCD가 변경 감지 → 자동 배포
```

### GitHub Actions 수정 (.github/workflows/deploy-backend.yml)

pop-con-backend 레포에 추가하는 워크플로우입니다.

```yaml
name: Build and Deploy Backend

on:
  push:
    branches: [ dev ]

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ap-northeast-2

      - name: Login to ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and push Docker image
        id: build
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          IMAGE_TAG: backend-${{ github.sha }}
        run: |
          docker build -t $ECR_REGISTRY/dev-app:$IMAGE_TAG .
          docker push $ECR_REGISTRY/dev-app:$IMAGE_TAG
          echo "image_tag=$IMAGE_TAG" >> $GITHUB_OUTPUT

      - name: Update image tag in GitOps repo
        env:
          IMAGE_TAG: ${{ steps.build.outputs.image_tag }}
          GITOPS_TOKEN: ${{ secrets.GITOPS_TOKEN }}
        run: |
          git clone https://x-access-token:${GITOPS_TOKEN}@github.com/kt-cloud-TECHUP-T1/gitops.git
          cd gitops

          # kustomization.yaml의 이미지 태그 업데이트
          cd k8s/overlays/dev
          kustomize edit set image \
            654654578161.dkr.ecr.ap-northeast-2.amazonaws.com/dev-app=${IMAGE_TAG}

          git config user.email "github-actions@github.com"
          git config user.name "github-actions[bot]"
          git add kustomization.yaml
          git commit -m "chore: update backend image to ${IMAGE_TAG}"
          git push
```

### GITOPS_TOKEN 설정

pop-con-backend 레포의 GitHub Secrets에 추가:

```
Settings → Secrets and variables → Actions → New repository secret

Name:  GITOPS_TOKEN
Value: GitHub Personal Access Token (gitops 레포 write 권한 필요)
       → GitHub → Settings → Developer settings → Personal access tokens
       → Permissions: repo (전체)
```

---

## 6. 배포 흐름 확인

### ArgoCD에서 동기화 상태 확인

```bash
# Application 상태
sudo kubectl get application -n argocd

# 상세 상태
sudo kubectl describe application popcon-dev -n argocd
```

| 상태 | 의미 |
|------|------|
| `Synced` | GitOps 레포와 클러스터 상태 일치 |
| `OutOfSync` | GitOps 레포 변경 감지, 동기화 예정 |
| `Healthy` | 모든 Pod 정상 |
| `Degraded` | Pod 일부 비정상 |

### 수동 동기화 (자동 동기화 전 테스트용)

```bash
argocd app sync popcon-dev
```

### 배포 히스토리 확인

```bash
argocd app history popcon-dev
```

### 롤백

```bash
# 이전 버전으로 롤백
argocd app rollback popcon-dev <revision-number>
```

---

## 7. EKS 전환 시 변경사항

k3s → EKS 전환 시 **GitOps 레포 구조는 그대로 유지**됩니다.
변경이 필요한 것은 최소입니다.

### 변경 필요한 것

| 항목 | k3s | EKS |
|------|-----|-----|
| ArgoCD destination | `https://kubernetes.default.svc` | EKS 클러스터 URL 추가 |
| ECR Secret | 수동 생성 | IRSA (IAM Roles for Service Accounts)로 대체 |
| NodePort | 30080 | LoadBalancer 또는 Ingress로 변경 |
| 볼륨 | hostPath | EBS CSI Driver PVC |

### overlays/prod 추가 시

```yaml
# k8s/overlays/prod/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: popcon

resources:
  - ../../base

images:
  - name: 654654578161.dkr.ecr.ap-northeast-2.amazonaws.com/dev-app
    newTag: backend-latest  # prod 이미지 태그

patches:
  - path: backend-patch.yaml
```

```yaml
# k8s/overlays/prod/backend-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: popcon-backend
spec:
  replicas: 3          # prod은 고가용성
```

### ArgoCD에 EKS 클러스터 등록

```bash
# EKS 클러스터 kubeconfig 추가
aws eks update-kubeconfig --name <cluster-name> --region ap-northeast-2

# ArgoCD에 클러스터 등록
argocd cluster add <context-name>

# Application의 destination 변경
# server: https://<EKS-cluster-endpoint>
```

---

## 빠른 참고 명령어

```bash
# ArgoCD Pod 상태
sudo kubectl get pods -n argocd

# Application 목록
sudo kubectl get application -n argocd

# 수동 동기화
argocd app sync popcon-dev

# 앱 상태 확인
argocd app get popcon-dev

# 로그 확인
sudo kubectl logs -n argocd deployment/argocd-server

# Kustomize 렌더링 미리보기 (배포 전 확인)
kubectl kustomize k8s/overlays/dev
```