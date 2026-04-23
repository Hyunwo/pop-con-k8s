# 03. Istio 구성 (담당 파트)

## 왜 Istio를 선택했나
- nginx ingress: 외부 트래픽 진입만 담당, 내부 서비스 간 제어 불가
- AWS API Gateway: 서버리스 기반, EKS 연동 복잡, 요청당 비용
- Kong: 별도 운영 필요, 과도한 복잡도
- **Istio 선택 이유**: 외부 진입 제어 + 내부 서비스 메시를 하나로 관리
  - mTLS, Circuit Breaker, AuthorizationPolicy, 트래픽 정책을 일관되게 적용 가능
  - Envoy 사이드카로 코드 수정 없이 메트릭/트레이스 자동 수집

## Envoy 사이드카 설정
모든 Pod에 자동 주입. Pod 어노테이션으로 리소스 제한:
```yaml
proxy.istio.io/config: "concurrency: 1"
sidecar.istio.io/proxyCPU: "10m"
sidecar.istio.io/proxyMemory: "64Mi"
sidecar.istio.io/proxyCPULimit: "100m"
sidecar.istio.io/proxyMemoryLimit: "128Mi"  # user 서비스는 256Mi (Coraza WASM 때문)
```

## VirtualService
- Ingress Gateway로 들어온 요청을 각 백엔드 서비스로 라우팅
- 경로 기반 라우팅:
  - /auth → backend-auth-svc
  - /user → backend-user-svc
  - /popup → backend-popup-svc
  - /auction → backend-auction-svc
  - /draw → backend-draw-svc
  - /queue → backend-queue-svc
  - /anti-macro → backend-anti-macro-svc
- popcon.store → frontend
- api.popcon.store → 8개 서비스

## DestinationRule (Circuit Breaker + Connection Pool)
설계 기준: 동시 접속자 15,000명 시나리오

```yaml
connectionPool:
  http:
    http1MaxPendingRequests: 10000
    http2MaxRequests: 10000
```

서비스별 Circuit Breaker:
| 서비스 | consecutive5xxErrors | interval | baseEjectionTime | 이유 |
|---|---|---|---|---|
| auth, user, popup | 5 | 10s | 30s | 일반 서비스 |
| auction | 3 | 10s | 30s | 중복 입찰 방지 |
| draw | 3 | 10s | 30s | 중복 응모 방지 |
| queue | 3 | 5s | 15s | 빠른 감지/복구 |
| queue-worker | 5 | 10s | 30s | 일반 |
| anti-macro | 5 | 10s | 30s | 일반 |

maxEjectionPercent: 50 (공통)

## PeerAuthentication (mTLS STRICT)
```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: popcon-prod
spec:
  mtls:
    mode: STRICT
```
- popcon-prod 네임스페이스 전체 적용
- 평문 통신 완전 차단
- 서비스 간 통신 자동 암호화
- 내부 네트워크도 신뢰 불가 구간으로 취급 (Zero Trust)

## AuthorizationPolicy
- Ingress Gateway에서만 내부 서비스 진입 허용
- SA 이름: istio-gateway-prod (주의: istio-ingressgateway-service-account 아님)
- ticket-service: X-Internal-Secret 헤더 검증으로 내부 호출만 허용
- queue-worker: HTTP 엔드포인트 없음, 큐 메시지만 소비

## ServiceEntry
- 외부 서비스 접근 시 Istio 내부에서 허용 목록 등록 필요
- ghcr.io: Coraza WASM 이미지 pull용

## 서비스 라우팅 구조
```
Ingress Gateway
├── VS /frontend  → user (frontend)    → envoy → mTLS
├── VS /auth      → auth               → envoy → mTLS
├── VS /user      → user               → envoy → mTLS
├── VS /popup     → popup              → envoy → mTLS
├── VS /auction   → auction            → envoy → mTLS
├── VS /draw      → draw               → envoy → mTLS
├── VS /queue     → queue              → envoy → mTLS
└── VS /anti-macro→ anti-macro         → envoy → mTLS

내부 전용 (Ingress 라우팅 제외):
├── ticket-service: X-Internal-Secret 헤더 검증
└── queue-worker: HTTP 없음, 큐 소비만
```

## Observability
- Envoy 사이드카에서 자동 수집
- Prometheus/Grafana: 메트릭
- Jaeger: 분산 트레이싱
- Kiali: 서비스 메시 시각화

## 포트폴리오 어필 포인트
1. nginx ingress 대비 Istio를 선택한 명확한 이유 설명 가능
2. mTLS STRICT로 Zero Trust 네트워크 구현
3. 서비스 특성에 맞는 Circuit Breaker 차등 설계 (경매/드로우는 더 엄격하게)
4. AuthorizationPolicy로 서비스 간 접근 제어
5. 코드 수정 없이 인프라 레벨에서 보안/모니터링 구현
