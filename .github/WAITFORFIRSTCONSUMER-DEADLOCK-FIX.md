# WaitForFirstConsumer Deadlock — Fix Documentation

## 🔴 Problem

**Symptom:** Vault pods stuck in `Pending` state, PVCs stuck in `Pending` state

**Error pattern:**

```
kubectl get pods -n vault
NAME      READY   STATUS    RESTARTS   AGE
vault-0   0/1     Pending   0          5m

kubectl get pvc -n vault
NAME                  STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS        AGE
vault-data-vault-0    Pending                                      microk8s-hostpath   5m
```

**Events:**

```
kubectl describe pod vault-0 -n vault
Events:
  Warning  FailedScheduling  pod/vault-0  0/1 nodes are available:
  1 pod has unbound immediate PersistentVolumeClaims.
```

## 🔍 Root Cause

**The deadlock:**

1. **StatefulSet** creates `vault-0` pod
2. **Pod** requires PVC `vault-data-vault-0`
3. **PVC** uses StorageClass with `volumeBindingMode: WaitForFirstConsumer`
4. **WaitForFirstConsumer** delays binding until pod is scheduled to a node
5. **Pod** can't be scheduled until PVC is bound
6. **Circular dependency** → Deadlock

**Why WaitForFirstConsumer exists:**

In **multi-node clusters**, it ensures:

- PVC is created on the same node as the pod
- Avoids cross-node volume mounting issues
- Optimizes for node affinity

**Why it fails in single-node clusters:**

In **single-node clusters** (like your MicroK8s setup):

- There's only one node, so node selection is irrelevant
- The "wait for scheduling" logic creates unnecessary complexity
- Results in deadlock with StatefulSets

## ✅ Solution

### Option 1: Custom StorageClass with Immediate Binding (Recommended)

**Created:** [`manifests/storageclass-immediate.yaml`](file:///e:/Repo/HashiCorp%20Vault/manifests/storageclass-immediate.yaml)

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: microk8s-hostpath-immediate
provisioner: microk8s.io/hostpath
volumeBindingMode: Immediate # ← Binds PVCs immediately
reclaimPolicy: Delete
allowVolumeExpansion: true
```

**Updated:** `helm/vault/values.yaml` to use `microk8s-hostpath-immediate`

**Deployment steps:**

```bash
# 1. Apply the custom StorageClass
kubectl apply -f manifests/storageclass-immediate.yaml

# 2. Verify it was created
kubectl get storageclass microk8s-hostpath-immediate

# 3. If Vault is already deployed, delete and recreate
cd scripts
./fix-storageclass.sh

# 4. Or deploy fresh
helm upgrade --install vault hashicorp/vault \
  --version 0.32.0 \
  --namespace vault \
  --create-namespace \
  -f helm/vault/values.yaml \
  --wait
```

---

### Option 2: Patch Existing StorageClass (Alternative)

**Only if you can't create a new StorageClass:**

```bash
# WARNING: This affects ALL PVCs using microk8s-hostpath

# Patch the existing StorageClass
kubectl patch storageclass microk8s-hostpath \
  -p '{"volumeBindingMode":"Immediate"}'

# Verify
kubectl get storageclass microk8s-hostpath -o yaml | grep volumeBindingMode
```

**⚠️ Caution:** This changes the default StorageClass behavior for all workloads.

---

### Option 3: Manual PVC Pre-Creation (Not Recommended)

Manually create PVCs before deploying the StatefulSet:

```bash
# Create PVCs manually
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vault-data-vault-0
  namespace: vault
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
  storageClassName: microk8s-hostpath
EOF

# Repeat for vault-1, vault-2, and audit PVCs
```

**Why not recommended:**

- Manual process, error-prone
- Doesn't scale
- Defeats the purpose of StatefulSet automation

---

## 🎯 Recommended Approach

**For single-node MicroK8s clusters:**

1. ✅ **Create custom StorageClass** with `Immediate` binding (Option 1)
2. ✅ **Update Vault values.yaml** to use the new StorageClass
3. ✅ **Deploy Vault** — PVCs will bind immediately
4. ✅ **Pods will start** without deadlock

**For multi-node clusters:**

- Keep `WaitForFirstConsumer` (it's beneficial)
- Ensure proper node affinity/anti-affinity rules
- Use pod topology spread constraints

---

## 📊 Verification

After applying the fix:

```bash
# 1. Check StorageClass exists
kubectl get storageclass microk8s-hostpath-immediate

# Expected output:
# NAME                           PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE   AGE
# microk8s-hostpath-immediate    microk8s.io/hostpath    Delete          Immediate           1m

# 2. Deploy Vault
helm upgrade --install vault hashicorp/vault \
  --version 0.32.0 \
  --namespace vault \
  -f helm/vault/values.yaml \
  --wait

# 3. Watch PVCs bind immediately
kubectl get pvc -n vault -w

# Expected output:
# NAME                     STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS                  AGE
# vault-data-vault-0       Bound    pvc-abc123...                              10Gi       RWO            microk8s-hostpath-immediate   5s
# vault-audit-vault-0      Bound    pvc-def456...                              5Gi        RWO            microk8s-hostpath-immediate   5s

# 4. Watch pods start
kubectl get pods -n vault -w

# Expected output:
# NAME      READY   STATUS    RESTARTS   AGE
# vault-0   0/1     Running   0          10s
# vault-0   1/1     Running   0          30s
```

---

## 🔄 Comparison: WaitForFirstConsumer vs Immediate

| Aspect            | WaitForFirstConsumer   | Immediate             |
| ----------------- | ---------------------- | --------------------- |
| **Binding time**  | When pod is scheduled  | When PVC is created   |
| **Use case**      | Multi-node clusters    | Single-node clusters  |
| **Node affinity** | Respects pod placement | Ignores pod placement |
| **StatefulSet**   | Can cause deadlock     | Works seamlessly      |
| **Performance**   | Optimized for locality | May cross nodes       |

---

## 📝 Summary

**Problem:** WaitForFirstConsumer + StatefulSet = Deadlock in single-node clusters

**Root Cause:** Circular dependency between pod scheduling and PVC binding

**Solution:** Custom StorageClass with `Immediate` binding mode

**Result:** ✅ PVCs bind immediately → Pods start → No deadlock

---

## 🚀 Next Steps

1. **Apply the StorageClass:**

   ```bash
   kubectl apply -f manifests/storageclass-immediate.yaml
   ```

2. **Deploy Vault:**

   ```bash
   cd scripts
   ./fix-storageclass.sh  # If already deployed
   # OR
   helm upgrade --install vault hashicorp/vault \
     --version 0.32.0 \
     --namespace vault \
     -f helm/vault/values.yaml \
     --wait
   ```

3. **Verify:**
   ```bash
   kubectl get pvc,pods -n vault
   ```

The deadlock is now resolved! 🎉
