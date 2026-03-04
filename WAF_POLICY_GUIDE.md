# WAF 정책 가이드 (Cloudflare 무료 플랜)

## WAF란?

WAF(Web Application Firewall)는 웹 서비스로 들어오는 요청을 필터링하여
악성 요청을 차단하는 보안 장치이다.

```
사용자 요청
    │
    ▼
[Cloudflare WAF]  ← 여기서 좋은 요청/나쁜 요청 판단
    │
    ├── 악성 요청 → 차단 (Block)
    └── 정상 요청 → 통과 → ALB → 백엔드
```

---

## 팝콘 서비스 특성

- **대상 사용자**: 국내 사용자 (카카오/네이버 로그인 = 한국 서비스)
- **결제**: PortOne (국내 PG사)
- **주요 위협**: 봇을 이용한 티켓 대량 구매, 해킹 시도

---

## 차단할 것 vs 허용할 것

### 차단 (Block)

| 대상 | 이유 |
|------|------|
| 한국 외 국가 트래픽 | 국내 서비스이므로 해외 접근 불필요 |
| SQL Injection 공격 | DB 탈취 시도 방어 |
| XSS 공격 | 스크립트 삽입 공격 방어 |
| 봇 자동화 도구 (sqlmap, nikto 등) | 해킹 도구 차단 |
| 빈 User-Agent 요청 | 정상 브라우저는 항상 User-Agent가 있음 |
| `/actuator`, `/h2-console` 경로 | Spring Boot 내부 관리 경로 외부 노출 차단 |

### 허용 (Allow)

| 대상 | 이유 |
|------|------|
| 한국 IP | 정상 사용자 |
| PortOne 서버 IP | 결제 완료 후 서버→서버 콜백 |
| 카카오/네이버 OAuth 콜백 경로 | 소셜 로그인 흐름 |
| Cloudflare 헬스체크 | 서버 상태 확인 |

---

## Cloudflare 커스텀 룰 5개 설계

무료 플랜에서는 커스텀 룰을 5개까지 만들 수 있다.

### 룰 1: 한국 외 국가 차단

```
조건: 요청 국가 ≠ KR (한국)
액션: Block (차단)
```

Cloudflare 대시보드 설정:
```
Security → WAF → Custom Rules → Create rule
Field: Country
Operator: does not equal
Value: Korea
Action: Block
```

> ⚠️ 주의: 개발팀 중 해외에서 접속하는 경우 해당 IP를 화이트리스트에 추가해야 함

---

### 룰 2: 내부 관리 경로 차단

Spring Boot 내부 경로가 외부에 노출되면 서버 정보가 유출된다.

```
조건: URL 경로에 /actuator 또는 /h2-console 포함
액션: Block (차단)
```

Cloudflare 대시보드 설정:
```
Field: URI Path
Operator: contains
Value: /actuator

+ OR

Field: URI Path
Operator: contains
Value: /h2-console

Action: Block
```

---

### 룰 3: 해킹 도구 차단

자동화된 해킹 도구는 특정 User-Agent를 사용한다.

```
조건: User-Agent에 sqlmap, nikto 포함 또는 User-Agent가 비어있음
액션: Block (차단)
```

Cloudflare 대시보드 설정:
```
Field: User Agent
Operator: contains
Value: sqlmap

+ OR

Field: User Agent
Operator: contains
Value: nikto

+ OR

Field: User Agent
Operator: equals
Value: (빈 값)

Action: Block
```

---

### 룰 4: 결제 콜백 경로 보호 (PortOne)

결제 완료 후 PortOne 서버가 우리 백엔드로 콜백을 보낸다.
이 경로는 PortOne 서버 IP에서만 오는 요청만 허용해야 한다.

```
조건: URL 경로에 /payment 포함
      AND 요청 IP가 PortOne IP 대역이 아님
액션: Block (차단)
```

> ⚠️ PortOne 공식 문서에서 웹훅 발신 IP를 확인 후 적용 필요
> https://developers.portone.io → 웹훅 연동 → IP 화이트리스트

---

### 룰 5: 과도한 요청 제한 (봇 티켓 구매 방어)

짧은 시간에 너무 많은 요청을 보내는 봇을 탐지한다.

```
조건: POST 요청이 5분 내 100회 초과 (동일 IP)
액션: JS Challenge (봇 여부 검증)
```

> ℹ️ Rate Limiting은 Cloudflare 유료 기능이므로
> 무료 플랜에서는 JS Challenge로 대체하거나 룰 5를 다른 용도로 사용

---

## 컴플라이언스 체크리스트

서비스 운영 전 확인해야 할 보안/법적 사항이다.

### 개인정보보호법 (PIPA)

- [ ] WAF 로그에 개인정보(이름, 전화번호, 이메일) 미포함 확인
- [ ] Cloudflare 로그 보관 기간 설정 (무료: 24시간)
- [ ] 요청 바디(body) 로깅 비활성화 확인
  - Cloudflare 대시보드 → Security → Settings → Log visibility

### HTTPS 강제 적용

- [ ] HTTP → HTTPS 자동 리다이렉트 활성화
  - Cloudflare → SSL/TLS → Edge Certificates → Always Use HTTPS: ON

### 결제 보안 (PCI-DSS 기준)

- [ ] 결제 관련 경로는 HTTPS만 허용
- [ ] PortOne 콜백 IP 화이트리스트 적용 (룰 4)
- [ ] 카드 정보가 서버에 저장되지 않는지 확인 (PortOne이 처리)

### OAuth 보안

- [ ] 카카오/네이버 개발자 콘솔에 등록된 redirect URI 확인
  ```
  https://devapi.popcon.store/auth/oauth/kakao/callback
  https://devapi.popcon.store/auth/oauth/naver/callback
  ```
- [ ] state 파라미터 검증 로직 백엔드에 구현 여부 확인 (CSRF 방어)

---

## 적용 순서

```
1단계: Cloudflare 도입 완료 (CLOUDFLARE_GUIDE.md 참고)
    │
2단계: 룰 2, 3 적용 (내부 경로 차단, 해킹 도구 차단) ← 즉시 적용 가능
    │
3단계: PortOne IP 확인 후 룰 4 적용
    │
4단계: 실제 서비스 트래픽 모니터링 후 룰 1 (국가 차단) 적용
    │    → 테스트 환경에서 먼저 검증 필요
    │
5단계: 룰 5 (봇 제한) 적용 및 모니터링
```

> ℹ️ 국가 차단(룰 1)은 마지막에 적용하는 것을 권장
> 잘못 설정하면 정상 사용자도 차단될 수 있으므로
> 트래픽 로그를 먼저 확인한 뒤 적용한다.

---

## 모니터링

Cloudflare 대시보드 → Security → Overview 에서 확인:

- **차단된 요청 수**: 룰별 차단 통계
- **위협 국가**: 어느 나라에서 공격이 오는지
- **트래픽 추이**: 비정상적인 트래픽 급증 탐지
