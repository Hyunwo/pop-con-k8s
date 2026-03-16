# DNS 보안 레이어 선택 근거: Route53 → Cloudflare

> **프로젝트**: Pop-Con (팝업 스토어 예약 플랫폼)
> **작성 목적**: Dev 환경의 Route53에서 Staging/Prod 환경의 Cloudflare로 전환한 기술적 근거

---

## 1. 핵심 요약

> Route53은 DNS 역할만 수행합니다. Staging 이후부터는 보안 요구사항이 발생했고,
> 동일한 수준의 보안을 AWS 단독으로 구현하면 월 $18.50 이상이 추가됩니다.
> Cloudflare는 WAF · DDoS 방어 · CDN · 접근 제어를 Free 플랜에서 제공하며,
> 프로덕션 전환 시 Pro 플랜($20/월)으로도 AWS 조합보다 저렴하게 동등 이상의 보안을 유지합니다.

---

## 2. 환경별 전환 배경

Dev 환경은 팀 내부 개발 목적으로 외부 보안 위협에 노출될 가능성이 낮아 Route53 단독으로 충분했습니다.
Staging부터는 실제 운영과 동일한 도메인 구조와 보안 정책을 적용해야 했습니다.

| 항목 | Dev | Staging | Prod (예정) |
|------|-----|---------|------------|
| 인프라 | EC2 + Docker Compose | EC2 + K3s | **AWS EKS** |
| 배포 방식 | 수동 스크립트 | GitOps (ArgoCD) | GitOps (ArgoCD) |
| DNS | Route53 | Cloudflare | Cloudflare |
| WAF | 없음 | Cloudflare Free | Cloudflare Pro |
| Swagger 접근 | 공개 | 팀 이메일 인증 필요 | WAF 차단 (완전 비공개) |
| 도메인 | `devapi.popcon.store` | `stagingapi.popcon.store` | `api.popcon.store` |

---

## 3. Route53 단독 구성의 한계

Route53은 DNS 서비스로, 도메인-IP 변환만 담당합니다.
아래 보안 요구사항을 Route53 단독으로는 충족할 수 없습니다.

| 요구사항 | Route53 | AWS 대안 (추가 비용 발생) | Cloudflare Free |
|---------|---------|------------------------|----------------|
| DDoS 방어 | ❌ | Shield Advanced: **$3,000/월** | ✅ 무제한 |
| WAF | ❌ | AWS WAF: **$5/월 + 룰당 $1/월** | ✅ 커스텀 룰 5개 |
| CDN | ❌ | CloudFront: **별도 구성 + 요금** | ✅ 자동 적용 |
| 관리자 페이지 접근 제어 | ❌ | Cognito: **$0.0055/MAU** | ✅ Cloudflare Access |
| Rate Limiting | ❌ | **$0.05/만 요청** | ✅ 기본 제공 |

---

## 4. 비용 비교 분석

### 단계별 플랜 전환 계획

| 단계 | 시점 | 플랜 | 월 비용 |
|------|------|------|--------|
| Dev / Staging | 현재 ~ 중간 발표 | Cloudflare **Free** | $0 |
| Production | 중간 발표 이후 | Cloudflare **Pro** | $20 |

### AWS 조합 vs Cloudflare 상세 비교

| 항목 | AWS 조합 | Cloudflare Free | Cloudflare Pro |
|------|---------|----------------|---------------|
| DNS | Route53: **$0.50/월** | 포함 | 포함 |
| SSL | ACM (ALB 전용) | 범용 SSL 인증서 | 범용 SSL 인증서 |
| WAF 규칙 수 | 룰 1개당 **$1.00/월** | **5개** | **20개** |
| Cloudflare Rules | - | **70개** | **225개** |
| WAF 취약점 방어 | AWS WAF Managed Rules 별도 | 심각도 높은 취약성 보호 | OWASP 포함 광범위 보호 |
| 제로데이 위협 방어 | ❌ | ❌ | ✅ |
| CDN | CloudFront 별도 구성 | 전역 CDN 포함 | 전역 CDN + Cache Analytics |
| 이미지 최적화 | CloudFront 별도 설정 | ❌ | ✅ 원클릭 적용 |
| DDoS 방어 | Shield Advanced: **$3,000/월** | 무제한 (앱 레이어) | 무제한 (앱 레이어) |
| Rate Limiting (IP 기반) | **$0.05/만 요청** | ✅ 기본 제공 | ✅ 기본 제공 |
| 봇 감지 | 별도 구성 필요 | 일반 봇 감지·챌린지 | 정교한 봇 탐지·챌린지 |
| 기술 지원 | - | 커뮤니티 | 티켓 + 커뮤니티 + 개발자 문서 |
| **월 합계** | **$18.50 ~ $3,000+** | **$0** | **$20** |

### Pro 플랜 전환 시 추가되는 기능

중간 발표 이후 프로덕션(EKS) 전환과 함께 Pro 플랜을 적용할 예정입니다.

| 기능 | Free | Pro | 도입 목적 |
|------|------|-----|---------|
| WAF 규칙 수 | 5개 | **20개** | 서비스 확장에 따른 룰 추가 대응 |
| Cloudflare Rules | 70개 | **225개** | 세밀한 트래픽 제어 |
| WAF 취약점 방어 | 심각도 높은 취약성 | OWASP 포함 광범위 | 알려진 공격 패턴 자동 차단 |
| 제로데이 위협 방어 | ❌ | ✅ | 신규 취약점 선제 대응 |
| 봇 감지 수준 | 일반 봇 | 정교한 봇 | 고도화된 자동화 구매 봇 방어 |
| 이미지 최적화 | ❌ | ✅ 원클릭 | 팝업 스토어 이미지 로딩 최적화 |
| Cache Analytics | ❌ | ✅ | CDN 캐시 히트율 분석 및 최적화 |
| 기술 지원 | 커뮤니티 | 티켓 지원 | 프로덕션 장애 대응 |

---

## 5. 실제 적용한 보안 정책

### WAF 룰

| # | 유형 | 방어 대상 |
|---|------|---------|
| 1 | SQLi 차단 | SQL Injection을 통한 DB 탈취 시도 |
| 2 | XSS 차단 | 악성 스크립트 삽입 공격 |
| 3 | 경로 탐색 차단 | `../` 패턴을 이용한 디렉토리 트래버설 |
| 4 | 악성 봇 · 스캐너 차단 | sqlmap, nikto 등 자동화 해킹 도구 |
| 5 | 관리자 페이지 보호 | `/swagger` Cloudflare Access 인증 |
| 6 | Rate Limit (예약 API) | `/reservations` 봇 티켓 대량 구매 방어 |

### Cloudflare Access (Zero Trust)

`/swagger` 경로는 Cloudflare Access 정책으로 보호됩니다.

| 환경 | 정책 |
|------|------|
| `devapi.popcon.store/swagger` | 팀 이메일 인증 필요 |
| `stagingapi.popcon.store/swagger` | 팀 이메일 인증 필요 |
| `api.popcon.store/swagger` | WAF에서 완전 차단 (접근 불가) |

### 아키텍처 변화

```
[기존]
사용자 ──→ Route53 (DNS) ──→ ALB ──→ EC2
            DNS 변환만 수행

[현재]
사용자 ──→ Cloudflare ──→ ALB ──→ EC2
            ├── WAF (공격 필터링)
            ├── DDoS 방어
            ├── CDN (정적 자원 캐싱)
            ├── SSL/TLS 처리
            └── Access (관리자 인증)
```

ALB 보안그룹을 Cloudflare IP 대역만 허용하도록 설정하여,
Cloudflare를 우회한 ALB 직접 접근을 차단했습니다.

---

## 6. 벤더 의존성 검토

Cloudflare 도입 시 가장 먼저 검토한 리스크는 벤더 의존성입니다.

Cloudflare 레이어는 **DNS 앞단**에만 위치합니다.
EC2, K3s, ALB 등 내부 인프라는 변경하지 않았기 때문에
Cloudflare를 제거하면 네임서버 변경과 ALB 보안그룹 복구만으로 원래 구조로 복귀할 수 있습니다.

---

## 7. 결론

| 관점 | 판단 |
|------|------|
| 비용 | AWS WAF + CloudFront 조합 대비 Free 구간 $18.50, Pro 전환 후에도 $20으로 절감 |
| 보안 | SQLi · XSS · 경로 탐색 · 봇 차단 · Rate Limiting을 단일 플랫폼에서 통합 관리 |
| 운영 | 인프라 변경 없이 DNS 레이어 교체만으로 도입, 롤백 비용 최소 |
| 확장성 | Pro 플랜 전환으로 OWASP 관리형 룰셋, 무제한 WAF 룰 등 프로덕션 요구사항 대응 |
