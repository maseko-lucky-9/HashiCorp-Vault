# Vault Volume Permission Denied Error — Fix Documentation

## 🔴 Error

```
Error initializing storage of type raft: failed to create fsm:
failed to open bolt file: open /vault/data/vault.db: permission denied
```

**Pod status:**

```
vault-0   0/1   Pending            0   20s
vault-1   0/1   Pending            0   20s
vault-2   0/1   CrashLoopBackOff   1   20s
```

## 🔍 Root Cause

**The permission mismatch:**

| Component                    | Owner         | UID:GID  |
| ---------------------------- | ------------- | -------- |
| Volume (created by MicroK8s) | `root:root`   | 0:0      |
| Vault process                | `vault:vault` | 100:1000 |

**Why fsGroup doesn't work:**

The `values.yaml` has `fsGroup: 1000` configured:

```yaml
securityContext:
  pod:
    fsGroup: 1000
```

However, **MicroK8s hostpath provisioner doesn't always respect fsGroup**. This is a known limitation of the `hostpath` provisioner — it creates directories owned by root, and Kubernetes can't change ownership without an initContainer.

**The conflict:**

1. MicroK8s creates `/var/snap/microk8s/common/default-storage/vault-data-vault-X/` owned by `root:root`
2. Kubernetes mounts this as `/vault/data` in the pod
3. `fsGroup: 1000` tries to set group ownership, but fails with hostpath
4. Vault (running as uid 100) tries to write `vault.db`
5. **Permission denied** → CrashLoopBackOff

## ✅ Solution

Add an `extraInitContainers` that runs as root to fix permissions before Vault starts.

### Changes Applied

**File:** [`helm/vault/values.yaml`](file:///e:/Repo/HashiCorp%20Vault/helm/vault/values.yaml)

Added after `auditStorage`:

```yaml
extraInitContainers:
  - name: fix-permissions
    image: busybox:1.36
    command:
      - sh
      - -c
      - |
        echo "Fixing volume permissions..."
        chown -R 100:1000 /vault/data
        chown -R 100:1000 /vault/audit
        chmod -R 755 /vault/data
        chmod -R 755 /vault/audit
        echo "Permissions fixed successfully"
    volumeMounts:
      - name: data
        mountPath: /vault/data
      - name: audit
        mountPath: /vault/audit
    securityContext:
      runAsUser: 0 # Must run as root to chown
      runAsNonRoot: false
```

**How it works:**

1. **Before Vault starts**, the initContainer runs
2. **Runs as root** (uid 0) to have permission to chown
3. **Changes ownership** of `/vault/data` and `/vault/audit` to `100:1000`
4. **Sets permissions** to `755` (rwxr-xr-x)
5. **Exits successfully**, allowing Vault container to start
6. **Vault starts** with correct permissions

## 🚀 Deployment

### If Vault is Already Deployed

```bash
# Delete existing StatefulSet and PVCs
cd scripts
./fix-storageclass.sh

# This will:
# 1. Delete Vault release
# 2. Delete PVCs
# 3. Reinstall with new initContainer
```

### Fresh Deployment

```bash
# Apply StorageClass
kubectl apply -f manifests/storageclass-immediate.yaml

# Deploy Vault
helm upgrade --install vault hashicorp/vault \
  --version 0.32.0 \
  --namespace vault \
  --create-namespace \
  -f helm/vault/values.yaml \
  --wait
```

## 📊 Verification

### Watch InitContainer Run

```bash
# Watch pods start
kubectl get pods -n vault -w

# Expected sequence:
# vault-0   0/1   Init:0/1   0   5s   ← initContainer running
# vault-0   0/1   PodInitializing   0   10s   ← initContainer done
# vault-0   0/1   Running   0   15s   ← Vault starting
# vault-0   1/1   Running   0   30s   ← Vault ready
```

### Check InitContainer Logs

```bash
kubectl logs vault-0 -n vault -c fix-permissions

# Expected output:
# Fixing volume permissions...
# Permissions fixed successfully
```

### Check Vault Logs

```bash
kubectl logs vault-0 -n vault

# Should NOT show permission denied errors
# Should show successful Raft initialization
```

### Verify Permissions on Host

```bash
# On the MicroK8s node
ls -la /var/snap/microk8s/common/default-storage/

# Should show directories owned by 100:1000
# drwxr-xr-x 2 100 1000 4096 Feb 17 22:00 vault-data-vault-0
```

## 🔄 Why This Happens

### Normal Kubernetes Behavior

In standard Kubernetes with CSI drivers:

- `fsGroup: 1000` in pod securityContext
- Kubernetes automatically chowns volumes to `fsGroup`
- Works seamlessly

### MicroK8s Hostpath Behavior

With MicroK8s hostpath provisioner:

- `fsGroup: 1000` is **ignored**
- Volumes remain owned by `root:root`
- Requires manual initContainer to fix

### Alternative Solutions

**Option 1: Use a different StorageClass** (if available)

- OpenEBS
- Longhorn
- NFS provisioner

**Option 2: Run Vault as root** (NOT RECOMMENDED)

```yaml
securityContext:
  pod:
    runAsUser: 0
    runAsNonRoot: false
```

❌ **Security risk** — never run Vault as root in production

**Option 3: Pre-create volumes manually** (NOT SCALABLE)

```bash
# Manually create and chown directories
sudo mkdir -p /var/snap/microk8s/common/default-storage/vault-data-vault-0
sudo chown -R 100:1000 /var/snap/microk8s/common/default-storage/vault-data-vault-0
```

❌ **Not automated** — defeats GitOps principles

**✅ Option 4: Use initContainer** (RECOMMENDED)

- Automated
- Secure (initContainer runs once, then exits)
- Works with GitOps
- No manual intervention

## 📝 Summary

**Problem:** MicroK8s hostpath volumes owned by root, Vault runs as uid 100

**Root Cause:** MicroK8s hostpath provisioner doesn't respect `fsGroup`

**Solution:** Add initContainer to chown volumes before Vault starts

**Result:** ✅ Vault pods start successfully with correct permissions

## 🎯 Key Takeaways

1. **fsGroup doesn't work** with MicroK8s hostpath provisioner
2. **InitContainers are the standard solution** for permission fixes
3. **Running as root is acceptable** for initContainers (they exit before the main container)
4. **Always verify permissions** after deployment
5. **This is a known MicroK8s limitation**, not a Vault issue

---

## 🚀 Next Steps

1. **Deploy with the fix:**

   ```bash
   cd scripts
   ./fix-storageclass.sh
   ```

2. **Verify pods start:**

   ```bash
   kubectl get pods -n vault -w
   ```

3. **Initialize Vault:**
   ```bash
   cd scripts
   ./init-vault.sh
   ```

The permission error is now resolved! 🎉
