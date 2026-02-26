# Vault Deployment Checklist — Server Execution Steps (Live Environment)

This checklist provides the exact commands to run on your **Ubuntu + MicroK8s server** (Live environment) to deploy Vault.

> **For local development** (WSL + Minikube), see `scripts/local-dev.sh` instead.

## ✅ Pre-Deployment Checklist

- [ ] Ubuntu server is running and accessible via SSH
- [ ] You have `sudo` privileges
- [ ] Server has at least 4GB RAM and 50GB disk space
- [ ] GitHub repository URL updated in `argocd/vault-application.yaml`

---

## 📋 Step-by-Step Deployment

### Step 1: Install Prerequisites

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install entropy daemon (CRITICAL for Vault key generation)
sudo apt install haveged -y
sudo systemctl enable --now haveged

# Verify entropy (should be > 1000)
cat /proc/sys/kernel/random/entropy_avail

# Disable swap permanently
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Install required tools
sudo apt install -y curl wget jq

# Configure firewall
sudo ufw allow 22/tcp      # SSH
sudo ufw allow 6443/tcp    # Kubernetes API
sudo ufw allow 8200/tcp    # Vault API
sudo ufw --force enable
```

### Step 2: Install Kubernetes (MicroK8s)

```bash
# Install MicroK8s
sudo snap install microk8s --classic --channel=1.31/stable

# Add your user to the microk8s group
sudo usermod -aG microk8s $USER
newgrp microk8s

# Wait for MicroK8s to be ready
microk8s status --wait-ready

# Enable required addons
microk8s enable dns hostpath-storage ingress

# Set up kubectl alias
sudo snap alias microk8s.kubectl kubectl

# Verify kubectl works
kubectl get nodes
```

### Step 3: Install Helm

```bash
# Install Helm 3.16
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify installation
helm version
```

### Step 4: Install cert-manager

```bash
# Install cert-manager for TLS certificate management
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait

# Verify cert-manager is running
kubectl get pods -n cert-manager
```

### Step 5: Create Self-Signed Certificate Issuer

```bash
# Create a self-signed ClusterIssuer
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: vault-tls
  namespace: vault
spec:
  secretName: vault-tls
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
  commonName: vault.vault.svc.cluster.local
  dnsNames:
    - vault
    - vault.vault
    - vault.vault.svc
    - vault.vault.svc.cluster.local
    - vault-0.vault-internal
    - vault-active
  duration: 8760h  # 1 year
  renewBefore: 720h  # 30 days
EOF

# Wait for certificate to be ready
kubectl wait --for=condition=Ready certificate/vault-tls -n vault --timeout=60s
```

### Step 6: Clone Your Repository

```bash
# Clone the Vault deployment repository
cd ~
git clone https://github.com/maseko-lucky-9/HashiCorp-Vault.git
cd HashiCorp-Vault
```

---

## 🚀 Quick Start: Automated Bootstrap (Recommended)

**Alternative to Steps 7-10:** Use the automated bootstrap script to install ArgoCD and deploy Vault in one command.

```bash
cd scripts
chmod +x bootstrap-argocd.sh
./bootstrap-argocd.sh
```

The bootstrap script will:

- ✅ Detect existing ArgoCD installation (idempotent)
- ✅ Install ArgoCD v2.14.0 if not present
- ✅ Configure namespaces and labels
- ✅ Deploy Vault application via ArgoCD
- ✅ Display admin credentials and next steps

**After bootstrap completes, skip to Step 11 (Verify Vault Status).**

For detailed bootstrap documentation, see [`scripts/BOOTSTRAP-README.md`](file:///e:/Repo/HashiCorp%20Vault/scripts/BOOTSTRAP-README.md).

---

## 📋 Manual Deployment (Alternative)

If you prefer manual control, follow Steps 7-10 below:

### Step 7: Label Namespaces for NetworkPolicy

```bash
# Create and label the apps namespace
kubectl create namespace apps
kubectl label namespace apps vault-client=true

# Label kube-system (for health checks)
kubectl label namespace kube-system kubernetes.io/metadata.name=kube-system
```

### Step 8: Apply Kubernetes Manifests

```bash
# Apply NetworkPolicy (default-deny + allow rules)
kubectl apply -f manifests/network-policy.yaml

# Apply PodDisruptionBudget
kubectl apply -f manifests/pod-disruption-budget.yaml

# Verify manifests
kubectl get networkpolicies -n vault
kubectl get poddisruptionbudgets -n vault
```

### Step 9: Deploy Vault via Helm

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
  # NOTE: Do NOT use --wait on first deployment.
  # Vault pods remain 0/1 Ready until manually initialized (Step 10).

# Verify pods are running (they will be sealed)
kubectl get pods -n vault
```

Expected output:

```
NAME                                    READY   STATUS    RESTARTS   AGE
vault-0                                 0/1     Running   0          2m
vault-agent-injector-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
```

### Step 10: Initialize Vault

```bash
# Run the initialization script
cd scripts
chmod +x init-vault.sh backup-vault.sh
./init-vault.sh
```

**CRITICAL:** The script will output:

- 5 unseal keys
- 1 root token

**IMMEDIATELY save these to a password manager or encrypted offline storage!**

### Step 11: Verify Vault Status

```bash
# Check seal status (should be "Sealed: false")
kubectl exec -n vault vault-0 -- vault status

# Check data volume
kubectl exec -n vault vault-0 -- df -h /vault/data

# Check audit logs
kubectl exec -n vault vault-0 -- ls -lh /vault/audit/
```

### Step 12: Create Application Vault Role

```bash
# Create a Kubernetes ServiceAccount for your app
kubectl create serviceaccount myapp-sa -n apps

# Create a Vault role bound to this ServiceAccount
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/app-role \
  bound_service_account_names=myapp-sa \
  bound_service_account_namespaces=apps \
  policies=app-readonly \
  ttl=1h

# Write a test secret
kubectl exec -n vault vault-0 -- vault kv put secret/apps/myapp/config \
  db_host=postgres.apps.svc \
  db_port=5432 \
  api_key=test-key-12345
```

### Step 13: Deploy Backup CronJob (Optional)

```bash
# If using S3 backups, edit the CronJob first:
# nano manifests/backup-cronjob.yaml
# Set S3_BUCKET environment variable

# Apply the CronJob
kubectl apply -f manifests/backup-cronjob.yaml

# Verify CronJob
kubectl get cronjobs -n vault
```

### Step 14: Test Secret Injection

```bash
# Deploy a test pod with Vault Agent Injector
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-vault-injection
  namespace: apps
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "app-role"
    vault.hashicorp.com/agent-inject-secret-config.txt: "secret/data/apps/myapp/config"
    vault.hashicorp.com/agent-inject-template-config.txt: |
      {{- with secret "secret/data/apps/myapp/config" -}}
      {{ range \$k, \$v := .Data.data }}
      {{ \$k }}={{ \$v }}
      {{ end }}
      {{- end -}}
spec:
  serviceAccountName: myapp-sa
  containers:
    - name: app
      image: nginx:alpine
      command: ["/bin/sh", "-c", "cat /vault/secrets/config.txt && sleep 3600"]
EOF

# Wait for pod to be ready
kubectl wait --for=condition=Ready pod/test-vault-injection -n apps --timeout=120s

# Verify secrets were injected
kubectl exec -n apps test-vault-injection -- cat /vault/secrets/config.txt
```

Expected output:

```
db_host=postgres.apps.svc
db_port=5432
api_key=test-key-12345
```

### Step 15: Revoke Root Token

```bash
# After confirming everything works, revoke the root token
kubectl exec -n vault vault-0 -- vault token revoke <ROOT_TOKEN>
```

---

## 🎯 Post-Deployment Verification

Run these checks to ensure everything is working:

```bash
# 1. All Vault pods are running and unsealed
kubectl get pods -n vault
kubectl exec -n vault vault-0 -- vault status | grep Sealed

# 2. Raft cluster has quorum
kubectl exec -n vault vault-0 -- vault operator raft list-peers

# 3. NetworkPolicy is enforced
kubectl get networkpolicies -n vault

# 4. PodDisruptionBudget is active
kubectl get pdb -n vault

# 5. Audit logs are being written
kubectl exec -n vault vault-0 -- tail -n 10 /vault/audit/vault-audit.log

# 6. Test secret injection works
kubectl logs -n apps test-vault-injection -c app
```

---

## 📝 Important Notes

### Single-Node Cluster Configuration

Since you're running a **single-node cluster in standalone mode**:

- Only 1 Vault pod (`vault-0`) runs on the node
- File storage backend stores data in `/vault/data`
- No Raft consensus or leader election needed
- `local-path` or `microk8s-hostpath-immediate` StorageClass works perfectly
- No node affinity configuration needed

### Unseal Keys Storage

**CRITICAL:** Store the 5 unseal keys in multiple secure locations:

- Password manager (1Password, Bitwarden, KeePass)
- Encrypted USB drive (offline)
- Paper backup in a safe

**Never** store them in:

- Git repository
- Kubernetes Secrets
- Plain text files on the server

### Root Token Recovery

If you need the root token after revoking it:

```bash
# Generate a new root token using unseal keys
kubectl exec -n vault vault-0 -- vault operator generate-root -init
# Follow the prompts with your unseal keys
```

---

## 🚨 Troubleshooting

| Issue                          | Solution                                                                    |
| ------------------------------ | --------------------------------------------------------------------------- |
| Entropy < 1000                 | Restart haveged: `sudo systemctl restart haveged`                           |
| Pods stuck in Pending          | Check PVC: `kubectl get pvc -n vault`                                       |
| Certificate not Ready          | Check cert-manager logs: `kubectl logs -n cert-manager -l app=cert-manager` |
| Vault sealed after restart     | Run unseal on vault-0 with 3 of 5 keys                                      |
| NetworkPolicy blocking traffic | Verify namespace labels: `kubectl get ns --show-labels`                     |

---

## ✅ Deployment Complete!

Your production-ready Vault instance is now running. Next steps:

1. Configure your applications to use Vault Agent Injector
2. Set up monitoring (Prometheus + Grafana)
3. Schedule regular backup testing
4. Document your unseal procedure for your team
