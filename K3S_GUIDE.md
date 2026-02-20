# Pop-Con k3s 배포 가이드

EC2 인스턴스 위에 k3s(경량 Kubernetes)를 설치하고 Pop-Con 백엔드(Spring Boot), MySQL, Redis를 배포하는 전체 과정입니다.

---

## 목차

1. [사전 준비](#1-사전-준비)
2. [Terraform으로 AWS 인프라 생성](#2-terraform으로-aws-인프라-생성)
3. [ECR에 이미지 빌드 및 푸시](#3-ecr에-이미지-빌드-및-푸시)
4. [EC2 접속 (SSM Session Manager)](#4-ec2-접속-ssm-session-manager)
5. [k3s 설치](#5-k3s-설치)
6. [k8s 매니페스트 배포](#6-k8s-매니페스트-배포)
7. [배포 확인](#7-배포-확인)
8. [트러블슈팅](#8-트러블슈팅)

---

## 1. 사전 준비

### 1-1. 로컬 도구 설치

#### AWS CLI

- **Windows**: [AWS CLI 설치 페이지](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)에서 MSI 설치 파일 다운로드
- **Mac**: `brew install awscli`

설치 후 자격증명 설정:

```bash
aws configure
# AWS Access Key ID: <your-access-key>
# AWS Secret Access Key: <your-secret-key>
# Default region name: ap-northeast-2
# Default output format: json
```

확인:

```bash
aws sts get-caller-identity
```

#### Terraform

- **Windows**: [Terraform 설치 페이지](https://developer.hashicorp.com/terraform/install)에서 ZIP 다운로드 후 PATH에 추가
- **Mac**: `brew tap hashicorp/tap && brew install hashicorp/tap/terraform`

#### Session Manager Plugin (EC2 SSM 접속용)

- **Windows**:
  1. [AWS Session Manager Plugin 다운로드](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)에서 `SessionManagerPluginSetup.exe` 실행
  2. 환경변수 PATH에 `C:\Program Files\Amazon\SessionManagerPlugin\bin` 추가
  3. Git Bash 재시작 후 확인: `session-manager-plugin`

- **Mac**:
  ```bash
  curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac_arm64/sessionmanager-bundle.zip" -o "sessionmanager-bundle.zip"
  unzip sessionmanager-bundle.zip
  sudo ./sessionmanager-bundle/install -i /usr/local/sessionmanagerplugin -b /usr/local/bin/session-manager-plugin
  ```

#### Docker

- **Windows**: [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/) 설치
- **Mac**: [Docker Desktop for Mac](https://www.docker.com/products/docker-desktop/) 설치 (Apple Silicon도 지원)

### 1-2. AWS 키페어 확인

EC2 접속에 사용할 키페어 이름을 확인합니다 (Terraform에서 사용):

```bash
aws ec2 describe-key-pairs --query "KeyPairs[*].KeyName" --output table
```

---

## 2. Terraform으로 AWS 인프라 생성

이 레포의 Terraform 코드로 VPC, EC2, ECR, SSM 파라미터 등을 생성합니다.

### 2-1. tfvars 파일 작성

```bash
cd terraform/env/personal
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` 파일을 열어 값 입력:

```hcl
instance_type = "t3.medium"
key_name      = "<your-key-pair-name>"   # aws ec2 describe-key-pairs로 확인한 이름
db_username   = "popcon_user"
db_password   = "popcon1234!"
db_name       = "popcon"
```

> `terraform.tfvars`는 `.gitignore`에 포함되어 있어 GitHub에 올라가지 않습니다.

### 2-2. Terraform 초기화 및 적용

```bash
cd terraform/env/personal

terraform init
terraform plan    # 생성될 리소스 미리 확인
terraform apply   # 실제 생성 (yes 입력)
```

**생성되는 리소스:**
- VPC, Public Subnet, Internet Gateway
- EC2 (Amazon Linux 2023, t3.medium, 30GB EBS)
  - SSM Agent 자동 설치 및 활성화
  - Docker 자동 설치
  - ECR 읽기 IAM 권한 부여
- ECR 레포지토리 (`dev-app`)
- SSM Parameter Store 파라미터

### 2-3. EC2 인스턴스 ID 확인

```bash
terraform output
# 또는
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*popcon*" "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].[InstanceId,PublicIpAddress]" \
  --output table
```

---

## 3. ECR에 이미지 빌드 및 푸시

### 3-1. ECR 로그인

```bash
# 계정 ID 확인
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-2

aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin \
  ${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com
```

> **Mac M1/M2 (Apple Silicon) 주의**: EC2는 x86_64이므로 빌드 시 플랫폼을 명시해야 합니다.

### 3-2. 백엔드 이미지 빌드 및 푸시

```bash
cd pop-con-backend   # 백엔드 프로젝트 폴더로 이동

ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/dev-app"

# Windows/Mac Intel
docker build -t ${ECR_URI}:backend-latest .

# Mac Apple Silicon (M1/M2)
docker buildx build --platform linux/amd64 -t ${ECR_URI}:backend-latest .

docker push ${ECR_URI}:backend-latest
```

### 3-3. (선택) 프론트엔드 이미지 빌드 및 푸시

```bash
cd pop-con-frontend

# Windows/Mac Intel
docker build -t ${ECR_URI}:frontend-latest .

# Mac Apple Silicon (M1/M2)
docker buildx build --platform linux/amd64 -t ${ECR_URI}:frontend-latest .

docker push ${ECR_URI}:frontend-latest
```

---

## 4. EC2 접속 (SSM Session Manager)

SSH 없이 AWS Systems Manager로 EC2에 접속합니다.

### 4-1. 인스턴스 ID 확인

```bash
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].[InstanceId,Tags[?Key=='Name'].Value|[0]]" \
  --output table
```

### 4-2. SSM 연결 가능 여부 확인

```bash
aws ssm describe-instance-information \
  --query "InstanceInformationList[*].[InstanceId,PingStatus]" \
  --output table
```

`PingStatus`가 `Online`이면 접속 준비 완료입니다.

> EC2 시작 직후라면 SSM Agent가 등록되는 데 1~2분 소요됩니다.

### 4-3. EC2 접속

```bash
INSTANCE_ID=<your-instance-id>

aws ssm start-session --target $INSTANCE_ID
```

접속 성공 시 `sh-4.2$` 프롬프트가 표시됩니다.

```bash
# ec2-user로 전환 (권장)
sudo su - ec2-user
```

---

## 5. k3s 설치

EC2에 접속한 상태에서 진행합니다.

### 5-1. k3s 설치

```bash
curl -sfL https://get.k3s.io | sh -
```

### 5-2. 설치 확인

```bash
sudo systemctl status k3s
sudo kubectl get nodes
```

`Ready` 상태가 되면 정상입니다:

```
NAME              STATUS   ROLES                  AGE   VERSION
ip-10-0-x-x...   Ready    control-plane,master   1m    v1.x.x+k3s1
```

### 5-3. kubectl 편의 설정 (선택)

매번 `sudo`를 입력하지 않으려면:

```bash
# kubeconfig 복사
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config

# 별칭 추가
echo 'alias k="kubectl"' >> ~/.bashrc
source ~/.bashrc
```

---

## 6. k8s 매니페스트 배포

### 6-1. git 설치 및 레포 클론

```bash
# git 설치
sudo dnf install -y git

# 레포 클론 (Public 레포)
sudo git clone https://github.com/Hyunwo/pop-con-k8s.git /opt/pop-con-k8s
```

### 6-2. ECR Secret 생성

k3s가 ECR에서 이미지를 pull 하려면 인증 정보가 필요합니다.

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-2
ECR_PASSWORD=$(aws ecr get-login-password --region $REGION)

# Namespace 먼저 생성
sudo kubectl apply -f /opt/pop-con-k8s/k8s/namespace.yaml

# ECR Secret 생성 (popcon 네임스페이스에)
sudo kubectl create secret docker-registry ecr-secret \
  --docker-server=${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com \
  --docker-username=AWS \
  --docker-password=${ECR_PASSWORD} \
  --namespace=popcon
```

> ECR 토큰은 12시간마다 만료됩니다. 만료되면 Secret을 삭제 후 재생성하세요:
> ```bash
> sudo kubectl delete secret ecr-secret -n popcon
> # 위 create 명령 재실행
> ```

### 6-3. 매니페스트 배포

```bash
sudo kubectl apply -f /opt/pop-con-k8s/k8s/
```

다음 순서로 리소스가 생성됩니다:
- `namespace.yaml` → `popcon` 네임스페이스
- `secret.yaml` → DB 자격증명
- `configmap.yaml` → 환경변수 (DB_HOST, REDIS_HOST 등)
- `mysql.yaml` → MySQL PVC + Deployment + Service
- `redis.yaml` → Redis Deployment + Service
- `backend.yaml` → Spring Boot Deployment + NodePort Service

### 6-4. 배포 상태 확인

```bash
# Pod 상태 확인 (모두 1/1 Running이 될 때까지 대기)
sudo kubectl get pods -n popcon -w

# 서비스 확인
sudo kubectl get svc -n popcon
```

Pod가 `Running` 상태가 되는 데 **약 1~3분** 소요됩니다 (이미지 pull + 앱 시작).

```
NAME                               READY   STATUS    RESTARTS
popcon-backend-xxx-xxx             1/1     Running   0
popcon-mysql-xxx-xxx               1/1     Running   0
popcon-redis-xxx-xxx               1/1     Running   0
```

---

## 7. 배포 확인

### 7-1. EC2 내부에서 확인

```bash
# 백엔드 응답 확인
curl http://localhost:30080
```

### 7-2. 외부에서 확인

EC2의 퍼블릭 IP와 NodePort(30080)로 접근합니다.

```bash
# EC2 퍼블릭 IP 확인
aws ec2 describe-instances \
  --instance-ids <your-instance-id> \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text
```

브라우저 또는 curl로 접근:

```
http://<EC2-Public-IP>:30080
```

> **포트 30080이 Security Group에 열려 있어야 합니다.** Terraform 코드에 포함되지 않은 경우 AWS 콘솔 → EC2 → 보안 그룹에서 인바운드 규칙 추가:
> - 유형: 사용자 지정 TCP
> - 포트: 30080
> - 소스: 0.0.0.0/0

---

## 8. 트러블슈팅

### SSM 접속 안 될 때

```bash
# SSM 연결 목록 확인
aws ssm describe-instance-information --output table

# PingStatus가 Online이 아니면 EC2 재시작 후 대기
aws ec2 reboot-instances --instance-ids <instance-id>
```

### Pod가 Pending 상태일 때

```bash
sudo kubectl describe pod <pod-name> -n popcon
```

- `FailedScheduling`: 리소스 부족 → EC2 타입 업그레이드 검토
- `ImagePullBackOff`: ECR Secret 오류 → Secret 재생성

### ECR 이미지 pull 실패 (ImagePullBackOff)

```bash
# Secret 확인
sudo kubectl get secret ecr-secret -n popcon

# Secret 삭제 후 재생성
sudo kubectl delete secret ecr-secret -n popcon
ECR_PASSWORD=$(aws ecr get-login-password --region ap-northeast-2)
sudo kubectl create secret docker-registry ecr-secret \
  --docker-server=<account-id>.dkr.ecr.ap-northeast-2.amazonaws.com \
  --docker-username=AWS \
  --docker-password=${ECR_PASSWORD} \
  --namespace=popcon
```

### 백엔드 Pod가 0/1로 멈출 때

```bash
# 로그 확인
sudo kubectl logs -n popcon deployment/popcon-backend

# 이벤트 확인
sudo kubectl describe pod -n popcon -l app=popcon-backend
```

- MySQL 연결 실패: MySQL Pod가 먼저 Ready 상태인지 확인
- 환경변수 오류: configmap.yaml, secret.yaml 값 확인

### 디스크 부족 (no space left on device)

```bash
df -h  # 디스크 확인

# EBS 볼륨 확장 (AWS 콘솔에서 먼저 볼륨 크기 수정 후)
sudo growpart /dev/xvda 1
sudo xfs_growfs /
```

> 이 레포의 Terraform 코드는 기본 30GB EBS로 생성하므로 일반적으로 발생하지 않습니다.

### 매니페스트 업데이트 후 재배포

```bash
cd /opt/pop-con-k8s
sudo git pull
sudo kubectl apply -f k8s/

# 특정 Deployment 재시작 (이미지 태그가 same한 경우)
sudo kubectl rollout restart deployment/popcon-backend -n popcon
```

---

## 아키텍처 요약

```
[로컬 PC]
  │
  ├─ terraform apply  →  [AWS]
  │                         ├─ VPC / Subnet / IGW
  │                         ├─ EC2 (Amazon Linux 2023, t3.medium, 30GB)
  │                         │    └─ k3s (Kubernetes)
  │                         │         ├─ popcon-mysql  (ClusterIP :3306)
  │                         │         ├─ popcon-redis  (ClusterIP :6379)
  │                         │         └─ popcon-backend (NodePort :30080)
  │                         └─ ECR (dev-app)
  │                              ├─ backend-latest
  │                              └─ frontend-latest
  │
  ├─ docker push  →  ECR
  │
  └─ aws ssm start-session  →  EC2 접속
```

| 컴포넌트 | 이미지 | 포트 | 접근 방식 |
|----------|--------|------|----------|
| MySQL | mysql:8.0 | 3306 | ClusterIP (내부 전용) |
| Redis | redis:7-alpine | 6379 | ClusterIP (내부 전용) |
| Backend | ECR backend-latest | 8080 | NodePort 30080 (외부 접근) |