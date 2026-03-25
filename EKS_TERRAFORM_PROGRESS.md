# EKS Terraform 작업 진행 기록

> 작성일: 2026-03-25
> 담당: EKS 전환 및 ArgoCD 담당자
> 브랜치: terraform-infra `prod`

---

## 1. 작업 개요

Staging(k3s) → Prod(EKS) 전환을 위한 Terraform 인프라 코드 작성 및 초기 테스트.

### 생성된 파일 구조

```
terraform-infra/
  modules/
    eks/
      main.tf        ← EKS 클러스터, 노드그룹, Security Group
      irsa.tf        ← ALB Controller / External Secrets IRSA Role
      variables.tf
      outputs.tf
  env/
    prod/
      backend.tf     ← S3 원격 state (t1-terraform-state-bucket-260213)
      provider.tf    ← AWS provider, default_tags (Env=prod)
      main.tf        ← NAT GW, ECR/S3 참조, EKS/RDS/ElastiCache/SSM/Bastion 모듈
      variables.tf
      terraform.tfvars
      outputs.tf
  .github/workflows/
    terraform-plan.yml   ← prod 브랜치 PR 트리거 추가
    terraform-apply.yml  ← prod 브랜치 push 트리거 추가
```

---

## 2. 주요 설계 결정

### EKS 구성
| 항목 | 값 | 이유 |
|------|-----|------|
| Kubernetes 버전 | 1.35 | AWS EKS 최신 지원 버전 |
| 노드 인스턴스 | t3.medium | staging 대비 스펙 유지 |
| 노드 수 | desired=2, min=2, max=4 | 팀 협의 결정 |
| endpoint_public_access | true | 초기 구축 편의성, 안정화 후 false로 변경 예정 |
| endpoint_private_access | true | VPC 내부 접근 항상 허용 |

### IRSA
- **ALB Controller**: K8s Ingress → AWS ALB 자동 생성/관리 (staging에서 Terraform 직접 생성하던 방식 대체)
- **External Secrets**: SSM Parameter Store → K8s Secret 자동 동기화

### ECR
- 6개 레포지토리 모두 기존 AWS에 존재 → `data "aws_ecr_repository"` 로 참조만 (재생성 없음)
- staging과 동일 레포 공유, 이미지 태그로 환경 구분 (SHORT_SHA 방식 유지)

### GitHub Actions
- `terraform-plan.yml`: PR → prod 브랜치 대상일 때 실행, 결과를 PR 코멘트로 출력
- `terraform-apply.yml`: prod 브랜치 merge 시 실행
- GitHub Environment `prod` 생성 필요 (DB/Redis 비밀번호 환경별 분리)

---

## 3. 발생한 이슈 및 해결

### 3-1. prod 브랜치 직접 push → apply 즉시 실행
**원인**: PR 없이 prod 브랜치에 직접 push하면 `terraform-apply.yml`이 바로 트리거됨

**교훈**: prod 변경은 반드시 feature 브랜치 → prod PR → 머지 순서로 진행해야 함

**추후 조치**: GitHub Branch Protection Rule 설정 예정 (팀 협의 후)

---

### 3-2. apply 중단으로 인한 state 불일치
**원인**: apply 도중 워크플로우 취소 → AWS에 리소스는 생성됐지만 state에 일부 미기록

**발생 에러**:
```
ResourceInUseException: Cluster already exists with name: t1-prod-eks
DBInstanceAlreadyExists: DB instance already exists
Resource.AlreadyAssociated: route table association conflicts
```

**해결**: `terraform import`로 누락된 리소스를 state에 재등록

---

### 3-3. EKS 클러스터 재생성 (bootstrap_self_managed_addons)
**원인**: AWS provider v6에서 `bootstrap_self_managed_addons` 기본값이 `true`인데, 기존 클러스터는 `false`로 생성됨 → forces replacement

**영향**: EKS 클러스터 삭제 후 재생성 (노드그룹도 함께)

**결론**: 클러스터에 아무것도 배포되지 않은 상태였으므로 재생성 진행

---

### 3-4. route_table_association 충돌
**원인**: staging과 prod가 동일한 private subnet 공유 (dev VPC 기반)
- staging의 route table이 이미 private subnet에 연결되어 있음
- subnet은 route table을 하나만 가질 수 있어 충돌 발생

**임시 해결**: `aws_route_table_association` 제거 → staging NAT Gateway 경유로 인터넷 접근

**근본 해결 (예정)**: 팀 계정 이동 시 prod 전용 VPC 구성 → 충돌 없이 독립 운영

---

### 3-5. IAM 권한 부족 (강사 계정 제한)
**증상**: `eks:DescribeNodegroup`, `eks:DescribeCluster` 권한 없음 → terraform destroy 실패

**해결**: `terraform state rm`으로 해당 리소스를 state에서 제거 후 진행

---

### 3-6. RDS deletion_protection
**원인**: RDS 모듈 기본값 `deletion_protection = true`, `skip_final_snapshot = false`

**해결**: env/prod/main.tf에 `skip_final_snapshot = true`, `deletion_protection = false` 추가 후 apply → destroy

---

## 4. 현재 상태 (2026-03-25 기준)

| 리소스 | 상태 | 비고 |
|--------|------|------|
| Terraform 코드 (modules/eks) | 완료 | prod 브랜치 push됨 |
| Terraform 코드 (env/prod) | 완료 | prod 브랜치 push됨 |
| GitHub Environment (prod) | 완료 | secrets 등록됨 |
| AWS 리소스 | **전체 destroy됨** | 3단계 VPC 재구성 전 정리 |

---

## 5. 다음 단계 (3단계: VPC 재구성)

### 배경
강사 계정에서는 staging과 동일한 dev VPC 사용 → subnet 충돌 발생
팀 계정으로 이동 시 prod 전용 환경이 필요하므로, 지금부터 VPC부터 독립 구성하기로 결정

### 필요 작업

**1. modules/vpc/ 모듈 생성**
```
modules/
  vpc/
    main.tf      ← VPC, Public/Private Subnet, IGW, Route Table
    variables.tf
    outputs.tf
```

**2. env/prod/main.tf 수정**
```hcl
# 변경 전: dev tfstate에서 VPC 참조
data "terraform_remote_state" "dev" { ... }

# 변경 후: 직접 VPC 생성
module "vpc" {
  source = "../../modules/vpc"
  name   = "t1-prod"
  ...
}
```

**3. Subnet 태그 추가 (ALB Controller 필수)**
```
Public Subnet:  kubernetes.io/role/elb = 1
Private Subnet: kubernetes.io/role/internal-elb = 1
```

### 팀 계정 이동 시 변경 사항
- S3 backend bucket 변경
- AWS credentials 변경
- 코드 구조는 그대로 유지

---

## 6. 참고사항

### prod 브랜치 운영 방식
```
feature/* 브랜치 → prod PR 생성
                     ↓
               terraform plan 자동 실행 (PR 코멘트)
                     ↓
               팀원 리뷰 후 머지
                     ↓
               terraform apply 자동 실행
```

### 로컬 terraform 실행 시 필수 환경변수
```bash
export AWS_PROFILE=team1
export TF_VAR_db_username=값
export TF_VAR_db_password=값
export TF_VAR_db_root_password=값
export TF_VAR_redis_password=값
```
