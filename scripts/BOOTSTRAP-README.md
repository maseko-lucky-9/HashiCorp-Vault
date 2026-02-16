# ArgoCD Bootstrap Script — Documentation

## Overview

The `bootstrap-argocd.sh` script automates the initial deployment of ArgoCD and the Vault application in your Kubernetes cluster. It is designed to be **idempotent** (safe to run multiple times) and includes comprehensive error handling and health checks.

## Features

- ✅ **Idempotent** — Safe to run multiple times without side effects
- ✅ **Detection** — Automatically detects existing ArgoCD installations
- ✅ **Health Checks** — Verifies ArgoCD is operational before proceeding
- ✅ **Namespace Setup** — Creates and labels all required namespaces
- ✅ **Application Deployment** — Deploys Vault via ArgoCD
- ✅ **Error Handling** — Comprehensive logging and error recovery
- ✅ **Production-Ready** — Uses ArgoCD v2.14.0 with custom health checks

## Prerequisites

Before running the bootstrap script, ensure:

1. **kubectl installed and configured**

   ```bash
   kubectl version --client
   kubectl cluster-info
   ```

2. **Cluster admin permissions**

   ```bash
   kubectl auth can-i create namespace
   # Should return: yes
   ```

3. **Internet connectivity** — Required to download ArgoCD manifests

4. **Repository cloned**
   ```bash
   cd ~/HashiCorp-Vault
   ```

## Usage

### Basic Execution

```bash
cd scripts
chmod +x bootstrap-argocd.sh
./bootstrap-argocd.sh
```

### What the Script Does

The script executes the following steps in order:

#### 1. **Prerequisite Checks**

- Verifies `kubectl` is installed
- Checks cluster connectivity
- Validates admin permissions

#### 2. **ArgoCD Detection**

- Checks if ArgoCD namespace exists
- Verifies ArgoCD server deployment
- If found, validates health status

#### 3. **ArgoCD Installation** (if not present)

- Creates `argocd` namespace
- Applies ArgoCD v2.14.0 manifests
- Waits for all components to become healthy (up to 5 minutes)

#### 4. **ArgoCD Configuration**

- Labels namespaces for NetworkPolicy
- Configures custom health checks for Vault StatefulSets
- Patches ArgoCD ConfigMap

#### 5. **Namespace Setup**

- Creates `vault` namespace
- Creates `apps` namespace with `vault-client=true` label
- Labels `kube-system` for NetworkPolicy

#### 6. **Vault Application Deployment**

- Applies `argocd/vault-application.yaml`
- Waits for initial sync (up to 2 minutes)
- Note: Vault pods will start in sealed state

#### 7. **Verification**

- Checks ArgoCD component health
- Verifies Vault pods are deployed
- Reports application sync status

#### 8. **Output**

- Displays ArgoCD admin credentials
- Provides next steps and access instructions
- Saves detailed log to `/tmp/argocd-bootstrap-YYYYMMDD-HHMMSS.log`

## Expected Output

### Successful Execution

```
═══════════════════════════════════════════════════════
  ArgoCD Bootstrap Script
  Version: v2.14.0
═══════════════════════════════════════════════════════

[2026-02-16 21:20:00] Checking prerequisites...
[2026-02-16 21:20:01] ✅ All prerequisites met
[2026-02-16 21:20:01] ArgoCD not detected. Proceeding with installation...
[2026-02-16 21:20:02] Installing ArgoCD v2.14.0...
[2026-02-16 21:20:03] ✅ Created namespace: argocd
[2026-02-16 21:20:05] Applying ArgoCD manifests...
[2026-02-16 21:20:10] ✅ ArgoCD manifests applied
[2026-02-16 21:20:10] Checking ArgoCD health...
[2026-02-16 21:22:30] ✅ ArgoCD server is healthy
[2026-02-16 21:22:30] ✅ ArgoCD installed successfully
[2026-02-16 21:22:31] Configuring ArgoCD...
[2026-02-16 21:22:32] ✅ ArgoCD configuration applied
[2026-02-16 21:22:33] Retrieving ArgoCD admin password...

═══════════════════════════════════════════════════════
  ArgoCD Admin Credentials
═══════════════════════════════════════════════════════
  Username: admin
  Password: xK9mP2nQ7vR4sT8w
═══════════════════════════════════════════════════════

[2026-02-16 21:22:34] ⚠️  IMPORTANT: Change this password immediately after first login!

[2026-02-16 21:22:35] Setting up required namespaces...
[2026-02-16 21:22:36] ✅ Created namespace: vault
[2026-02-16 21:22:37] ✅ Created namespace: apps (labeled vault-client=true)
[2026-02-16 21:22:38] ✅ All namespaces configured
[2026-02-16 21:22:39] Deploying Vault application via ArgoCD...
[2026-02-16 21:22:40] ✅ Vault application deployed
[2026-02-16 21:22:41] Waiting for Vault application to sync...
[2026-02-16 21:23:10] ✅ Vault application synced successfully
[2026-02-16 21:23:11] Verifying deployment...
[2026-02-16 21:23:12] ✅ ArgoCD components running (7 pods)
[2026-02-16 21:23:13] ✅ Vault pods deployed (4 pods)
[2026-02-16 21:23:13] ⚠️  Note: Vault pods will be sealed until initialized

═══════════════════════════════════════════════════════
  Bootstrap Complete!
═══════════════════════════════════════════════════════

Next Steps:

1. Access ArgoCD UI:
   kubectl port-forward svc/argocd-server -n argocd 8080:443
   Then open: https://localhost:8080

2. Initialize Vault:
   cd scripts
   ./init-vault.sh

3. Monitor Vault deployment:
   kubectl get pods -n vault -w

4. View ArgoCD applications:
   kubectl get applications -n argocd

Important:
  - Change ArgoCD admin password after first login
  - Save Vault unseal keys securely when running init-vault.sh
  - Review DEPLOYMENT.md for detailed setup instructions

Log file: /tmp/argocd-bootstrap-20260216-212000.log

[2026-02-16 21:23:14] ✅ Bootstrap completed successfully!
```

### If ArgoCD Already Exists

```
[2026-02-16 21:20:01] ⚠️  WARNING: ArgoCD is already installed in namespace: argocd
[2026-02-16 21:20:02] Checking ArgoCD health...
[2026-02-16 21:20:03] ✅ ArgoCD server is healthy
[2026-02-16 21:20:03] ✅ Existing ArgoCD installation is healthy
[2026-02-16 21:20:04] Setting up required namespaces...
...
```

## Troubleshooting

### Script Fails at Prerequisite Check

**Error:** `kubectl not found`

**Solution:**

```bash
# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
```

**Error:** `Cannot connect to Kubernetes cluster`

**Solution:**

```bash
# Verify kubeconfig
export KUBECONFIG=~/.kube/config
kubectl cluster-info

# For k3s
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

**Error:** `Insufficient permissions`

**Solution:**

```bash
# Check your permissions
kubectl auth can-i '*' '*' --all-namespaces

# For k3s, ensure you're using the correct kubeconfig
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
```

### ArgoCD Installation Timeout

**Error:** `ArgoCD failed to become healthy after 30 attempts`

**Solution:**

```bash
# Check pod status
kubectl get pods -n argocd

# Check pod logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server

# Check events
kubectl get events -n argocd --sort-by='.lastTimestamp'

# Common issue: Insufficient resources
kubectl describe nodes
```

### Vault Application Not Syncing

**Error:** `Vault application sync is taking longer than expected`

**Solution:**
This is normal for first-time deployment. Vault pods start in a sealed state. The script will continue, and you should:

```bash
# Check ArgoCD Application status
kubectl get application vault -n argocd

# Check Vault pods
kubectl get pods -n vault

# View ArgoCD UI for detailed sync status
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

## Script Behavior

### Idempotency

The script is safe to run multiple times:

- **If ArgoCD exists:** Skips installation, validates health, proceeds to namespace setup
- **If namespaces exist:** Skips creation, ensures labels are applied
- **If Vault app exists:** Updates the application manifest (ArgoCD will detect changes)

### Logging

All output is logged to `/tmp/argocd-bootstrap-YYYYMMDD-HHMMSS.log` for troubleshooting.

View the log:

```bash
tail -f /tmp/argocd-bootstrap-*.log
```

### Exit Codes

- `0` — Success
- `1` — Error (check log file for details)

## Integration with DEPLOYMENT.md

The bootstrap script **replaces Steps 6-8** in `DEPLOYMENT.md`:

**Before (Manual):**

1. Install cert-manager
2. Create TLS certificates
3. Clone repository
4. Label namespaces
5. Apply manifests
6. **Install ArgoCD manually** ← Replaced
7. **Apply Vault Application** ← Replaced
8. **Verify deployment** ← Replaced
9. Deploy Vault via Helm
10. Initialize Vault

**After (Automated):**

1. Install cert-manager
2. Create TLS certificates
3. Clone repository
4. Label namespaces
5. Apply manifests
6. **Run `bootstrap-argocd.sh`** ← One command
7. Deploy Vault via Helm (or let ArgoCD handle it)
8. Initialize Vault

## Security Considerations

1. **Admin Password** — The script displays the ArgoCD admin password. Change it immediately:

   ```bash
   # Access ArgoCD UI and change password, or use CLI:
   argocd account update-password
   ```

2. **Log Files** — Bootstrap logs contain the admin password. Secure or delete them:

   ```bash
   rm /tmp/argocd-bootstrap-*.log
   ```

3. **RBAC** — The script requires cluster-admin permissions. Run only on trusted systems.

## Next Steps After Bootstrap

1. **Access ArgoCD UI**

   ```bash
   kubectl port-forward svc/argocd-server -n argocd 8080:443
   ```

   Open https://localhost:8080 and login with the credentials displayed

2. **Change Admin Password**
   - Login to ArgoCD UI
   - Go to User Info → Update Password

3. **Initialize Vault**

   ```bash
   cd scripts
   ./init-vault.sh
   ```

4. **Monitor Deployment**

   ```bash
   # Watch Vault pods
   kubectl get pods -n vault -w

   # Check ArgoCD sync status
   kubectl get applications -n argocd
   ```

5. **Continue with DEPLOYMENT.md**
   - Proceed to Step 11 (Verify Vault Status)
   - Complete remaining configuration steps

## Advanced Usage

### Custom ArgoCD Version

Edit the script to change the version:

```bash
ARGOCD_VERSION="v2.15.0"  # Change this line
```

### Skip Vault Deployment

Comment out the Vault deployment section:

```bash
# deploy_vault_application  # Comment this line
```

### Custom Namespaces

Edit the configuration section:

```bash
ARGOCD_NAMESPACE="my-argocd"
VAULT_NAMESPACE="my-vault"
```

## Summary

The bootstrap script provides a **one-command solution** to set up ArgoCD and deploy the Vault application, reducing manual steps and potential errors. It's production-ready with comprehensive error handling and health checks.

**Recommended workflow:**

1. Run `bootstrap-argocd.sh` (this script)
2. Run `init-vault.sh` (initialize Vault)
3. Run `backup-vault.sh` (test backups)
4. Deploy your applications
