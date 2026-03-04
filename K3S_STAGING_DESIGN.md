# Pop-Con k3s Staging 환경 설계 가이드

docker-compose(dev) → k3s(staging) → EKS(production) 구조에서
staging 환경의 k3s 설계 및 구축 계획 문서입니다.

---

## 목차

1. [전체 구조 개요](#1-전체-구조-개요)
2. [dev와 staging의 차이점](#2-dev와-staging의-차이점)
3. [매니페스트 구조 설계](#3-매니페스트-구조-설계)
4. [각 매니페스트 상세 설계](#4-각-매니페스트-상세-설계)
5. [Secret 관리 전략](#5-secret-관리-전략)
6. [Ingress 설계](#6-ingress-설계)
7. [ECR 인증 전략](#7-ecr-인증-전략)
8. [CI/CD 연동 계획](#8-cicd-연동-계획)
9. [인프라 구축 순서](#9-인프라-구축-순서)

---

## 1. 전체 구조 개요

```
GitHub Actions (CI/CD)
  → 이미지 빌드 → ECR push
      ↓
  k3s EC2 (staging)
      ├── Traefik Ingress
      │     ├── app.도메인.com     → frontend Pod
      │     └── api.도메인.com     → backend Pod
      ├── frontend Deployment
      └── backend Deployment
            ├── RDS (MySQL)         ← 외부 관리형 DB
            └── ElastiCache (Redis) ← 외부 관리형 캐시
```

> **staging은 MySQL/Redis를 k8s Pod으로 운영하지 않는다.**
> RDS와 ElastiCache를 사용하므로 mysql.yaml, redis.yaml 매니페스트가 불필요하다.

### 환경별 비교

| 항목 | dev | staging | production |
|------|-----|---------|------------|
| 실행 방식 | docker-compose | k3s | EKS |
| 서버 | EC2 단일 | EC2 단일 | EKS 멀티 노드 |
| DB | EC2 내 MySQL 컨테이너 | RDS (외부) | RDS (외부) |
| Cache | EC2 내 Redis 컨테이너 | ElastiCache (외부) | ElastiCache (외부) |
| Ingress | ALB | Traefik (k3s 내장) | AWS ALB Controller |
| Secret 관리 | SSM `/popcon/*` → .env | SSM `/popcon/staging/*` → k8s Secret | SSM → k8s Secret |
| 이미지 | ECR latest | ECR latest | ECR 버전 태그 |
| 비용 | 낮음 | 중간 (RDS/ElastiCache) | 높음 |

---

## 2. dev와 staging의 차이점

### docker-compose vs k8s 매니페스트 대응

```
docker-compose.yml          k8s 매니페스트
─────────────────────────────────────────────
networks: popcon-network  → 00-namespace.yaml
environment: DB_HOST=...  → 01-configmap.yaml    (RDS 엔드포인트로 설정)
environment: DB_PASSWORD= → 02-secret.yaml
mysql: ...                → ❌ 불필요 (RDS 사용)
redis: ...                → ❌ 불필요 (ElastiCache 사용)
backend: ...              → 05-backend.yaml
frontend: ...             → 06-frontend.yaml
ports: 외부 노출           → 07-ingress.yaml
```

### 핵심 차이점

**1. 컨테이너 간 통신**
```
# docker-compose: 서비스명으로 직접 통신
DB_HOST: popcon-mysql

# k8s: Service 리소스를 통해 통신 (동일한 이름 사용 가능)
DB_HOST: popcon-mysql  ← Service 이름과 일치시킴
```

**2. 외부 노출 방식**
```
# docker-compose: ports로 직접 노출
ports:
  - "8080:8080"

# k8s: Ingress → Service → Pod 순서로 라우팅
외부 → Ingress(Traefik) → Service(ClusterIP) → Pod
```

**3. 볼륨 (영구 스토리지)**
```
# docker-compose
volumes:
  - mysql-data:/var/lib/mysql

# k8s: PVC(PersistentVolumeClaim) 사용
PVC → PV(실제 디스크) → Pod 마운트
```

---

## 3. 매니페스트 구조 설계

```
k8s/
├── 00-namespace.yaml     # 네임스페이스 (리소스 격리)
├── 01-configmap.yaml     # 평문 환경변수 (RDS/ElastiCache 엔드포인트 포함)
├── 02-secret.yaml        # 민감 환경변수 (base64 인코딩)
├── 03-backend.yaml       # 백엔드 (Deployment + Service)
├── 04-frontend.yaml      # 프론트엔드 (Deployment + Service)
└── 05-ingress.yaml       # Traefik Ingress (외부 라우팅)
```

> **mysql.yaml, redis.yaml 없음**: staging은 RDS/ElastiCache를 사용하므로
> k8s 내부에 MySQL/Redis Pod을 띄우지 않는다.
>
> **번호를 붙이는 이유**: `kubectl apply -f k8s/` 실행 시
> 알파벳 순서로 적용되므로 의존성 순서 보장

---

## 4. 각 매니페스트 상세 설계

### 00-namespace.yaml

리소스를 격리하는 논리적 공간. docker의 network와 유사.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: popcon
```

---

### 01-configmap.yaml

민감하지 않은 환경변수 저장. docker-compose의 평문 environment와 동일.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: popcon-config
  namespace: popcon
data:
  SPRING_PROFILES_ACTIVE: "prod"
  DB_HOST: "t1-staging-rds.xxxxxxxxxx.ap-northeast-2.rds.amazonaws.com"  # RDS 엔드포인트
  DB_PORT: "3306"
  JAVA_OPTS: "-Xms512m -Xmx512m"
  REDIS_HOST: "t1-staging-redis.xxxxxx.cache.amazonaws.com"              # ElastiCache 엔드포인트
  REDIS_PORT: "6379"
  STATE_TTL_SECONDS: "300"
  OAUTH_BASE_URL: "https://stagingapi.popcon.store"
  FRONTEND_BASE_URL: "https://staging.popcon.store"
```

> RDS/ElastiCache 엔드포인트는 AWS 콘솔에서 확인:
> - RDS: `AWS Console → RDS → Databases → t1-staging-rds → Endpoint`
> - ElastiCache: `AWS Console → ElastiCache → t1-staging-redis → Primary Endpoint`

---

### 02-secret.yaml

민감 정보 저장. base64 인코딩 필요.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: popcon-secret
  namespace: popcon
type: Opaque
data:
  # echo -n "값" | base64 로 인코딩
  DB_USERNAME: <base64>
  DB_PASSWORD: <base64>
  DB_ROOT_PASSWORD: <base64>
  REDIS_PASSWORD: <base64>
```

> **주의**: secret.yaml을 Git에 커밋하면 안 됨
> SSM에서 값을 읽어 자동 생성하는 스크립트 필요 (아래 5번 참고)

---

### 03-mysql.yaml

PVC(영구 스토리지) + Deployment(컨테이너) + Service(통신) 3가지 포함.

```yaml
# PVC: MySQL 데이터 영구 보존
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pvc
  namespace: popcon
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
---
# Deployment: MySQL 컨테이너 실행
apiVersion: apps/v1
kind: Deployment
metadata:
  name: popcon-mysql
  namespace: popcon
spec:
  replicas: 1
  selector:
    matchLabels:
      app: popcon-mysql
  template:
    metadata:
      labels:
        app: popcon-mysql
    spec:
      containers:
        - name: mysql
          image: mysql:8.0
          env:
            - name: MYSQL_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: popcon-secret
                  key: DB_ROOT_PASSWORD
            - name: MYSQL_DATABASE
              valueFrom:
                secretKeyRef:
                  name: popcon-secret
                  key: DB_NAME   # secret에 DB_NAME 추가 필요
            - name: MYSQL_USER
              valueFrom:
                secretKeyRef:
                  name: popcon-secret
                  key: DB_USERNAME
            - name: MYSQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: popcon-secret
                  key: DB_PASSWORD
          volumeMounts:
            - name: mysql-data
              mountPath: /var/lib/mysql
          readinessProbe:
            exec:
              command: ["mysqladmin", "ping", "-h", "localhost"]
            initialDelaySeconds: 10
            periodSeconds: 10
      volumes:
        - name: mysql-data
          persistentVolumeClaim:
            claimName: mysql-pvc
---
# Service: 다른 Pod에서 popcon-mysql:3306으로 접근 가능
apiVersion: v1
kind: Service
metadata:
  name: popcon-mysql
  namespace: popcon
spec:
  selector:
    app: popcon-mysql
  ports:
    - port: 3306
      targetPort: 3306
  type: ClusterIP  # 클러스터 내부에서만 접근
```

---

### 04-redis.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: popcon-redis
  namespace: popcon
spec:
  replicas: 1
  selector:
    matchLabels:
      app: popcon-redis
  template:
    metadata:
      labels:
        app: popcon-redis
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          command:
            - redis-server
            - --requirepass
            - $(REDIS_PASSWORD)
          env:
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: popcon-secret
                  key: REDIS_PASSWORD
---
apiVersion: v1
kind: Service
metadata:
  name: popcon-redis
  namespace: popcon
spec:
  selector:
    app: popcon-redis
  ports:
    - port: 6379
      targetPort: 6379
  type: ClusterIP
```

---

### 05-backend.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: popcon-backend
  namespace: popcon
spec:
  replicas: 1
  selector:
    matchLabels:
      app: popcon-backend
  template:
    metadata:
      labels:
        app: popcon-backend
    spec:
      imagePullSecrets:
        - name: ecr-secret       # ECR 인증 Secret
      containers:
        - name: backend
          image: <ECR_REGISTRY>/t1-dev-app:backend-latest
          ports:
            - containerPort: 8080
          envFrom:
            - configMapRef:
                name: popcon-config   # ConfigMap 전체 주입
          env:
            - name: DB_USERNAME
              valueFrom:
                secretKeyRef:
                  name: popcon-secret
                  key: DB_USERNAME
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: popcon-secret
                  key: DB_PASSWORD
            - name: DB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: popcon-secret
                  key: DB_ROOT_PASSWORD
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: popcon-secret
                  key: REDIS_PASSWORD
          readinessProbe:
            httpGet:
              path: /actuator/health
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 5
---
apiVersion: v1
kind: Service
metadata:
  name: popcon-backend
  namespace: popcon
spec:
  selector:
    app: popcon-backend
  ports:
    - port: 8080
      targetPort: 8080
  type: ClusterIP    # Ingress를 통해 외부 노출
```

---

### 06-frontend.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: popcon-frontend
  namespace: popcon
spec:
  replicas: 1
  selector:
    matchLabels:
      app: popcon-frontend
  template:
    metadata:
      labels:
        app: popcon-frontend
    spec:
      imagePullSecrets:
        - name: ecr-secret
      containers:
        - name: frontend
          image: <ECR_REGISTRY>/t1-dev-app:frontend-latest
          ports:
            - containerPort: 3000
---
apiVersion: v1
kind: Service
metadata:
  name: popcon-frontend
  namespace: popcon
spec:
  selector:
    app: popcon-frontend
  ports:
    - port: 3000
      targetPort: 3000
  type: ClusterIP
```

---

### 07-ingress.yaml

외부 트래픽을 도메인 기반으로 각 서비스에 라우팅.
k3s는 Traefik Ingress Controller가 기본 내장됨.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: popcon-ingress
  namespace: popcon
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  rules:
    - host: app.도메인.com         # 프론트엔드 도메인
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: popcon-frontend
                port:
                  number: 3000
    - host: api.도메인.com         # 백엔드 도메인
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: popcon-backend
                port:
                  number: 8080
```

---

## 5. Secret 관리 전략

### 문제점
secret.yaml에 값을 직접 작성하면 Git에 커밋 불가.

### SSM Parameter Store 경로 구조

dev와 staging은 SSM 경로가 **분리**되어 있다.

```
/popcon/                  ← dev 환경 파라미터
  ├── DB_HOST
  ├── DB_NAME
  ├── DB_USERNAME
  ├── DB_PASSWORD
  ├── REDIS_PASSWORD
  └── ECR_REGISTRY

/popcon/staging/          ← staging 환경 파라미터 (RDS/ElastiCache 엔드포인트 등)
  ├── DB_HOST             (RDS 엔드포인트)
  ├── DB_NAME
  ├── DB_USERNAME
  ├── DB_PASSWORD
  ├── REDIS_HOST          (ElastiCache 엔드포인트)
  └── REDIS_PASSWORD
```

> **⚠️ deploy.sh `--recursive` 주의**: dev의 deploy.sh는 `/popcon` 경로를 `--recursive`로 읽는다.
> 이 경우 `/popcon/staging/DB_HOST` 같은 staging 파라미터도 함께 읽혀
> `staging/DB_HOST` 라는 엉뚱한 변수명이 .env에 들어간다.
> dev 배포 시에는 staging/ 접두사가 붙은 줄을 필터링해야 한다 (deploy.sh 참고).

### 해결 방법 — SSM에서 읽어 자동 생성

SSM에서 staging 경로의 값을 읽어 k8s Secret을 생성하는 스크립트 작성.

```bash
#!/bin/bash
# create-secret.sh (k8s/create-secret.sh)

PROJECT_NAME="popcon/staging"   # staging 환경 경로
REGION="ap-northeast-2"
NAMESPACE="popcon"

get_param() {
  aws ssm get-parameter \
    --name "/${PROJECT_NAME}/$1" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text \
    --region $REGION
}

DB_USERNAME=$(get_param DB_USERNAME)
DB_PASSWORD=$(get_param DB_PASSWORD)
DB_NAME=$(get_param DB_NAME)
REDIS_PASSWORD=$(get_param REDIS_PASSWORD)
KAKAO_CLIENT_ID=$(get_param KAKAO_CLIENT_ID)
KAKAO_CLIENT_SECRET=$(get_param KAKAO_CLIENT_SECRET)
NAVER_CLIENT_ID=$(get_param NAVER_CLIENT_ID)
NAVER_CLIENT_SECRET=$(get_param NAVER_CLIENT_SECRET)
JWT_SECRET=$(get_param JWT_SECRET)

# k8s Secret 생성
kubectl create secret generic popcon-secret \
  --from-literal=DB_USERNAME="$DB_USERNAME" \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" \
  --from-literal=DB_NAME="$DB_NAME" \
  --from-literal=REDIS_PASSWORD="$REDIS_PASSWORD" \
  --from-literal=KAKAO_CLIENT_ID="$KAKAO_CLIENT_ID" \
  --from-literal=KAKAO_CLIENT_SECRET="$KAKAO_CLIENT_SECRET" \
  --from-literal=NAVER_CLIENT_ID="$NAVER_CLIENT_ID" \
  --from-literal=NAVER_CLIENT_SECRET="$NAVER_CLIENT_SECRET" \
  --from-literal=JWT_SECRET="$JWT_SECRET" \
  --namespace=$NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f -
```

> DB_ROOT_PASSWORD는 RDS 사용 시 불필요. RDS는 생성 시 root 비밀번호를 별도 설정한다.

---

## 6. Ingress 설계

### k3s Traefik vs dev ALB

| | dev (docker-compose) | staging (k3s) | production (EKS) |
|---|---|---|---|
| Ingress | AWS ALB | Traefik (내장) | AWS ALB Controller |
| SSL | ACM 인증서 | Let's Encrypt 또는 ACM | ACM 인증서 |
| 도메인 연결 | Route53 → ALB | Route53 → EC2 IP | Route53 → ALB |

### 트래픽 흐름

```
인터넷
  ↓
Route53 (도메인)
  ↓
EC2 Public IP (포트 80/443)
  ↓
Traefik Ingress Controller
  ├── app.도메인 → popcon-frontend Service → Pod
  └── api.도메인 → popcon-backend Service → Pod
```

---

## 7. ECR 인증 전략

k3s가 ECR에서 이미지를 pull 하려면 인증이 필요.

### 방법 1 — imagePullSecrets (현재 설계)

```bash
# ECR 토큰으로 k8s Secret 생성
ECR_PASSWORD=$(aws ecr get-login-password --region ap-northeast-2)

kubectl create secret docker-registry ecr-secret \
  --docker-server=<계정ID>.dkr.ecr.ap-northeast-2.amazonaws.com \
  --docker-username=AWS \
  --docker-password=${ECR_PASSWORD} \
  --namespace=popcon
```

> ECR 토큰은 12시간마다 만료 → CronJob으로 자동 갱신 필요

### 방법 2 — EC2 IAM Role 활용 (권장)

EC2에 ECR 읽기 권한 IAM Role이 있으면
k3s에 registries.yaml 설정으로 자동 인증 가능.

```yaml
# /etc/rancher/k3s/registries.yaml
mirrors:
  "<계정ID>.dkr.ecr.ap-northeast-2.amazonaws.com":
    endpoint:
      - "https://<계정ID>.dkr.ecr.ap-northeast-2.amazonaws.com"
```

terraform-infra에서 EC2 Role에 ECR 권한이 이미 부여되어 있으므로
방법 2가 더 안정적.

---

## 8. CI/CD 연동 계획

### 현재 (dev)
```
GitHub Actions → ECR push → Watchtower 자동 감지 → 컨테이너 재시작
```

### staging (k3s) 목표
```
GitHub Actions → ECR push → kubectl rollout restart → Pod 재시작
```

### GitHub Actions 추가 작업 필요

```yaml
# deploy-staging.yml (추가 필요)
- name: Deploy to k3s
  uses: appleboy/ssh-action@v1
  with:
    host: ${{ secrets.STAGING_EC2_IP }}
    key: ${{ secrets.STAGING_SSH_KEY }}
    script: |
      kubectl rollout restart deployment/popcon-backend -n popcon
      kubectl rollout restart deployment/popcon-frontend -n popcon
```

또는 SSM으로 EC2에 명령 실행:

```yaml
- name: Deploy to k3s via SSM
  run: |
    aws ssm send-command \
      --instance-ids ${{ secrets.STAGING_INSTANCE_ID }} \
      --document-name "AWS-RunShellScript" \
      --parameters commands=["kubectl rollout restart deployment -n popcon"]
```

---

## 9. 인프라 구축 순서

### Phase 1 — terraform으로 k3s EC2 구축

```
terraform-infra에 staging 환경 추가
  → env/staging/ 디렉토리 생성
  → k3s용 EC2 (t3.medium 이상 권장)
  → 기존 dev와 동일한 모듈 사용 (vpc, ec2, ecr 공유)
```

### Phase 2 — k3s 설치 및 기본 설정

```
EC2 접속 (SSM)
  → k3s 설치
  → ECR 인증 설정 (registries.yaml)
  → kubectl 설정
```

### Phase 3 — 매니페스트 배포

```
gitops 레포에 k8s/ 디렉토리 추가
  → 00-namespace.yaml ~ 07-ingress.yaml 작성
  → create-secret.sh 실행 (SSM → k8s Secret)
  → kubectl apply -f k8s/
```

### Phase 4 — CI/CD 연동

```
GitHub Actions에 staging 배포 단계 추가
  → ECR push 후 kubectl rollout restart 실행
```

---

## 미결 사항 (설계 시 결정 필요)

| 항목 | 옵션 | 결정 필요 |
|------|------|---------|
| k3s EC2 위치 | dev와 같은 VPC? 별도 VPC? | |
| ECR 인증 | imagePullSecrets vs registries.yaml | |
| SSL 인증서 | Let's Encrypt vs ACM | |
| CI/CD 트리거 | dev와 동일 브랜치? staging 브랜치 별도? | |
| 매니페스트 위치 | gitops 레포 k8s/ ? 별도 레포? | |
