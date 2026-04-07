# Istio 마이그레이션 계획서

> 최종 업데이트: 2026-04-07

## 사전 준비

- [x] TopologySpreadConstraints DoNotSchedule + PDB 적용
  - 모든 8개 서비스에 `whenUnsatisfiable: DoNotSchedule` 적용
  - PodDisruptionBudget (minAvailable: 1) 전 서비스 적용 확인
- [x] t3a.xlarge SPOF 제거 → t3a.large 2개 체제 전환
- [x] 현재 서비스 간 통신 흐름 검증 (17개 파드 모두 Running 확인)
- [ ] memory limit 768Mi → 1Gi 상향 (sidecar 여유 확보) — 선택적, Karpenter 자동 프로비저닝으로 대체 가능
- [ ] JVM MaxRAMPercentage 75% → 60% 조정 — sidecar 도입 후 OOM 모니터링 후 결정

---

## 단계별 진행

### 1단계: Istio 설치 ✅ 완료 (2026-04-07)

**ArgoCD GitOps 방식으로 설치** (Helm 직접 설치 대신)

```
gitops/prod/istio/
  kustomization.yaml
  argocd-apps/
    istio-base-app.yaml    → istio-base v1.29.1 (CRD 등 기반 리소스)
    istiod-app.yaml        → istiod v1.29.1 (컨트롤 플레인)
  helm-values/
    values-istiod.yaml     → pilot 리소스, sidecar 리소스, holdApplicationUntilProxyStarts
```

검증 결과:
```
istio-base-prod: Synced / Healthy
istiod-prod:     Synced / Healthy
istiod pod:      1/1 Running
sidecar injector webhook: 등록 완료 (4 entries)
```

---

### 2단계: sidecar injection 활성화

```yaml
# gitops/prod/namespace.yaml 에 label 추가
metadata:
  labels:
    istio-injection: enabled
```

```bash
# 기존 파드에 적용 (rolling restart)
kubectl rollout restart deployment -n popcon-prod
```

검증:
```bash
# 파드가 2/2 (앱 + Envoy sidecar)로 Running인지 확인
kubectl get pods -n popcon-prod
```

---

### 3단계: permissive 모드로 mTLS 활성화

```yaml
# gitops/prod/istio/peer-authentication.yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: popcon-prod
spec:
  mtls:
    mode: PERMISSIVE
```

검증:
- popcon.store 접속 정상 여부 확인
- api.popcon.store 각 엔드포인트 응답 확인
- Kiali에서 서비스 간 트래픽 흐름 확인

---

### 4단계: VirtualService / DestinationRule 적용

8개 서비스에 retry, timeout, circuit breaker 순차 적용.

```bash
kubectl apply -f gitops/prod/istio/virtualservices/
kubectl apply -f gitops/prod/istio/destinationrules/
```

검증:
- 각 서비스 정상 응답 확인
- 의도적 오류 주입 후 retry 동작 확인

---

### 5단계: strict mTLS 전환

permissive에서 충분히 검증 후 strict으로 전환.

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

검증:
- mTLS 없는 직접 HTTP 호출 차단 확인
- 서비스 간 통신 정상 확인

---

### 6단계: 관측 도구 설치 (Kiali / Jaeger)

ArgoCD GitOps 방식으로 설치 예정 (Helm chart).

> Kiali, Jaeger는 ALB를 통한 외부 트래픽이 아닌 **사이드카가 수집한 서비스 간 트래픽** 데이터를 사용하므로, Istio Ingress Gateway 없이도 정상 동작

---

## 롤백 기준

아래 상황 발생 시 즉시 롤백:

| 상황 | 판단 기준 |
|------|---------|
| 서비스 응답 없음 | 5분 이상 지속 |
| 파드 CrashLoopBackOff | 3회 이상 반복 |
| ArgoCD OutOfSync 해소 불가 | 10분 이상 지속 |
| sidecar injection 실패 | 파드가 1/2로 유지 |
