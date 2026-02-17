# Self-Hosted GitHub Runner Configuration

## Overview

This repository uses a **self-hosted GitHub runner** for CI/CD workflows. This allows direct access to your local Kubernetes cluster for deployment and validation.

## Runner Configuration

### Jobs Using Self-Hosted Runner

The following jobs run on your self-hosted runner:

**`lint-validate.yaml`:**

- ✅ `helm-validate` — Validates Helm values with HashiCorp chart
- ✅ `helm-template` — Renders and validates Kubernetes manifests
- ⚠️ `security-scan` — Runs on `ubuntu-latest` (doesn't need cluster access)
- ⚠️ `yaml-lint` — Runs on `ubuntu-latest` (doesn't need cluster access)

**`deploy.yaml`:**

- ✅ `validate` — Pre-deployment validation
- ✅ `deploy` — Helm upgrade to cluster
- ✅ `smoke-test` — Post-deployment verification

**`rollback.yaml`:**

- ✅ `rollback` — Helm rollback operation

### Why Self-Hosted?

1. **Direct Cluster Access** — Runner has kubeconfig for your cluster
2. **No Secret Exposure** — No need to store kubeconfig in GitHub Secrets
3. **Faster Deployments** — Local network access to cluster
4. **Cost Savings** — No GitHub Actions minutes consumed

## Runner Requirements

Your self-hosted runner must have:

### Required Tools

```bash
# Verify these are installed on your runner
kubectl version --client
helm version
git --version
```

### Kubernetes Access

```bash
# Runner must have valid kubeconfig
export KUBECONFIG=~/.kube/config
kubectl cluster-info
kubectl auth can-i create deployment -n vault
```

### Helm Repositories

The workflows will automatically add the HashiCorp Helm repository, but you can pre-configure it:

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

## Setting Up Self-Hosted Runner

If you haven't set up your runner yet:

### 1. Install GitHub Actions Runner

```bash
# On your Ubuntu server
cd ~
mkdir actions-runner && cd actions-runner

# Download latest runner (check GitHub for current version)
curl -o actions-runner-linux-x64-2.314.1.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.314.1/actions-runner-linux-x64-2.314.1.tar.gz

# Extract
tar xzf ./actions-runner-linux-x64-2.314.1.tar.gz
```

### 2. Configure Runner

```bash
# Get registration token from:
# GitHub Repo → Settings → Actions → Runners → New self-hosted runner

./config.sh --url https://github.com/maseko-lucky-9/HashiCorp-Vault --token YOUR_TOKEN

# When prompted:
# - Runner name: vault-runner (or your choice)
# - Runner group: Default
# - Labels: self-hosted,Linux,X64
# - Work folder: _work
```

### 3. Install as Service

```bash
# Install as systemd service
sudo ./svc.sh install

# Start the service
sudo ./svc.sh start

# Check status
sudo ./svc.sh status
```

### 4. Verify Runner

Go to your GitHub repository:

- Settings → Actions → Runners
- You should see your runner listed as "Idle" (green)

## Workflow Behavior

### On Pull Request

When you create a PR, the `lint-validate.yaml` workflow runs:

1. **helm-validate** (self-hosted)
   - Fetches HashiCorp Vault chart
   - Validates your `values.yaml`
   - Templates the chart

2. **helm-template** (self-hosted)
   - Renders full Kubernetes manifests
   - Validates with kubeconform

3. **security-scan** (ubuntu-latest)
   - Trivy config scan
   - Trivy image scan
   - Checkov policy checks

4. **yaml-lint** (ubuntu-latest)
   - YAML syntax validation

### On Push to Main

When you merge to `main`, the `deploy.yaml` workflow runs:

1. **validate** (self-hosted)
   - Re-validates Helm values

2. **deploy** (self-hosted)
   - Requires manual approval (production environment)
   - Runs `helm upgrade --install`
   - Waits for deployment

3. **smoke-test** (self-hosted)
   - Verifies Vault pods are running
   - Checks Raft storage type

## Troubleshooting

### Runner Offline

**Symptom:** Workflows stuck in "Queued" state

**Solution:**

```bash
# On your server
sudo systemctl status actions.runner.maseko-lucky-9-HashiCorp-Vault.vault-runner.service

# Restart if needed
sudo ./svc.sh restart
```

### Runner Can't Access Cluster

**Symptom:** `kubectl` commands fail in workflow

**Solution:**

```bash
# Ensure runner user has kubeconfig
sudo -u runner-user kubectl cluster-info

# For k3s, copy kubeconfig
sudo cp /etc/rancher/k3s/k3s.yaml /home/runner-user/.kube/config
sudo chown runner-user:runner-user /home/runner-user/.kube/config
```

### Helm Repository Not Found

**Symptom:** `Error: failed to download "hashicorp/vault"`

**Solution:**
The workflow adds the repo automatically, but if it fails:

```bash
# Manually add on runner
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

## Security Considerations

### Runner Isolation

Your self-hosted runner has access to:

- ✅ Your Kubernetes cluster (by design)
- ✅ Local filesystem
- ⚠️ GitHub repository code

**Best practices:**

1. Run the runner as a dedicated user (not root)
2. Limit runner user permissions to only what's needed
3. Use namespace-scoped kubeconfig if possible
4. Monitor runner logs regularly

### Secrets Management

Since the runner has direct cluster access, you **don't need** to store `KUBE_CONFIG` in GitHub Secrets. However, if you have other secrets (S3 credentials, etc.), add them via:

GitHub Repo → Settings → Secrets and variables → Actions → New repository secret

Access in workflows:

```yaml
env:
  S3_BUCKET: ${{ secrets.S3_BUCKET }}
```

## Monitoring

### Check Runner Logs

```bash
# View runner service logs
sudo journalctl -u actions.runner.*.service -f

# View runner application logs
cd ~/actions-runner
tail -f _diag/Runner_*.log
```

### Workflow Logs

View in GitHub:

- Repository → Actions → Select workflow run → View logs

## Summary

Your workflows are configured to use your self-hosted runner for all Kubernetes-related operations, while security scans run on GitHub's `ubuntu-latest` runners (which don't need cluster access).

This hybrid approach provides:

- ✅ Secure cluster access via self-hosted runner
- ✅ Fast deployments on local network
- ✅ Reliable security scanning via GitHub infrastructure
- ✅ No kubeconfig secrets in GitHub
