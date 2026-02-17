# HashiCorp Vault on Kubernetes — GitOps Deployment

Production-ready deployment of [HashiCorp Vault](https://www.vaultproject.io/) on a self-hosted MicroK8s cluster using GitOps principles (Helm + ArgoCD), automated CI/CD via GitHub Actions with a self-hosted runner, and comprehensive security hardening.

---

## ✨ Key Features

- **High Availability** — 3-node Raft integrated storage with automatic leader election
- **GitOps Workflow** — Infrastructure-as-Code with PR validation, automated deployment, and one-click rollback
- **Security Hardened** — Non-root containers, read-only filesystem, IPC_LOCK, seccomp profiles, default-deny NetworkPolicy
- **Automated CI/CD** — Self-hosted GitHub Actions runner for lint, validate, deploy, and smoke tests
- **Secret Injection** — Vault Agent Injector (sidecar pattern) for seamless application integration
- **Automated Backups** — Daily Raft snapshots via CronJob with S3-compatible upload
- **One-Command Bootstrap** — Idempotent ArgoCD + Vault deployment script

---

## 📋 Quick Reference

| Component      | Version            | Purpose                       |
| -------------- | ------------------ | ----------------------------- |
| Vault          | 1.21.0             | Secrets management            |
| Helm Chart     | 0.32.0             | Deployment packaging          |
| MicroK8s       | 1.31+              | Kubernetes distribution       |
| ArgoCD         | 2.14+              | GitOps continuous delivery    |
| GitHub Actions | —                  | CI/CD (self-hosted runner)    |
| StorageClass   | hostpath-immediate | Persistent volume provisioner |

---

## 🏗️ Architecture

```
┌──────────────────────────────────────────────────────────┐
│  GitHub Repository                                       │
│  ┌─────────────┐  push   ┌──────────────────────┐       │
│  │ values.yaml │ ──────▶ │ GitHub Actions Runner │       │
│  │ policies/   │         │ (self-hosted)         │       │
│  │ manifests/  │         └────────┬─────────────┘       │
│  └─────────────┘                  │ helm upgrade         │
└───────────────────────────────────┼──────────────────────┘
                                    ▼
┌──────────────────────────────────────────────────────────┐
│  MicroK8s Cluster                                        │
│                                                          │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐                  │
│  │ vault-0 │◄─┤ vault-1 │◄─┤ vault-2 │  Raft Consensus  │
│  │ (leader)│  │(standby)│  │(standby)│                   │
│  └────┬────┘  └────┬────┘  └────┬────┘                   │
│       │            │            │                         │
│  ┌────┴────┐  ┌────┴────┐  ┌────┴────┐                   │
│  │ 10Gi PV │  │ 10Gi PV │  │ 10Gi PV │  hostpath-immed.  │
│  └─────────┘  └─────────┘  └─────────┘                   │
│                                                          │
│  ┌──────────────────┐  ┌──────────────────┐              │
│  │ NetworkPolicy    │  │ PodDisruptionBdgt │             │
│  │ (default-deny)   │  │ (minAvailable: 2) │             │
│  └──────────────────┘  └──────────────────┘              │
└──────────────────────────────────────────────────────────┘
```

---

## 📁 Repository Structure

```
.
├── helm/vault/
│   └── values.yaml                  # Helm chart values (HA, security, storage)
├── argocd/
│   └── vault-application.yaml       # ArgoCD Application manifest
├── .github/
│   └── workflows/
│       ├── lint-validate.yaml        # PR validation (template + kubeconform + Trivy)
│       ├── deploy.yaml               # Deployment workflow (push to main)
│       └── rollback.yaml             # Manual rollback (workflow_dispatch)
├── manifests/
│   ├── storageclass-immediate.yaml   # Custom StorageClass (Immediate binding)
│   ├── network-policy.yaml           # Default-deny + Vault-specific allow rules
│   ├── pod-disruption-budget.yaml    # PDB (minAvailable: 2)
│   └── backup-cronjob.yaml           # Daily Raft snapshot CronJob
├── policies/
│   ├── app-readonly.hcl              # Namespace-scoped read-only access
│   ├── admin.hcl                     # Admin (denies sys/seal)
│   └── database-dynamic.hcl          # Dynamic DB credential generation
├── scripts/
│   ├── bootstrap-argocd.sh           # One-command ArgoCD + Vault bootstrap
│   ├── init-vault.sh                 # First-time Vault initialization
│   ├── backup-vault.sh               # Manual Raft snapshot + S3 upload
│   ├── fix-storageclass.sh           # StorageClass migration helper
│   └── BOOTSTRAP-README.md           # Bootstrap script documentation
├── DEPLOYMENT.md                     # Step-by-step server setup guide
└── README.md                         # This file
```

---

## 🔧 Prerequisites

### Server Requirements

| Requirement | Minimum          | Recommended      |
| ----------- | ---------------- | ---------------- |
| OS          | Ubuntu 22.04 LTS | Ubuntu 24.04 LTS |
| CPU         | 2 cores          | 4 cores          |
| RAM         | 4 GB             | 8 GB             |
| Disk        | 50 GB            | 100 GB SSD       |
| Network     | Static IP        | Static IP + DNS  |

### Software Requirements

```bash
# MicroK8s (Kubernetes distribution)
sudo snap install microk8s --classic --channel=1.31/stable
microk8s enable dns storage helm3

# Verify cluster
microk8s status --wait-ready
microk8s kubectl get nodes

# Entropy daemon (CRITICAL for cryptographic operations)
sudo apt install haveged -y
sudo systemctl enable --now haveged
cat /proc/sys/kernel/random/entropy_avail  # Must be > 1000

# Helm (if not using MicroK8s built-in)
snap install helm --classic
```

### GitHub Self-Hosted Runner

A self-hosted GitHub Actions runner must be configured on your server with access to the MicroK8s cluster. See [`.github/SELF-HOSTED-RUNNER.md`](.github/SELF-HOSTED-RUNNER.md) for setup instructions.

---

## 🚀 Quick Start

### Option A: Automated Bootstrap (Recommended)

Deploy ArgoCD and Vault in a single command:

```bash
git clone https://github.com/maseko-lucky-9/HashiCorp-Vault.git
cd HashiCorp-Vault

# Apply custom StorageClass
kubectl apply -f manifests/storageclass-immediate.yaml

# Run bootstrap
cd scripts
chmod +x bootstrap-argocd.sh
./bootstrap-argocd.sh
```

See [`scripts/BOOTSTRAP-README.md`](scripts/BOOTSTRAP-README.md) for the complete bootstrap guide.

### Option B: Manual Deployment

#### Step 1: Apply Infrastructure Manifests

```bash
# Create custom StorageClass (required for MicroK8s)
kubectl apply -f manifests/storageclass-immediate.yaml

# Label app namespaces for NetworkPolicy
kubectl label namespace apps vault-client=true --overwrite

# Apply security manifests
kubectl apply -f manifests/network-policy.yaml
kubectl apply -f manifests/pod-disruption-budget.yaml
```

#### Step 2: Deploy Vault via Helm

```bash
# Add HashiCorp Helm repository
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Deploy Vault
helm upgrade --install vault hashicorp/vault \
  --version 0.32.0 \
  --namespace vault \
  --create-namespace \
  -f helm/vault/values.yaml \
  --timeout 10m
```

> [!IMPORTANT]
> Do **not** use `--wait` on the first deployment. Vault pods will remain `0/1 Ready` until initialized in Step 3.

#### Step 3: Initialize Vault

```bash
cd scripts
chmod +x init-vault.sh
./init-vault.sh
```

This script will:

1. Initialize vault-0 with Shamir keys (5 shares, 3 threshold)
2. Unseal all 3 pods
3. Join vault-1 and vault-2 to the Raft cluster
4. Enable Kubernetes auth, KV v2, and audit logging
5. Apply all policies from `policies/`

> [!CAUTION]
> **Save the unseal keys and root token** to secure offline storage immediately. These cannot be recovered if lost.

#### Step 4: Verify Deployment

```bash
# All pods should show 1/1 Running
kubectl get pods -n vault

# Vault status should show Sealed: false
kubectl exec vault-0 -n vault -- vault status

# Raft cluster should have 3 peers
kubectl exec vault-0 -n vault -- vault operator raft list-peers
```

---

## ⚙️ Configuration Options

### Storage

| Parameter                         | Default                       | Description                   |
| --------------------------------- | ----------------------------- | ----------------------------- |
| `server.dataStorage.size`         | `10Gi`                        | Raft data volume size per pod |
| `server.dataStorage.storageClass` | `microk8s-hostpath-immediate` | StorageClass name             |
| `server.auditStorage.size`        | `5Gi`                         | Audit log volume size per pod |
| `server.ha.replicas`              | `3`                           | Number of Vault server pods   |

### Networking

| Parameter             | Default     | Description                               |
| --------------------- | ----------- | ----------------------------------------- |
| `server.service.type` | `ClusterIP` | Service type (`NodePort`, `LoadBalancer`) |
| `ui.enabled`          | `true`      | Enable Vault Web UI                       |
| `ui.serviceType`      | `ClusterIP` | UI service type                           |

To expose the Vault UI externally:

```bash
# Port forward to localhost
kubectl port-forward svc/vault-ui -n vault 8200:8200

# Or change to NodePort in values.yaml:
#   service:
#     type: NodePort
#     nodePort: 30820
```

### TLS Configuration

TLS is currently **disabled** for initial setup (`tls_disable = true` in Raft config). To enable TLS in production:

1. Install cert-manager: `helm install cert-manager jetstack/cert-manager --set crds.enabled=true`
2. Uncomment `tls_cert_file` and `tls_key_file` in `values.yaml`
3. Change `tls_disable` to `false`
4. Update `retry_join` URLs from `http://` to `https://`
5. Add `leader_tls_servername` to each `retry_join` block

---

## 🔐 Using Vault with Applications

### Inject Secrets via Sidecar

Add these annotations to your pod spec for automatic secret injection:

```yaml
apiVersion: v1
kind: Pod
metadata:
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "app-role"
    vault.hashicorp.com/agent-inject-secret-config.txt: "secret/data/apps/myapp/config"
    vault.hashicorp.com/agent-inject-template-config.txt: |
      {{- with secret "secret/data/apps/myapp/config" -}}
      {{ range $k, $v := .Data.data }}
      {{ $k }}={{ $v }}
      {{ end }}
      {{- end -}}
spec:
  serviceAccountName: myapp-sa
  containers:
    - name: app
      image: myapp:latest
      command: ["/bin/sh", "-c", "source /vault/secrets/config.txt && ./app"]
```

Secrets are rendered at `/vault/secrets/config.txt` before the application starts.

### Create a Kubernetes Auth Role

```bash
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/app-role \
  bound_service_account_names=myapp-sa \
  bound_service_account_namespaces=apps \
  policies=app-readonly \
  ttl=1h
```

### Store a Secret

```bash
kubectl exec -n vault vault-0 -- vault kv put \
  secret/apps/myapp/config \
  DB_HOST=postgres.db.svc \
  DB_USER=myapp \
  DB_PASS=s3cur3p4ss
```

---

## 🛡️ Security Hardening Checklist

- [ ] Entropy daemon (`haveged`) installed — `entropy_avail > 1000`
- [ ] PodDisruptionBudget applied — `minAvailable: 2`
- [ ] Default-deny NetworkPolicy applied before allow rules
- [ ] All app namespaces labeled `vault-client: "true"`
- [ ] Root token revoked after initial setup
- [ ] Audit logging enabled (file + syslog dual devices)
- [ ] Automated backups configured with S3 upload
- [ ] TLS enabled for production (currently disabled for setup)
- [ ] Non-root containers with `readOnlyRootFilesystem: true`
- [ ] `IPC_LOCK` capability for mlock-based secret protection

---

## 📋 Operations Guide

### Daily Health Checks

```bash
# Pod status
kubectl get pods -n vault

# Seal status (should show Sealed: false)
kubectl exec vault-0 -n vault -- vault status

# Raft cluster health
kubectl exec vault-0 -n vault -- vault operator raft list-peers

# Audit log disk usage
kubectl exec vault-0 -n vault -- df -h /vault/audit

# PVC status
kubectl get pvc -n vault
```

### Unseal After Restart

If pods restart (node reboot, upgrades), Vault will be sealed:

```bash
for pod in vault-0 vault-1 vault-2; do
  kubectl exec -n vault $pod -- vault operator unseal <key1>
  kubectl exec -n vault $pod -- vault operator unseal <key2>
  kubectl exec -n vault $pod -- vault operator unseal <key3>
done
```

### Manual Backup

```bash
cd scripts
./backup-vault.sh
```

### Automated Backups (CronJob)

```bash
# Edit S3 credentials in manifests/backup-cronjob.yaml, then apply:
kubectl apply -f manifests/backup-cronjob.yaml

# Verify CronJob
kubectl get cronjob -n vault
```

### Upgrade Vault Version

1. Update `server.image.tag` in `helm/vault/values.yaml`
2. Create a PR → GitHub Actions validates (lint + template + security scan)
3. Merge to `main` → Workflow deploys automatically
4. Pods use `OnDelete` strategy — manually delete one at a time:

```bash
# Delete standby pods first, leader last
kubectl delete pod vault-2 -n vault   # Wait for rejoin + unseal
kubectl delete pod vault-1 -n vault   # Wait for rejoin + unseal
kubectl delete pod vault-0 -n vault   # Leader steps down, then rejoins
```

### Rollback

Trigger a manual rollback via the GitHub Actions UI:

**GitHub → Actions → Rollback Vault → Run workflow → Enter revision number**

Or via CLI:

```bash
helm rollback vault <revision> -n vault
```

---

## 🔄 CI/CD Workflows

### On Pull Request (`lint-validate.yaml`)

| Job             | Runner        | Description                                |
| --------------- | ------------- | ------------------------------------------ |
| `helm-validate` | self-hosted   | Templates chart with custom values         |
| `helm-template` | self-hosted   | Validates rendered manifests (kubeconform) |
| `security-scan` | ubuntu-latest | Trivy + Checkov policy scanning            |
| `yaml-lint`     | ubuntu-latest | YAML syntax validation                     |

### On Push to Main (`deploy.yaml`)

| Job          | Runner      | Description                                  |
| ------------ | ----------- | -------------------------------------------- |
| `validate`   | self-hosted | Re-validates Helm values                     |
| `deploy`     | self-hosted | `helm upgrade --install` (requires approval) |
| `smoke-test` | self-hosted | Verifies StatefulSet, PVCs, StorageClass     |

### Manual Rollback (`rollback.yaml`)

Triggered via GitHub UI with a revision number input.

---

## 🆘 Troubleshooting

| Issue                               | Cause                              | Solution                                                                                                                              |
| ----------------------------------- | ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Pods stuck in `Pending`             | PVC not binding                    | Check StorageClass: `kubectl get sc` and PVCs: `kubectl get pvc -n vault`                                                             |
| `CrashLoopBackOff`                  | Permission denied on `/vault/data` | Ensure `extraInitContainers` is in values.yaml — see [VOLUME-PERMISSIONS-FIX](.github/VOLUME-PERMISSIONS-FIX.md)                      |
| `0/1 Ready` after deploy            | Vault not initialized              | Run `./scripts/init-vault.sh` (expected on first deploy)                                                                              |
| `Vault is sealed` (503)             | Node reboot or pod restart         | Unseal with 3 of 5 keys — see [Operations Guide](#-operations-guide)                                                                  |
| Raft join fails with HTTPS          | Protocol mismatch                  | Ensure `retry_join` URLs use `http://` when `tls_disable = true`                                                                      |
| `helm lint` fails                   | No Chart.yaml                      | Expected — use `helm template` instead. See [HELM-LINT-FIX](.github/HELM-LINT-FIX.md)                                                 |
| `kubectl exec` TLS error            | Kubelet certificate issue          | See [MICROK8S-CERTIFICATE-FIX](.github/MICROK8S-CERTIFICATE-FIX.md)                                                                   |
| PVC `WaitForFirstConsumer` deadlock | Binding mode issue                 | Use `microk8s-hostpath-immediate` StorageClass. See [WAITFORFIRSTCONSUMER-DEADLOCK-FIX](.github/WAITFORFIRSTCONSUMER-DEADLOCK-FIX.md) |
| StatefulSet update forbidden        | Immutable PVC fields               | Delete and recreate: `./scripts/fix-storageclass.sh`. See [STATEFULSET-STORAGECLASS-FIX](.github/STATEFULSET-STORAGECLASS-FIX.md)     |

### Detailed Troubleshooting Guides

All troubleshooting documentation is in the `.github/` directory:

- [HELM-LINT-FIX.md](.github/HELM-LINT-FIX.md) — Helm validation with external charts
- [SELF-HOSTED-RUNNER.md](.github/SELF-HOSTED-RUNNER.md) — GitHub runner setup and configuration
- [STATEFULSET-STORAGECLASS-FIX.md](.github/STATEFULSET-STORAGECLASS-FIX.md) — StorageClass migration
- [MICROK8S-CERTIFICATE-FIX.md](.github/MICROK8S-CERTIFICATE-FIX.md) — Kubelet TLS certificate fix
- [WAITFORFIRSTCONSUMER-DEADLOCK-FIX.md](.github/WAITFORFIRSTCONSUMER-DEADLOCK-FIX.md) — PVC binding deadlock
- [VOLUME-PERMISSIONS-FIX.md](.github/VOLUME-PERMISSIONS-FIX.md) — Volume ownership for non-root containers

---

## 📚 Additional Documentation

| Document                                                       | Description                                                |
| -------------------------------------------------------------- | ---------------------------------------------------------- |
| [DEPLOYMENT.md](DEPLOYMENT.md)                                 | Step-by-step server setup from bare metal to running Vault |
| [scripts/BOOTSTRAP-README.md](scripts/BOOTSTRAP-README.md)     | ArgoCD bootstrap script documentation                      |
| [.github/SELF-HOSTED-RUNNER.md](.github/SELF-HOSTED-RUNNER.md) | Self-hosted GitHub Actions runner guide                    |

---

## 🤝 Contributing

Contributions are welcome! Please follow these guidelines:

1. **Fork** the repository and create a feature branch
2. **Make changes** to the appropriate files (`helm/`, `manifests/`, `policies/`, `scripts/`)
3. **Test locally** using `helm template` to validate your changes:
   ```bash
   helm repo add hashicorp https://helm.releases.hashicorp.com
   helm template vault hashicorp/vault --version 0.32.0 -f helm/vault/values.yaml --namespace vault
   ```
4. **Create a Pull Request** — GitHub Actions will automatically run:
   - Helm template validation
   - Kubeconform manifest validation
   - Trivy and Checkov security scanning
   - YAML linting
5. **Address review feedback** and ensure all checks pass

### Commit Convention

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add Prometheus ServiceMonitor for Vault metrics
fix: correct retry_join protocol from https to http
docs: update troubleshooting guide with PVC deadlock fix
chore: bump Vault image to 1.21.1
```

---

## 📄 License

This project is provided as-is under the [MIT License](LICENSE). The HashiCorp Vault software itself is governed by the [Business Source License (BSL)](https://www.hashicorp.com/bsl).
