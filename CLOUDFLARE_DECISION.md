# Cloudflare 도입 의사결정 문서

> **목적**: 왜 Route53을 버리고 Cloudflare를 선택했는가
> **대상**: 중간 발표 심사위원

---

## 1. 결론 먼저

> **"보안 기능을 공짜로 얻고, AWS 비용을 줄이기 위해 Cloudflare를 선택했다."**

---

## 2. 환경별 전환 배경

### Dev → Staging으로 넘어가면서 무엇이 달라졌나

| 항목 | Dev 환경 | Staging 환경 |
|------|---------|-------------|
| 인프라 | EC2 + Docker Compose | EC2 + K3s (Kubernetes) |
| 배포 방식 | 수동 (`deploy.sh`) | GitOps (ArgoCD 자동 배포) |
| DNS | Route53 단독 | Cloudflare 프록시 |
| 보안 | 없음 (팀 내부 개발용) | WAF, DDoS 보호, 접근 제어 |
| Swagger UI | 노출됨 | Cloudflare Access로 팀 내부만 허용 |
| 도메인 | `devapi.popcon.store` | `stagingapi.popcon.store` |

Dev는 팀 내부 개발 환경으로 외부 노출을 크게 신경 쓰지 않아도 됐다.
Staging부터는 실제 사용자에게 공개되는 URL 구조와 동일하게 가져가야 했고, **보안 요구사항이 생겼다.**

---

## 3. Route53만으로는 부족한 이유

Route53은 **DNS 서비스**다. 도메인 이름을 IP로 변환하는 것이 전부다.
아래 기능들이 필요했는데, Route53에는 없다.

| 필요했던 기능 | Route53 | 대안 (AWS 조합) | Cloudflare 무료 |
|-------------|---------|----------------|----------------|
| DDoS 방어 | ❌ | AWS Shield Standard (자동 적용, 기본 수준) | ✅ 무제한 |
| WAF (웹 방화벽) | ❌ | AWS WAF: **$5/월 + 요청당 과금** | ✅ 커스텀 룰 5개 |
| CDN (정적 자원 캐싱) | ❌ | CloudFront: **별도 설정 + 요금** | ✅ 자동 |
| SSL 자동 관리 | ❌ | ACM: 무료지만 ALB와만 연동 | ✅ 자동 갱신 |
| 접근 제어 (Zero Trust) | ❌ | AWS Cognito / IAM: **복잡 + 유료** | ✅ Cloudflare Access 무료 |
| 관리자 페이지 보호 | ❌ | 직접 구현 필요 | ✅ Access 정책 설정 |

Route53을 유지하면서 동일한 수준의 보안을 구현하려면
**AWS WAF + CloudFront + Shield Advanced 조합**이 필요하고, 월 수십~수백 달러가 추가된다.

---

## 4. Cloudflare를 선택한 근거

### 4-1. 비용

```
Route53 + AWS WAF + CloudFront 구성 시 예상 비용 (월)
─────────────────────────────────────────────────
  Route53 Hosted Zone     : $0.50
  AWS WAF (웹 ACL)        : $5.00
  AWS WAF (룰 10개 기준)  : $10.00
  WAF 요청 처리 ($0.60/백만): ~$3.00 (트래픽 기준)
  CloudFront (기본)       : $0~
─────────────────────────────────────────────────
  합계                    : 약 $18.50/월 이상

Cloudflare 무료 플랜      : $0
```

같은 기능을 **무료**로 제공한다.

### 4-2. 보안

**실제 적용한 WAF 커스텀 룰 5개:**

| 룰 | 조건 | 목적 |
|----|------|------|
| 1 | 한국 외 국가 요청 차단 | 서비스 대상이 국내 사용자(카카오/네이버 로그인)이므로 해외 공격 원천 차단 |
| 2 | `/actuator`, `/h2-console` 경로 차단 | Spring Boot 내부 관리 경로 외부 노출 방지 |
| 3 | `sqlmap`, `nikto` 등 해킹 도구 User-Agent 차단 | 자동화 해킹 도구 탐지 및 차단 |
| 4 | 결제 콜백 경로(`/payment`) PortOne IP 외 차단 | 결제 위변조 방지 |
| 5 | 빈 User-Agent 요청 차단 | 정상 브라우저가 아닌 자동화 요청 차단 |

**Cloudflare Access (Zero Trust) 적용:**
- `/swagger` 경로를 팀 이메일 인증 없이는 접근 불가
- `devapi.popcon.store/swagger`, `stagingapi.popcon.store/swagger` 보호
- Prod(`api.popcon.store`)는 WAF에서 완전 차단

### 4-3. 아키텍처 단순화

```
기존 (Route53만 사용):
사용자 → Route53 → ALB → EC2
         (DNS만)

변경 후 (Cloudflare):
사용자 → Cloudflare → ALB → EC2
         ├── WAF 필터링
         ├── DDoS 보호
         ├── CDN 캐싱
         ├── SSL 처리
         └── Access 인증
```

ALB의 보안그룹을 **Cloudflare IP 대역만 허용**하도록 변경하여
ALB로의 직접 접근(Cloudflare 우회)을 물리적으로 차단했다.

---

## 5. 우려했던 점과 해결

### "Cloudflare에 트래픽을 다 보내도 되나? (벤더 의존성)"

Cloudflare를 걷어내면 다시 원래 구조로 돌아오는 데 걸리는 시간: **5분**
(네임서버를 Route53으로 되돌리고, ALB 보안그룹을 0.0.0.0/0으로 복구)

인프라 내부 구조(EC2, K3s, ALB)는 전혀 변경하지 않았기 때문에
Cloudflare 의존성은 **DNS 레이어**에만 존재한다. 탈출이 쉽다.

### "무료 플랜의 한계가 있지 않나?"

| 제한 | 내용 | 영향 |
|------|------|------|
| WAF 커스텀 룰 5개 | 5개까지만 생성 가능 | 5개로 핵심 위협은 모두 커버 가능 |
| Rate Limiting 유료 | 고급 속도 제한 유료 | JS Challenge로 대체 적용 |
| 로그 보관 24시간 | WAF 로그 24시간만 보관 | 장기 분석이 필요하면 유료 업그레이드 |

현재 서비스 규모에서는 무료 플랜으로 충분하다.
트래픽이 늘어나면 **Pro 플랜($20/월)**으로 Rate Limiting 등 기능을 추가할 수 있다.

---

## 6. 전환 후 달라진 것

| 항목 | 전환 전 | 전환 후 |
|------|---------|--------|
| Swagger 보안 | 누구나 접근 가능 | 팀 이메일 인증 필수 |
| DDoS 대응 | 없음 | Cloudflare 자동 방어 |
| 직접 ALB 접근 | 가능 | 불가 (Cloudflare IP만 허용) |
| 운영 비용 | Route53 $0.50/월 | $0 (Cloudflare 무료) |
| SSL 관리 | ACM 직접 관리 | Cloudflare 자동 처리 |

---

## 7. 요약

> **Route53은 DNS다. 우리에게 필요한 건 보안이었다.**
> Cloudflare는 DNS + WAF + CDN + Access Control을 무료로 제공하면서
> 기존 인프라(ALB, EC2, K3s)를 전혀 바꾸지 않아도 됐다.
> 비용을 줄이면서 보안 수준을 높이는 선택이었다.
