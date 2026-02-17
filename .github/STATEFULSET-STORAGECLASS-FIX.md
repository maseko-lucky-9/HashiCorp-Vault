# StatefulSet StorageClass Update Error — Fix Documentation

## 🔴 Error

```
Error: UPGRADE FAILED: cannot patch "vault" with kind StatefulSet:
StatefulSet.apps "vault" is invalid: spec: Forbidden: updates to statefulset
spec for fields other than 'replicas', 'ordinals', 'template', 'updateStrategy',
'persistentVolumeClaimRetentionPolicy' and 'minReadySeconds' are forbidden
```

## 🔍 Root Cause

You changed the `storageClass` in `helm/vault/values.yaml`:

```yaml
# Before
storageClass: "local-path"

# After
storageClass: "microk8s-hostpath"
```

**Why this fails:**

StatefulSet `volumeClaimTemplates` are **immutable** in Kubernetes. Once created, you cannot change:

- `storageClassName`
- `accessModes`
- `resources.requests.storage`

This is a Kubernetes design decision to prevent accidental data loss. The PVCs created by the StatefulSet are bound to the original StorageClass forever.

## ✅ Solutions

### Option 1: Delete and Recreate (Fresh Deployments Only)

**Use this if:**

- ✅ Vault is not yet initialized
- ✅ You have no production data
- ✅ You're still in testing/setup phase

**Steps:**

```bash
cd scripts
chmod +x fix-storageclass.sh
./fix-storageclass.sh
```

**What the script does:**

1. Uninstalls Vault Helm release
2. Deletes all Vault PVCs
3. Reinstalls Vault with new StorageClass
4. Shows verification of new PVCs

**After running:**

```bash
# Initialize Vault
cd scripts
./init-vault.sh

# Verify StorageClass
kubectl get pvc -n vault -o custom-columns=NAME:.metadata.name,STORAGECLASS:.spec.storageClassName
```

---

### Option 2: Manual PVC Migration (Production Systems)

**Use this if:**

- ⚠️ Vault is initialized with production data
- ⚠️ You need to preserve existing secrets
- ⚠️ You have active applications using Vault

**Prerequisites:**

1. Take a Raft snapshot backup:

   ```bash
   cd scripts
   ./backup-vault.sh
   ```

2. Save the backup to external storage (S3, USB drive, etc.)

**Migration Steps:**

#### 1. Scale Down Vault (Seal All Pods)

```bash
# Scale to 0 replicas
kubectl scale statefulset vault -n vault --replicas=0

# Wait for all pods to terminate
kubectl wait --for=delete pod -l app.kubernetes.io/name=vault -n vault --timeout=120s
```

#### 2. Backup Existing PVC Data

For each PVC (`vault-data-vault-0`, `vault-data-vault-1`, `vault-data-vault-2`):

```bash
# Create a temporary pod to copy data
kubectl run pvc-backup-vault-0 -n vault --image=busybox --restart=Never \
  --overrides='
{
  "spec": {
    "containers": [{
      "name": "backup",
      "image": "busybox",
      "command": ["sleep", "3600"],
      "volumeMounts": [{
        "name": "data",
        "mountPath": "/data"
      }]
    }],
    "volumes": [{
      "name": "data",
      "persistentVolumeClaim": {
        "claimName": "vault-data-vault-0"
      }
    }]
  }
}'

# Copy data out
kubectl exec -n vault pvc-backup-vault-0 -- tar czf - /data > vault-0-backup.tar.gz

# Repeat for vault-1 and vault-2
```

#### 3. Delete StatefulSet and PVCs

```bash
# Delete StatefulSet (keep PVCs for now)
kubectl delete statefulset vault -n vault --cascade=orphan

# Delete PVCs
kubectl delete pvc vault-data-vault-0 vault-data-vault-1 vault-data-vault-2 -n vault
kubectl delete pvc vault-audit-vault-0 vault-audit-vault-1 vault-audit-vault-2 -n vault
```

#### 4. Reinstall Vault with New StorageClass

```bash
helm upgrade --install vault hashicorp/vault \
  --version 0.32.0 \
  --namespace vault \
  -f helm/vault/values.yaml \
  --wait \
  --timeout 10m
```

#### 5. Restore Data to New PVCs

```bash
# Copy data back to new PVCs
kubectl run pvc-restore-vault-0 -n vault --image=busybox --restart=Never \
  --overrides='
{
  "spec": {
    "containers": [{
      "name": "restore",
      "image": "busybox",
      "command": ["sleep", "3600"],
      "volumeMounts": [{
        "name": "data",
        "mountPath": "/data"
      }]
    }],
    "volumes": [{
      "name": "data",
      "persistentVolumeClaim": {
        "claimName": "vault-data-vault-0"
      }
    }]
  }
}'

# Restore data
kubectl exec -n vault pvc-restore-vault-0 -i -- tar xzf - -C / < vault-0-backup.tar.gz

# Repeat for vault-1 and vault-2
```

#### 6. Restart Vault and Unseal

```bash
# Delete restore pods
kubectl delete pod pvc-restore-vault-0 pvc-restore-vault-1 pvc-restore-vault-2 -n vault

# Restart Vault pods
kubectl rollout restart statefulset vault -n vault

# Unseal each pod
for pod in vault-0 vault-1 vault-2; do
  kubectl exec -n vault $pod -- vault operator unseal <key1>
  kubectl exec -n vault $pod -- vault operator unseal <key2>
  kubectl exec -n vault $pod -- vault operator unseal <key3>
done
```

---

### Option 3: Revert the Change (Quickest)

If you don't actually need to change the StorageClass:

```bash
# Revert values.yaml back to local-path
git checkout helm/vault/values.yaml

# Or manually change back:
# storageClass: "local-path"

# Then deploy
helm upgrade --install vault hashicorp/vault \
  --version 0.32.0 \
  --namespace vault \
  -f helm/vault/values.yaml \
  --wait
```

---

## 🎯 Recommended Approach

**For your situation (likely testing/setup):**

1. **Check if Vault is initialized:**

   ```bash
   kubectl exec -n vault vault-0 -- vault status 2>/dev/null || echo "Not initialized"
   ```

2. **If not initialized or no important data:**

   ```bash
   cd scripts
   ./fix-storageclass.sh
   ```

3. **If initialized with production data:**
   - Take a Raft snapshot backup first
   - Follow Option 2 (Manual PVC Migration)
   - OR restore from backup after Option 1

---

## 📊 Verification

After migration, verify the new StorageClass:

```bash
# Check PVCs
kubectl get pvc -n vault -o custom-columns=NAME:.metadata.name,STORAGECLASS:.spec.storageClassName

# Expected output:
# NAME                     STORAGECLASS
# vault-audit-vault-0      microk8s-hostpath
# vault-audit-vault-1      microk8s-hostpath
# vault-audit-vault-2      microk8s-hostpath
# vault-data-vault-0       microk8s-hostpath
# vault-data-vault-1       microk8s-hostpath
# vault-data-vault-2       microk8s-hostpath

# Check Vault status
kubectl get pods -n vault
kubectl exec -n vault vault-0 -- vault status
```

---

## 🔑 Key Takeaways

1. **StatefulSet PVC templates are immutable** — this is a Kubernetes design decision
2. **Plan StorageClass carefully** before first deployment
3. **Always backup before migrations** — use `./backup-vault.sh`
4. **For fresh deployments** — delete and recreate is safe and fast
5. **For production** — manual migration preserves data but requires downtime

---

## 🆘 If You're Stuck

**Quick decision tree:**

```
Do you have production data in Vault?
├─ NO → Run ./fix-storageclass.sh (Option 1)
└─ YES → Do you have a recent backup?
    ├─ YES → Run ./fix-storageclass.sh, then restore from backup
    └─ NO → Take backup first, then follow Option 2 (Manual Migration)
```

**Need help?** Check:

- Vault status: `kubectl exec -n vault vault-0 -- vault status`
- PVC status: `kubectl get pvc -n vault`
- Pod logs: `kubectl logs -n vault vault-0`
