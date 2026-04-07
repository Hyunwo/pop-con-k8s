# Istio 도입 설계 (To-Be)

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

### 변경 후
```
ALB → Istio Ingress Gateway → VirtualService → Service → Pod
                                                          ├─ 앱 컨테이너
                                                          └─ Envoy Sidecar (자동 주입)
                                                                │
                                                                └─ mTLS, 트래픽 제어, 메트릭 수집
```

---

## 설치 구성요소

| 구성요소 | 역할 | 네임스페이스 |
|---------|------|------------|
| istiod | 컨트롤 플레인 (Pilot, Citadel, Galley) | istio-system |
| istio-ingressgateway | 외부 트래픽 진입점 (ALB 대체 또는 병행) | istio-system |
| Kiali | 서비스 메시 시각화 | istio-system |
| Jaeger | 분산 트레이싱 | istio-system |

---

## 네트워크 정책 설계

### mTLS 정책 (단계적 적용)

```yaml
# 1단계: permissive (HTTP + mTLS 모두 허용)
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: popcon-prod
spec:
  mtls:
    mode: PERMISSIVE

# 2단계: strict (mTLS만 허용)
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
# istiod webhook에 failurePolicy 설정
failurePolicy: Fail → Ignore (노드 교체 중 webhook 실패 허용)
```

---

## ArgoCD 연동 고려사항

Istio가 파드에 sidecar를 주입하면 ArgoCD가 diff로 감지해 OutOfSync 판정할 수 있음.
Application에 ignore 설정 추가 필요:

```yaml
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/template/metadata/annotations/kubectl.kubernetes.io~1last-applied-configuration
```

---

## 리소스 추가 예상

| 구성요소 | CPU Request | Memory Request |
|---------|------------|---------------|
| istiod | 500m | 2Gi |
| ingressgateway | 100m | 128Mi |
| Envoy sidecar (파드당) | 100m | 128Mi |
| Kiali | 200m | 256Mi |
| Jaeger | 200m | 256Mi |

> sidecar 17개 파드 × 128Mi = 약 2.2Gi 추가
> Karpenter가 부족한 노드를 자동 프로비저닝하므로 수동 개입 불필요
