# HashiCorp Vault on Kubernetes — GitOps Deployment

Production-ready deployment of HashiCorp Vault on self-hosted Kubernetes using GitOps (Helm + ArgoCD).

## 📋 Quick Reference

| Component  | Version | Purpose                    |
| ---------- | ------- | -------------------------- |
| Vault      | 1.21.0  | Secrets management         |
| Helm Chart | 0.32.0  | Deployment packaging       |
| Kubernetes | 1.31+   | Container orchestration    |
| ArgoCD     | 2.14+   | GitOps continuous delivery |

## 🏗️ Architecture

- **HA Topology**: 3 Vault pods with Raft integrated storage
- **Auto-Unseal**: Manual Shamir (5 shares, 3 threshold) or Transit method
- **Secret Injection**: Vault Agent Injector (sidecar pattern)
- **TLS**: Self-signed CA via cert-manager
- **Backup**: Automated CronJob with S3 upload

## 📁 Repository Structure

```
.
├── helm/vault/
│   └── values.yaml              # Helm chart configuration
├── argocd/
│   └── vault-application.yaml   # ArgoCD Application manifest
├── .github/workflows/
│   ├── lint-validate.yaml       # PR validation pipeline
│   ├── deploy.yaml              # Deployment workflow
│   └── rollback.yaml            # Manual rollback
├── policies/
│   ├── app-readonly.hcl         # Application read-only policy
│   ├── admin.hcl                # Admin policy
│   └── database-dynamic.hcl     # Dynamic DB credentials
├── scripts/
│   ├── init-vault.sh            # First-time initialization
│   └── backup-vault.sh          # Backup script
├── manifests/
│   ├── network-policy.yaml      # NetworkPolicy (default-deny + allow rules)
│   ├── pod-disruption-budget.yaml # PDB (minAvailable: 2)
│   └── backup-cronjob.yaml      # Automated backup CronJob
└── README.md
```

## 🚀 Deployment Steps

### 1. Prerequisites

Install on your Ubuntu server:

```bash
# Install entropy daemon (CRITICAL for home servers)
sudo apt install haveged -y
sudo systemctl enable --now haveged

# Verify entropy
cat /proc/sys/kernel/random/entropy_avail  # Should be > 1000

# Install Kubernetes (k3s or kubeadm)
curl -sfL https://get.k3s.io | sh -

# Install cert-manager
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true
```

### 2. Deploy Infrastructure Manifests

```bash
# Label app namespaces for NetworkPolicy
kubectl label namespace apps vault-client=true

# Apply NetworkPolicy (default-deny + allow rules)
kubectl apply -f manifests/network-policy.yaml

# Apply PodDisruptionBudget
kubectl apply -f manifests/pod-disruption-budget.yaml
```

### 3. Deploy Vault via Helm

```bash
# Add HashiCorp Helm repo
helm repo add hashicorp https://helm.releases.hashicorp.com

# Deploy Vault
helm upgrade --install vault hashicorp/vault \
  --version 0.32.0 \
  --namespace vault \
  --create-namespace \
  -f helm/vault/values.yaml \
  --wait
```

### 4. Initialize Vault

```bash
# Run initialization script
cd scripts
chmod +x init-vault.sh
./init-vault.sh

# CRITICAL: Save the unseal keys and root token to secure offline storage
```

### 5. Configure Kubernetes Auth

```bash
# Create a Vault role for your application
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/app-role \
  bound_service_account_names=myapp-sa \
  bound_service_account_namespaces=apps \
  policies=app-readonly \
  ttl=1h
```

### 6. Deploy ArgoCD (Optional)

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.14.0/manifests/install.yaml

# Apply Vault Application
kubectl apply -f argocd/vault-application.yaml
```

### 7. Enable Automated Backups

```bash
# Configure S3 bucket in manifests/backup-cronjob.yaml
# Then apply:
kubectl apply -f manifests/backup-cronjob.yaml
```

## 🔐 Using Vault with Applications

Add these annotations to your pod spec:

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

Secrets will be available at `/vault/secrets/config.txt`.

## 🛡️ Security Hardening Checklist

- [ ] `haveged` installed on all nodes (entropy ≥ 1000)
- [ ] PodDisruptionBudget applied (`minAvailable: 2`)
- [ ] Node affinity configured (if using `local-path` StorageClass)
- [ ] Default-deny NetworkPolicy applied before allow rules
- [ ] All app namespaces labeled `vault-client: "true"`
- [ ] TLS enabled (`tlsDisable: false`)
- [ ] Root token revoked after initial setup
- [ ] Audit logging enabled (file + syslog)
- [ ] Automated backups configured with S3 upload
- [ ] Audit log rotation configured

## 🔧 Operations

### Daily Health Checks

```bash
# Check pod status
kubectl get pods -n vault

# Check seal status
kubectl exec vault-0 -n vault -- vault status

# Check Raft peers
kubectl exec vault-0 -n vault -- vault operator raft list-peers

# Check audit log disk usage
kubectl exec vault-0 -n vault -- df -h /vault/audit
```

### Manual Backup

```bash
cd scripts
./backup-vault.sh
```

### Unseal After Restart

```bash
# Unseal each pod with 3 of 5 keys
for pod in vault-0 vault-1 vault-2; do
  kubectl exec -n vault $pod -- vault operator unseal <key1>
  kubectl exec -n vault $pod -- vault operator unseal <key2>
  kubectl exec -n vault $pod -- vault operator unseal <key3>
done
```

### Upgrade Vault

1. Update `server.image.tag` in `helm/vault/values.yaml`
2. Create PR → GitHub Actions validates
3. Merge PR → ArgoCD syncs (but pods won't restart due to `OnDelete`)
4. Manually delete pods one at a time (standby first, leader last):

```bash
kubectl delete pod vault-2 -n vault  # Wait for rejoin + unseal
kubectl delete pod vault-1 -n vault  # Wait for rejoin + unseal
kubectl delete pod vault-0 -n vault  # Leader steps down, then rejoins
```

## 📚 Documentation

Full implementation guide: [implementation_plan.md](file:///C:/Users/ltmas/.gemini/antigravity/brain/f31b61f3-f590-413b-8173-5cc7904659fc/implementation_plan.md)

## 🆘 Troubleshooting

| Issue                      | Solution                                                   |
| -------------------------- | ---------------------------------------------------------- |
| Pods stuck in `Pending`    | Check PVC provisioning: `kubectl get pvc -n vault`         |
| Pods in `CrashLoopBackOff` | Check logs: `kubectl logs vault-0 -n vault`                |
| `0/1 Ready`                | Vault is sealed — run `vault operator unseal`              |
| Injector not working       | Check webhook: `kubectl get mutatingwebhookconfigurations` |

## 📄 License

This configuration is provided as-is for educational and production use.
