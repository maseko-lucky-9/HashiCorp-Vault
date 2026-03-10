#!/bin/bash
set -uo pipefail

# Multi-environment QA validation script
# Runs all static checks against the changed files

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

PASS=0
FAIL=0
WARN=0
RESULTS=""

log_test() { echo -e "\n\033[1;34m━━━ TEST: $1 ━━━\033[0m"; }
log_pass() { echo -e "\033[0;32m  ✅ PASS: $1\033[0m"; PASS=$((PASS + 1)); RESULTS+="PASS|$1\n"; }
log_fail() { echo -e "\033[0;31m  ❌ FAIL: $1\033[0m"; FAIL=$((FAIL + 1)); RESULTS+="FAIL|$1\n"; }
log_warn() { echo -e "\033[1;33m  ⚠️  WARN: $1\033[0m"; WARN=$((WARN + 1)); RESULTS+="WARN|$1\n"; }

########################################
# Test 1: YAML Syntax (python yaml.safe_load)
########################################
log_test "YAML Syntax Validation"

for f in helm/vault/values.yaml helm/vault/values-local.yaml helm/vault/values-live.yaml argocd/vault-application.yaml; do
    if python3 -c "import yaml; yaml.safe_load(open('$f'))" 2>&1; then
        log_pass "YAML syntax: $f"
    else
        log_fail "YAML syntax: $f"
    fi
done

########################################
# Test 2: Bash Syntax (bash -n)
########################################
log_test "Bash Syntax Check"

for f in scripts/bootstrap.sh scripts/bootstrap-argocd.sh scripts/local-dev.sh scripts/init-vault.sh scripts/backup-vault.sh scripts/fix-storageclass.sh; do
    if [ -f "$f" ]; then
        if bash -n "$f" 2>&1; then
            log_pass "bash -n: $f"
        else
            log_fail "bash -n: $f"
        fi
    else
        log_warn "File not found: $f"
    fi
done

########################################
# Test 3: Helm Template — Base + Live
########################################
log_test "Helm Template: base + values-live.yaml"

helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo update > /dev/null 2>&1

if helm template vault hashicorp/vault \
    --version 0.32.0 \
    -f helm/vault/values.yaml \
    -f helm/vault/values-live.yaml \
    --namespace vault \
    > /tmp/rendered-live.yaml 2>&1; then
    log_pass "Helm template (Live) rendered successfully"

    # Validate rendered output has correct StorageClass
    if grep -q "microk8s-hostpath-immediate" /tmp/rendered-live.yaml; then
        log_pass "Live: StorageClass 'microk8s-hostpath-immediate' present"
    else
        log_fail "Live: StorageClass 'microk8s-hostpath-immediate' missing"
    fi

    # Validate rendered output has fix-permissions init container
    if grep -q "fix-permissions" /tmp/rendered-live.yaml; then
        log_pass "Live: fix-permissions init container present"
    else
        log_fail "Live: fix-permissions init container missing"
    fi

    # Validate data storage size
    if grep -q "10Gi" /tmp/rendered-live.yaml; then
        log_pass "Live: dataStorage size 10Gi present"
    else
        log_fail "Live: dataStorage size 10Gi missing"
    fi

    # Validate audit storage size
    if grep -q "5Gi" /tmp/rendered-live.yaml; then
        log_pass "Live: auditStorage size 5Gi present"
    else
        log_fail "Live: auditStorage size 5Gi missing"
    fi

    # Validate Ingress host vault.local
    if grep -q "vault.local" /tmp/rendered-live.yaml; then
        log_pass "Live: Ingress host vault.local present"
    else
        log_fail "Live: Ingress host vault.local missing"
    fi

    # Validate TLS secret reference
    if grep -q "vault-tls" /tmp/rendered-live.yaml; then
        log_pass "Live: TLS secret vault-tls referenced"
    else
        log_fail "Live: TLS secret vault-tls missing"
    fi
else
    log_fail "Helm template (Live) failed"
fi

########################################
# Test 4: Helm Template — Base + Local
########################################
log_test "Helm Template: base + values-local.yaml"

if helm template vault hashicorp/vault \
    --version 0.32.0 \
    -f helm/vault/values.yaml \
    -f helm/vault/values-local.yaml \
    --namespace vault \
    > /tmp/rendered-local.yaml 2>&1; then
    log_pass "Helm template (Local) rendered successfully"

    # Validate rendered output has correct StorageClass
    if grep -q "storageClassName: standard" /tmp/rendered-local.yaml; then
        log_pass "Local: StorageClass 'standard' present"
    else
        log_fail "Local: StorageClass 'standard' missing"
    fi

    # Validate no fix-permissions init container
    if grep -q "fix-permissions" /tmp/rendered-local.yaml; then
        log_fail "Local: fix-permissions init container should NOT be present"
    else
        log_pass "Local: fix-permissions init container correctly absent"
    fi

    # Validate data storage size
    if grep -q "2Gi" /tmp/rendered-local.yaml; then
        log_pass "Local: dataStorage size 2Gi present"
    else
        log_fail "Local: dataStorage size 2Gi missing"
    fi

    # Validate NodePort service
    if grep -q "NodePort" /tmp/rendered-local.yaml; then
        log_pass "Local: NodePort service type present"
    else
        log_fail "Local: NodePort service type missing"
    fi

    # Validate relaxed resources
    if grep -q "512Mi" /tmp/rendered-local.yaml; then
        log_pass "Local: Relaxed memory limit (512Mi) present"
    else
        log_fail "Local: Relaxed memory limit (512Mi) missing"
    fi

    # Validate Ingress is disabled for local
    if grep -q "kind: Ingress" /tmp/rendered-local.yaml; then
        log_fail "Local: Ingress should be disabled"
    else
        log_pass "Local: Ingress correctly disabled"
    fi
else
    log_fail "Helm template (Local) failed"
fi

########################################
# Test 5: Values Merge Correctness
########################################
log_test "Values Merge Edge Cases"

# Live should NOT have NodePort
if grep -q "type: NodePort" /tmp/rendered-live.yaml 2>/dev/null; then
    log_fail "Live: Should not have NodePort (leaking from local?)"
else
    log_pass "Live: Correctly uses ClusterIP (no NodePort leak)"
fi

# Local should NOT have microk8s storageclass
if grep -q "microk8s-hostpath-immediate" /tmp/rendered-local.yaml 2>/dev/null; then
    log_fail "Local: Should not have microk8s StorageClass"
else
    log_pass "Local: No microk8s StorageClass (correct)"
fi

# Both should have standalone enabled
for env in live local; do
    if grep -q 'storage "file"' /tmp/rendered-${env}.yaml 2>/dev/null; then
        log_pass "${env}: Standalone file storage configured"
    else
        log_fail "${env}: Missing standalone file storage"
    fi
done

# Both should have HA disabled (no raft)
for env in live local; do
    if grep -q "raft" /tmp/rendered-${env}.yaml 2>/dev/null; then
        log_fail "${env}: Raft storage found (should be standalone)"
    else
        log_pass "${env}: No Raft storage (standalone mode correct)"
    fi
done

# IPC_LOCK should be defined in the base values (Helm chart injects it at runtime)
if grep -q "IPC_LOCK" helm/vault/values.yaml; then
    log_pass "IPC_LOCK capability defined in base values.yaml"
else
    log_fail "IPC_LOCK capability missing from base values.yaml"
fi

########################################
# Test 6: ArgoCD Application Manifest
########################################
log_test "ArgoCD Application Manifest"

# Check that values-live.yaml is in the ArgoCD app
if grep -q "values-live.yaml" argocd/vault-application.yaml; then
    log_pass "ArgoCD: references values-live.yaml"
else
    log_fail "ArgoCD: missing values-live.yaml reference"
fi

# Check that values-local.yaml is NOT in ArgoCD (local is manual)
if grep -q "values-local.yaml" argocd/vault-application.yaml; then
    log_fail "ArgoCD: should not reference values-local.yaml (local is manual)"
else
    log_pass "ArgoCD: correctly does not reference values-local.yaml"
fi

# Check apiVersion
if grep -q "apiVersion: argoproj.io/v1alpha1" argocd/vault-application.yaml; then
    log_pass "ArgoCD: correct apiVersion"
else
    log_fail "ArgoCD: wrong apiVersion"
fi

########################################
# Test 7: GHA Workflow Validation
########################################
log_test "GitHub Actions Workflows"

# deploy.yaml should NOT have staging
if grep -q "staging" .github/workflows/deploy.yaml; then
    log_fail "deploy.yaml: still contains 'staging'"
else
    log_pass "deploy.yaml: 'staging' removed"
fi

# lint-validate.yaml should reference both env files
if grep -q "values-live.yaml" .github/workflows/lint-validate.yaml && \
   grep -q "values-local.yaml" .github/workflows/lint-validate.yaml; then
    log_pass "lint-validate.yaml: references both env value files"
else
    log_fail "lint-validate.yaml: missing env value file references"
fi

########################################
# Test 8: Stale HA References
########################################
log_test "Stale HA Reference Check"

# bootstrap.sh should not check for >= 3 pods
if grep -q 'ge 3' scripts/bootstrap.sh; then
    log_fail "bootstrap.sh: still has >= 3 pod check"
else
    log_pass "bootstrap.sh: pod check fixed (>= 1)"
fi

# bootstrap-argocd.sh should not check for >= 3 pods
if grep -q 'ge 3' scripts/bootstrap-argocd.sh; then
    log_fail "bootstrap-argocd.sh: still has >= 3 pod check"
else
    log_pass "bootstrap-argocd.sh: pod check fixed (>= 1)"
fi

# values.yaml should not have active Raft config (comments warning about Raft are OK)
if grep -v '^\s*#' helm/vault/values.yaml | grep -qi 'raft'; then
    log_fail "values.yaml: active Raft config found (should be standalone)"
else
    log_pass "values.yaml: no active Raft config (comments-only OK)"          
fi

########################################
# Test 9: Documentation Checks
########################################
log_test "Documentation Validation"

# README should have Environments section
if grep -q "Environments" README.md; then
    log_pass "README.md: Environments section present"
else
    log_fail "README.md: Environments section missing"
fi

# README should mention values-local.yaml and values-live.yaml
if grep -q "values-local.yaml" README.md && grep -q "values-live.yaml" README.md; then
    log_pass "README.md: references both value files"
else
    log_fail "README.md: missing value file references"
fi

# README should mention local-dev.sh
if grep -q "local-dev.sh" README.md; then
    log_pass "README.md: references local-dev.sh"
else
    log_fail "README.md: missing local-dev.sh reference"
fi

# DEPLOYMENT.md should be scoped to Live
if grep -q "Live" DEPLOYMENT.md; then
    log_pass "DEPLOYMENT.md: scoped to Live environment"
else
    log_fail "DEPLOYMENT.md: not scoped to Live"
fi

# DEPLOYMENT.md should cross-reference local-dev.sh
if grep -q "local-dev.sh" DEPLOYMENT.md; then
    log_pass "DEPLOYMENT.md: cross-references local-dev.sh"
else
    log_fail "DEPLOYMENT.md: missing local-dev.sh reference"
fi

########################################
# Test 10: File Existence & Permissions
########################################
log_test "File Existence"

for f in helm/vault/values.yaml helm/vault/values-local.yaml helm/vault/values-live.yaml \
         argocd/vault-application.yaml scripts/local-dev.sh; do
    if [ -f "$f" ]; then
        log_pass "Exists: $f"
    else
        log_fail "Missing: $f"
    fi
done

########################################
# Summary
########################################
echo ""
echo -e "\033[1m════════════════════════════════════════════════════\033[0m"
echo -e "\033[1m  TEST RESULTS SUMMARY\033[0m"
echo -e "\033[1m════════════════════════════════════════════════════\033[0m"
echo -e "  \033[0;32m✅ Passed: $PASS\033[0m"
echo -e "  \033[0;31m❌ Failed: $FAIL\033[0m"
echo -e "  \033[1;33m⚠️  Warnings: $WARN\033[0m"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "\033[0;32m  ALL TESTS PASSED\033[0m"
else
    echo -e "\033[0;31m  SOME TESTS FAILED — see above for details\033[0m"
    echo ""
    echo "Failed tests:"
    echo -e "$RESULTS" | grep "^FAIL" | while IFS='|' read -r status desc; do
        echo "  ❌ $desc"
    done
fi

echo ""
exit $FAIL
