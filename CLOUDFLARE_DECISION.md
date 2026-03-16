# DNS 보안 레이어 선택 근거: Route53 → Cloudflare

> **프로젝트**: Pop-Con (팝업 스토어 예약 플랫폼)
> **작성 목적**: Dev 환경의 Route53에서 Staging/Prod 환경의 Cloudflare로 전환한 기술적 근거

---

## 1. 핵심 요약

> Route53은 DNS 역할만 수행합니다. Staging 이후부터는 보안 요구사항이 발생했고,
> 동일한 수준의 보안을 AWS 단독으로 구현하면 트래픽 규모에 따라 월 수십~수백 달러가 추가됩니다.
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

## 4. 비용 및 기능 비교

### 실제 구현한 보안 기능 기준 비교

Pop-Con에서 실제 적용한 6가지 보안 정책을 Route53+AWS로 동일하게 구현했을 때와 비교합니다.

| 보안 기능 | Route53 + AWS 구현 방법 | AWS 비용 | Cloudflare 구현 방법 | Cloudflare 비용 |
|---------|----------------------|---------|-------------------|---------------|
| SQLi · XSS · 경로탐색 · 봇 차단 (4개 룰) | AWS WAF ACL + 룰 4개 | $5 + $4 = **$9/월** | WAF 커스텀 룰 | 포함 |
| Rate Limiting (`/reservations`) | AWS WAF Rate-based Rule | **$1/월** + $0.05/만 요청 | Cloudflare Rate Limiting | 포함 |
| `/swagger` 접근 제어 (이메일 인증) | Cognito + 별도 구현 | **$0.0055/MAU + 개발 공수** | Cloudflare Access | 포함 |
| CDN | CloudFront 별도 구성 | **데이터 전송량 기준 과금** | 자동 적용 | 포함 |
| DDoS 방어 (L7) | Shield Standard(무료)는 L3/L4만 → L7는 WAF 룰 추가 필요 | **WAF 비용에 포함** | L3/L4/L7 자동 방어 | 포함 |
| SSL | ACM (무료, ALB 전용) | $0 | 범용 SSL 자동 갱신 | 포함 |
| DNS | Route53 | **$0.50/월** | 포함 | 포함 |
| **월 고정 비용 합계** | | **$10.50+/월** | | **$0 (Free) / $20 (Pro)** |

> AWS의 `/swagger` 접근 제어는 Cognito 또는 Lambda@Edge로 직접 구현해야 하며,
> Cloudflare Access처럼 대시보드에서 이메일 정책만으로 설정하는 방법이 AWS에는 없습니다.

### 트래픽에 따른 비용 변화

AWS WAF는 요청량에 비례해 비용이 증가합니다. Cloudflare는 트래픽량과 무관하게 고정 요금입니다.

> **트래픽 추정 근거**: 순간 최대 동시접속 15,000명, 대기열 polling 5초 간격 기준
> 이벤트 1회당 약 300만~540만 요청 발생으로 추정.
> 실제 수치는 서비스 오픈 후 Grafana(Prometheus) 모니터링으로 측정할 예정입니다.

| 월 요청 수 | 예상 이벤트 횟수 | Route53+AWS WAF 월 비용 | Cloudflare Pro |
|-----------|--------------|----------------------|---------------|
| 300만 | ~1회 | $10.50 + $1.80 = **$12.30** | $20 |
| 600만 | ~2회 | $10.50 + $3.60 = **$14.10** | $20 |
| 1,200만 | ~4회 | $10.50 + $7.20 = **$17.70** | $20 |
| **1,700만** | **~5회** | $10.50 + $10.20 = **$20.70** ← 역전 | $20 |
| 2,400만 | ~8회 | $10.50 + $14.40 = **$24.90** | $20 |

> 월 약 **1,700만 요청(이벤트 약 5회)** 을 초과하면 Route53+AWS 비용이 Cloudflare Pro를 역전합니다.
> 팝업 스토어 특성상 봇의 대량 요청 공격 시 AWS 비용은 예측 불가 수준으로 급증할 수 있으며,
> Cloudflare는 이 경우에도 $20 고정입니다.

### 단계별 플랜 전환 계획

| 단계 | 시점 | 플랜 | 월 비용 |
|------|------|------|--------|
| Dev / Staging | 현재 ~ 중간 발표 | Cloudflare **Free** | $0 |
| Production | 중간 발표 이후 | Cloudflare **Pro** | $20 |

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

## 6. 결론

| 관점 | 판단 |
|------|------|
| 비용 | 트래픽 증가와 무관하게 $20 고정. AWS WAF는 트래픽 급증 시 비용 예측 불가 |
| 보안 | SQLi · XSS · 경로 탐색 · 봇 차단 · Rate Limiting을 단일 플랫폼에서 통합 관리 |
| 운영 | 인프라 변경 없이 DNS 레이어 교체만으로 도입. 롤백도 네임서버 변경 한 번으로 가능 |
| 확장성 | Pro 플랜 전환으로 OWASP 룰셋, 제로데이 방어, 정교한 봇 탐지 등 프로덕션 요구사항 대응 |
