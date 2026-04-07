# Istio 롤백 계획서

## 단계별 롤백 방법

### 5단계 롤백: strict → permissive

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

---

### 4단계 롤백: VirtualService / DestinationRule 제거

```bash
kubectl delete virtualservices --all -n popcon-prod
kubectl delete destinationrules --all -n popcon-prod
```

---

### 3단계 롤백: PeerAuthentication 제거

```bash
kubectl delete peerauthentication default -n popcon-prod
```

---

### 2단계 롤백: sidecar injection 비활성화

```bash
kubectl label namespace popcon-prod istio-injection-
kubectl rollout restart deployment -n popcon-prod
```

검증:
```bash
# 파드가 1/1 (사이드카 없음)으로 돌아왔는지 확인
kubectl get pods -n popcon-prod
```

---

### 1단계 롤백: Istio 완전 제거

```bash
helm uninstall istio-ingressgateway -n istio-system
helm uninstall istiod -n istio-system
helm uninstall istio-base -n istio-system
kubectl delete namespace istio-system
```

Istio CRD 정리:
```bash
kubectl get crd | grep istio | awk '{print $1}' | xargs kubectl delete crd
```

---

## 롤백 후 확인사항

```bash
# 1. 파드 정상 동작 확인
kubectl get pods -n popcon-prod

# 2. 서비스 응답 확인
curl -I https://popcon.store
curl -I https://api.popcon.store/auth/health

# 3. ArgoCD Synced 확인
kubectl get applications -n argocd

# 4. 잔여 Istio 리소스 확인
kubectl get crd | grep istio
kubectl get peerauthentication --all-namespaces
kubectl get virtualservice --all-namespaces
kubectl get destinationrule --all-namespaces
```

---

## 주의사항

- Istio 제거 후 ArgoCD에서 관련 어노테이션이 남아있으면 OutOfSync 발생 가능
  → `kubectl annotate` 또는 ArgoCD hard refresh로 해소
- sidecar injection label 제거 후 반드시 rolling restart 필요
  → label만 제거하면 기존 파드에 sidecar가 그대로 남음
- strict mTLS 상태에서 갑자기 sidecar를 제거하면 서비스 간 통신 단절
  → 반드시 permissive → injection 비활성화 순서로 진행
