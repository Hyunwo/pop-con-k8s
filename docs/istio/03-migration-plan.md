# Istio 마이그레이션 계획서

## 사전 준비

- [ ] memory limit 768Mi → 1Gi 상향 (sidecar 여유 확보)
- [ ] JVM MaxRAMPercentage 75% → 60% 조정 (limit 상향 대비)
- [ ] TopologySpreadConstraints DoNotSchedule + PDB 적용
- [ ] 현재 서비스 간 통신 흐름 검증 (정상 동작 확인)

---

## 단계별 진행

### 1단계: Istio 설치

```bash
# Helm으로 istio-base, istiod 설치
helm repo add istio https://istio-release.storage.googleapis.com/charts

helm install istio-base istio/base \
  -n istio-system --create-namespace

helm install istiod istio/istiod \
  -n istio-system \
  --set pilot.resources.requests.cpu=500m \
  --set pilot.resources.requests.memory=2Gi

helm install istio-ingressgateway istio/gateway \
  -n istio-system
```

검증:
```bash
kubectl get pods -n istio-system
kubectl get svc istio-ingressgateway -n istio-system
```

---

### 2단계: sidecar injection 활성화

```bash
# popcon-prod 네임스페이스에 sidecar 자동 주입 설정
kubectl label namespace popcon-prod istio-injection=enabled
```

기존 파드에 적용:
```bash
kubectl rollout restart deployment -n popcon-prod
```

검증:
```bash
# 파드가 2/2 (앱 + sidecar)로 Running인지 확인
kubectl get pods -n popcon-prod
```

---

### 3단계: permissive 모드로 mTLS 활성화

```bash
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: popcon-prod
spec:
  mtls:
    mode: PERMISSIVE
EOF
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

```bash
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: popcon-prod
spec:
  mtls:
    mode: STRICT
EOF
```

검증:
- mTLS 없는 직접 HTTP 호출 차단 확인
- 서비스 간 통신 정상 확인

---

### 6단계: 관측 도구 설치

```bash
# Kiali
helm install kiali-server kiali/kiali-server \
  -n istio-system

# Jaeger
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/addons/jaeger.yaml
```

---

## 롤백 기준

아래 상황 발생 시 즉시 롤백:

| 상황 | 판단 기준 |
|------|---------|
| 서비스 응답 없음 | 5분 이상 지속 |
| 파드 CrashLoopBackOff | 3회 이상 반복 |
| ArgoCD OutOfSync 해소 불가 | 10분 이상 지속 |
| sidecar injection 실패 | 파드가 1/2로 유지 |
