---
name: PopCon Istio 구성 상세
description: 사용자가 담당한 Istio 파트 상세 내용 - 포트폴리오/이력서용
type: project
originSessionId: 787fcbbe-15a1-4745-9de1-ac0a2ea8f402
---
# PopCon Istio 구성 (담당 파트)

## 핵심 구성 요소

### 1. VirtualService
- Ingress Gateway로 들어온 요청을 각 백엔드 서비스로 라우팅
- 경로 기반 라우팅: /auth → backend-auth-svc, /user → backend-user-svc 등
- popcon.store → frontend, api.popcon.store → 8개 서비스

### 2. DestinationRule
- 서비스별 Circuit Breaker + Connection Pool 설정
- http1MaxPendingRequests: 10000
- http2MaxRequests: 10000
- 경매/드로우: consecutive5xxErrors: 3 (정합성 중요 → 빠른 차단)
- 나머지: consecutive5xxErrors: 5
- baseEjectionTime: 30s, maxEjectionPercent: 50
- 대기열: interval: 5s (빠른 감지), baseEjectionTime: 15s (빠른 복구)

### 3. PeerAuthentication (mTLS STRICT)
- popcon-prod 네임스페이스 전체 적용
- 평문 통신 완전 차단
- 서비스 간 통신 자동 암호화
- 내부 네트워크도 신뢰 불가 구간으로 취급

### 4. AuthorizationPolicy
- Ingress Gateway에서만 내부 서비스 진입 허용
- ticket-service: Ingress 라우팅 제외, X-Internal-Secret 헤더 검증으로 내부 호출만 허용
- queue-worker: HTTP 엔드포인트 없음, 큐 메시지만 소비

### 5. Envoy 사이드카 설정 (Pod 어노테이션)
- sidecar.istio.io/proxyCPU: "10m"
- sidecar.istio.io/proxyMemory: "64Mi"
- sidecar.istio.io/proxyCPULimit: "100m"
- sidecar.istio.io/proxyMemoryLimit: "128Mi" (user 서비스는 256Mi로 상향)
- proxy.istio.io/config: "concurrency: 1"

## 트러블슈팅

### AuthorizationPolicy SA 이름 불일치
- 현상: 정책 적용 후 Ingress Gateway → 내부 서비스 통신 전부 차단
- 원인: SA 이름 `istio-ingressgateway-service-account` → 실제는 `istio-gateway-prod`
- 해결: 올바른 SA 이름으로 수정

### Envoy 사이드카 OOMKilled (Coraza WASM)
- 현상: backend-user istio-proxy 재시작 반복
- 원인: Coraza WASM 바이너리 로드 시 150~200Mi 필요한데 limit 128Mi
- 해결: proxyMemoryLimit 128Mi → 256Mi 상향

## 포트폴리오 어필 포인트
- nginx ingress 대신 Istio 선택: 외부 진입 + 내부 서비스 메시를 하나로 관리
- mTLS STRICT로 내부 통신 전 구간 암호화 (Zero Trust 네트워크)
- Circuit Breaker로 서비스별 장애 전파 차단 설계
- Envoy 사이드카로 코드 수정 없이 메트릭/트레이스 자동 수집
- Kiali로 서비스 메시 시각화 및 모니터링
