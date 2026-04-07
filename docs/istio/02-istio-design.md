# Istio 도입 설계 (To-Be)

> 최종 업데이트: 2026-04-07

## 도입 목적

| 기능 | 도입 전 | 도입 후 |
|------|---------|---------|
| 서비스 간 암호화 | HTTP 평문 | mTLS 자동 적용 |
| 서비스 간 인증 | 없음 | PeerAuthentication으로 인증 |
| 트래픽 관리 | 불가 | retry, timeout, circuit breaker, canary |
| 분산 트레이싱 | 없음 | Jaeger로 요청 흐름 추적 |
| 서비스 관측성 | Prometheus 메트릭만 | Kiali로 서비스 토폴로지 시각화 |

---

## 아키텍처 변경

### 변경 전
```
ALB → Service (ClusterIP) → Pod
                              └─ 앱 컨테이너만
```

### 변경 후 (ALB 유지 + Istio 서비스 메시)
```
사용자 → Cloudflare → ALB → Service (ClusterIP) → Pod
                                                    ├─ 앱 컨테이너
                                                    └─ Envoy Sidecar (자동 주입)
                                                          │
                                                          └─ mTLS, 트래픽 제어, 메트릭 수집
```

> **Istio Ingress Gateway를 사용하지 않는 이유**: ALB는 Cloudflare + WAF + ACM 인증서를 이미 관리하고 있음.
> Istio는 서비스 간(East-West) 트래픽 제어에만 집중. Kiali/Jaeger는 사이드카가 수집한 데이터를 사용하므로 ALB 유지와 무관하게 동작.

---

## 설치 구성요소

| 구성요소 | 역할 | 네임스페이스 | 설치 방식 | 상태 |
|---------|------|------------|---------|------|
| istio-base | CRD, ClusterRole 등 기반 리소스 | istio-system | ArgoCD GitOps (Helm) | ✅ Synced/Healthy |
| istiod | 컨트롤 플레인 (Pilot, Citadel, Galley) | istio-system | ArgoCD GitOps (Helm) | ✅ Synced/Healthy |
| Kiali | 서비스 메시 시각화 | istio-system | 예정 | ⏳ |
| Jaeger | 분산 트레이싱 | istio-system | 예정 | ⏳ |

> istio-ingressgateway는 도입 계획에서 제외 (ALB 유지)

---

## 네트워크 정책 설계

### mTLS 정책 (단계적 적용)

```yaml
# 1단계: permissive (HTTP + mTLS 모두 허용) — 검증 기간
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: popcon-prod
spec:
  mtls:
    mode: PERMISSIVE

# 2단계: strict (mTLS만 허용) — 검증 완료 후
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: popcon-prod
spec:
  mtls:
    mode: STRICT
```

### VirtualService 설계 (예시: auth)

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: backend-auth
  namespace: popcon-prod
spec:
  hosts:
    - backend-auth-svc
  http:
    - retries:
        attempts: 3
        perTryTimeout: 5s
        retryOn: 5xx,reset,connect-failure
      timeout: 15s
      route:
        - destination:
            host: backend-auth-svc
            port:
              number: 8080
```

### DestinationRule 설계 (Circuit Breaker 예시)

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: backend-auth
  namespace: popcon-prod
spec:
  host: backend-auth-svc
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100
      http:
        http1MaxPendingRequests: 100
        http2MaxRequests: 1000
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 30s
      baseEjectionTime: 30s
```

---

## Karpenter 연동 고려사항

Karpenter가 노드를 교체할 때 sidecar injection webhook 타임아웃 방지:

```yaml
# values-istiod.yaml 설정
pilot:
  autoscaleEnabled: false
  replicaCount: 1
meshConfig:
  defaultConfig:
    holdApplicationUntilProxyStarts: true  # sidecar 준비 후 앱 시작
```

> spot 환경에서 노드 교체 중 webhook 실패 시에도 파드 기동 허용하도록 `Fail → Ignore` 정책 적용됨

---

## ArgoCD 연동 고려사항

istiod 인증서 갱신 시 caBundle 값이 변경되어 OutOfSync 발생 → ignoreDifferences 처리:

```yaml
# istiod-app.yaml
ignoreDifferences:
  - group: admissionregistration.k8s.io
    kind: ValidatingWebhookConfiguration
    name: istio-validator-istio-system
    jqPathExpressions:
      - .webhooks[].clientConfig.caBundle

# istio-base-app.yaml
ignoreDifferences:
  - group: apiextensions.k8s.io
    kind: CustomResourceDefinition
    jqPathExpressions:
      - .spec.versions[].schema.openAPIV3Schema
  - group: admissionregistration.k8s.io
    kind: ValidatingWebhookConfiguration
    name: istiod-default-validator
    jqPathExpressions:
      - .webhooks
```

---

## 리소스 추가 예상

| 구성요소 | CPU Request | Memory Request |
|---------|------------|---------------|
| istiod | 500m | 2Gi |
| Envoy sidecar (파드당) | 100m | 128Mi |
| Kiali | 200m | 256Mi |
| Jaeger | 200m | 256Mi |

> sidecar 17개 파드 × 128Mi = 약 2.2Gi 추가
> Karpenter가 부족한 노드를 자동 프로비저닝하므로 수동 개입 불필요
