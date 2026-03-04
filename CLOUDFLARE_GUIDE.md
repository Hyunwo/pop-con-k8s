# Cloudflare 도입 가이드 (WAF + CDN + SSL)

## 개요

AWS WAF 비용 절감 및 DDoS 보호를 위해 Cloudflare 무료 플랜을 도입한다.

### 아키텍처 변화

**기존:**
```
사용자 → Route53 → ALB (ACM 인증서) → EC2
```

**Cloudflare 도입 후:**
```
사용자 → Cloudflare (WAF/CDN/SSL) → ALB → EC2
```

### 실제로 변경되는 것 (2가지만)

| 변경 항목 | 내용 |
|----------|------|
| **네임서버** | Route53 네임서버 → Cloudflare 네임서버로 변경 |
| **ALB 보안그룹** | `0.0.0.0/0` → Cloudflare IP 대역만 허용 |

### 그대로 유지되는 것

| 유지 항목 | 이유 |
|----------|------|
| **ACM 인증서** | ALB에 붙은 인증서 그대로 사용 (Full Strict 모드) |
| **ALB** | 삭제/교체 없음, 보안그룹만 수정 |
| **Route53 Hosted Zone** | DNS 레코드는 Cloudflare로 이전하지만 호스팅 존은 유지 가능 |
| **EC2 / k3s** | 변경 없음 |

> 느낌상: "Cloudflare를 앞단에 추가하고, ALB에 직접 접근 못 하게 막는 것"이 전부다.

### 무료 플랜으로 제공되는 것

| 기능 | 제공 여부 |
|------|-----------|
| DDoS 보호 | 무제한 |
| CDN (정적 자원 캐싱) | ✅ |
| SSL/TLS | ✅ |
| WAF 커스텀 룰 | 5개 |
| OWASP Managed Rules | 일부 |
| Rate Limiting | ❌ (유료) |

---

## SSL 모드 선택

Cloudflare와 Origin(ALB) 간 SSL 처리 방식을 결정한다.

```
Flexible:      사용자 ←HTTPS→ Cloudflare ←HTTP→  ALB  (보안 취약, 비권장)
Full:          사용자 ←HTTPS→ Cloudflare ←HTTPS→ ALB  (ACM 인증서 그대로 사용)
Full (Strict): 사용자 ←HTTPS→ Cloudflare ←HTTPS→ ALB  (ACM 인증서 유효성 검증)
```

**권장: Full (Strict)**
- ACM 인증서는 공인 CA(Amazon)가 발급 → Cloudflare가 신뢰
- 현재 구조 변경 없이 적용 가능

---

## 세팅 단계

### 1단계: Cloudflare 가입 및 도메인 추가

1. [cloudflare.com](https://cloudflare.com) 가입
2. `Add a Site` → 도메인 입력 (예: `popcon.store`)
3. **Free 플랜** 선택
4. Cloudflare가 기존 Route53 DNS 레코드 자동 스캔

---

### 2단계: DNS 레코드 설정

Cloudflare가 스캔한 A 레코드를 삭제하고 CNAME으로 교체한다.
ALB IP는 언제든 변경될 수 있으므로 반드시 CNAME을 사용해야 한다.

**삭제:** A 레코드 (고정 IP)

**추가:** CNAME 레코드 (ALB DNS 직접 참조)

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| CNAME | dev | `t1-dev-ec2-alb-xxxxxxxxxx.ap-northeast-2.elb.amazonaws.com` | Proxied ☁️ |
| CNAME | devapi | `t1-dev-ec2-alb-xxxxxxxxxx.ap-northeast-2.elb.amazonaws.com` | Proxied ☁️ |
| CNAME | staging | `t1-staging-ec2-alb-xxxxxxxxxx.ap-northeast-2.elb.amazonaws.com` | Proxied ☁️ |
| CNAME | stagingapi | `t1-staging-ec2-alb-xxxxxxxxxx.ap-northeast-2.elb.amazonaws.com` | Proxied ☁️ |

> ALB DNS 주소 확인 명령어:
> ```bash
> aws elbv2 describe-load-balancers --region ap-northeast-2 \
>   --query "LoadBalancers[*].{Name:LoadBalancerName,DNS:DNSName}" --output table
> ```

**Proxied(주황 구름)** 반드시 활성화 → Cloudflare WAF/CDN 적용

---

### 3단계: SSL 모드 설정

Cloudflare 대시보드 → **SSL/TLS** → **Full (Strict)** 선택

---

### 4단계: ALB 보안그룹 수정 (Terraform)

Cloudflare IP 대역만 허용하여 직접 접근을 차단한다.

`terraform-infra/modules/ec2/alb.tf` 수정:

```hcl
# Cloudflare IPv4 대역만 허용 (직접 접근 차단)
# https://www.cloudflare.com/ips/
ingress {
  description = "HTTP from Cloudflare"
  from_port   = 80
  to_port     = 80
  protocol    = "tcp"
  cidr_blocks = [
    "173.245.48.0/20",
    "103.21.244.0/22",
    "103.22.200.0/22",
    "103.31.4.0/22",
    "141.101.64.0/18",
    "108.162.192.0/18",
    "190.93.240.0/20",
    "188.114.96.0/20",
    "197.234.240.0/22",
    "198.41.128.0/17",
    "162.158.0.0/15",
    "104.16.0.0/13",
    "104.24.0.0/14",
    "172.64.0.0/13",
    "131.0.72.0/22"
  ]
}

ingress {
  description = "HTTPS from Cloudflare"
  from_port   = 443
  to_port     = 443
  protocol    = "tcp"
  cidr_blocks = [
    "173.245.48.0/20",
    "103.21.244.0/22",
    "103.22.200.0/22",
    "103.31.4.0/22",
    "141.101.64.0/18",
    "108.162.192.0/18",
    "190.93.240.0/20",
    "188.114.96.0/20",
    "197.234.240.0/22",
    "198.41.128.0/17",
    "162.158.0.0/15",
    "104.16.0.0/13",
    "104.24.0.0/14",
    "172.64.0.0/13",
    "131.0.72.0/22"
  ]
}
```

Terraform 적용:
```bash
cd terraform-infra/env/dev
terraform plan
terraform apply
```

---

### 5단계: 네임서버 변경

Cloudflare가 제공하는 네임서버 2개를 도메인 등록 기관에서 변경한다.

```
기존: ns-xxx.awsdns-xx.com (Route53)
변경: xxx.ns.cloudflare.com (Cloudflare)
```

전파 시간: 수분 ~ 최대 24시간

---

### 6단계: 검증

```bash
# Cloudflare 경유 확인
curl -I https://dev.popcon.store

# 응답 헤더에 아래가 있으면 성공
# cf-ray: xxxxxxxxxxxxxxxx
# server: cloudflare
```

---

## 주의사항

### 실제 클라이언트 IP 처리

Cloudflare 뒤에서는 모든 요청이 Cloudflare IP로 들어온다.
실제 클라이언트 IP는 `CF-Connecting-IP` 헤더에 담겨온다.

Spring Boot에서 실제 IP를 올바르게 읽으려면 `application-prod.yml`에 추가:

```yaml
server:
  forward-headers-strategy: framework
```

또는 `application.properties`:
```properties
server.forward-headers-strategy=framework
```

### OAuth 리다이렉트 URI

카카오/네이버 개발자 콘솔에 등록된 redirect URI가 Cloudflare 도메인과 일치해야 한다.

```
https://devapi.popcon.store/auth/oauth/kakao/callback
https://devapi.popcon.store/auth/oauth/naver/callback
```

### Route53 정리 (선택)

Cloudflare로 완전 이전 후 Route53 Hosted Zone 삭제 가능 (월 $0.50 절감).

`terraform-infra/env/dev/main.tf`에서 `dns` 모듈 제거 후 `terraform apply`.

---

## 전체 흐름 요약

```
[도메인 등록 기관]
      │ 네임서버 변경 (Route53 → Cloudflare)
      ▼
[Cloudflare]
  ├── WAF: 악성 요청 차단
  ├── CDN: 정적 자원 캐싱
  ├── SSL: 사용자 ↔ Cloudflare HTTPS 처리
  └── 프록시: Cloudflare IP로 ALB에 포워딩
      │
      │ HTTPS (Cloudflare IP 대역만 허용)
      ▼
[ALB] (AWS)
  ├── dev.popcon.store    → EC2:3000 (프론트엔드)
  ├── devapi.popcon.store → EC2:8080 (백엔드)
  ├── staging.popcon.store    → staging EC2:3000
  └── stagingapi.popcon.store → staging EC2:8080
      │
      ▼
[EC2 / k3s]
  ├── Frontend (Next.js)
  ├── Backend (Spring Boot)
  ├── MySQL / RDS
  └── Redis / ElastiCache
```
