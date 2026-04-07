# Istio 롤백 계획서

> 최종 업데이트: 2026-04-07

## 단계별 롤백 방법

### 5단계 롤백: strict → permissive

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: popcon-prod
spec:
  mtls:
    mode: PERMISSIVE
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

```yaml
# gitops/prod/namespace.yaml 에서 label 제거
# istio-injection: enabled 줄 삭제 후 commit & push
```

```bash
# ArgoCD가 namespace 변경 적용 후 rolling restart
kubectl rollout restart deployment -n popcon-prod
```

검증:
```bash
# 파드가 1/1 (사이드카 없음)으로 돌아왔는지 확인
kubectl get pods -n popcon-prod
```

---

### 1단계 롤백: Istio 완전 제거 (ArgoCD GitOps 방식)

```bash
# gitops/prod/kustomization.yaml 에서 istio 항목 제거
# - istio
# 후 commit & push → ArgoCD가 istio-base-prod, istiod-prod Application 삭제
```

또는 ArgoCD UI에서 직접 삭제:
```bash
kubectl delete application istio-base-prod -n argocd
kubectl delete application istiod-prod -n argocd
```

잔여 CRD 정리:
```bash
kubectl get crd | grep istio | awk '{print $1}' | xargs kubectl delete crd
kubectl delete namespace istio-system
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

- sidecar injection label 제거 후 반드시 rolling restart 필요
  → label만 제거하면 기존 파드에 sidecar가 그대로 남음
- strict mTLS 상태에서 갑자기 sidecar를 제거하면 서비스 간 통신 단절
  → 반드시 strict → permissive → injection 비활성화 순서로 진행
- Istio 제거 후 ArgoCD에서 관련 리소스가 남아있으면 OutOfSync 발생 가능
  → ArgoCD hard refresh 또는 Application 재동기화로 해소
- 1단계(Istio 완전 제거) 후에도 istio-system namespace가 Terminating 상태로 남을 수 있음
  → 잔여 finalizer 확인: `kubectl get namespace istio-system -o yaml`
