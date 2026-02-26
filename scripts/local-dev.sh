#!/bin/bash
set -euo pipefail

################################################################################
# Vault Local Development Bootstrap (WSL + Minikube)
#
# Purpose: Quick local Vault deployment for development and testing
# Runtime: WSL 2 with Minikube (Docker or Hyperv driver)
#
# Usage:
#   ./local-dev.sh              # Full bootstrap
#   ./local-dev.sh --teardown   # Remove everything
#   ./local-dev.sh --status     # Check deployment status
#
# Prerequisites:
#   - Minikube installed (https://minikube.sigs.k8s.io/docs/start/)
#   - kubectl installed
#   - Helm 3.12+ installed
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VAULT_NAMESPACE="vault"
HELM_CHART_VERSION="0.32.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()         { echo -e "${BLUE}[LOCAL]${NC} $*"; }
log_success() { echo -e "${GREEN}[LOCAL] ✅ $*${NC}"; }
log_error()   { echo -e "${RED}[LOCAL] ❌ $*${NC}" >&2; }
log_warning() { echo -e "${YELLOW}[LOCAL] ⚠️  $*${NC}"; }

################################################################################
# Teardown
################################################################################

teardown() {
    log "Tearing down local Vault deployment..."

    if helm status vault -n "$VAULT_NAMESPACE" &> /dev/null; then
        helm uninstall vault -n "$VAULT_NAMESPACE"
        log_success "Vault Helm release removed"
    else
        log_warning "No Vault Helm release found"
    fi

    if kubectl get namespace "$VAULT_NAMESPACE" &> /dev/null; then
        kubectl delete namespace "$VAULT_NAMESPACE" --timeout=60s
        log_success "Namespace $VAULT_NAMESPACE deleted"
    fi

    log_success "Teardown complete"
    exit 0
}

################################################################################
# Status
################################################################################

show_status() {
    echo ""
    log "Vault Local Deployment Status"
    echo "─────────────────────────────────────────"

    # Minikube
    if minikube status &> /dev/null; then
        log_success "Minikube: running"
    else
        log_error "Minikube: stopped"
    fi

    # Helm release
    if helm status vault -n "$VAULT_NAMESPACE" &> /dev/null; then
        log_success "Helm release: deployed"
    else
        log_warning "Helm release: not found"
    fi

    # Pods
    echo ""
    kubectl get pods -n "$VAULT_NAMESPACE" 2>/dev/null || log_warning "No pods found"

    # PVCs
    echo ""
    kubectl get pvc -n "$VAULT_NAMESPACE" 2>/dev/null || log_warning "No PVCs found"

    # Access URL
    echo ""
    local vault_url
    vault_url=$(minikube service vault-ui -n "$VAULT_NAMESPACE" --url 2>/dev/null || echo "")
    if [ -n "$vault_url" ]; then
        log "Vault UI: $vault_url"
    else
        log "Vault UI: kubectl port-forward svc/vault -n vault 8200:8200"
    fi

    echo ""
    exit 0
}

################################################################################
# Prerequisites
################################################################################

check_prerequisites() {
    log "Checking prerequisites..."
    local missing=0

    if ! command -v minikube &> /dev/null; then
        log_error "minikube not found. Install: https://minikube.sigs.k8s.io/docs/start/"
        missing=1
    fi

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Install: https://kubernetes.io/docs/tasks/tools/"
        missing=1
    fi

    if ! command -v helm &> /dev/null; then
        log_error "helm not found. Install: https://helm.sh/docs/intro/install/"
        missing=1
    fi

    if [ $missing -ne 0 ]; then
        exit 1
    fi

    log_success "All prerequisites met"
}

################################################################################
# Minikube
################################################################################

ensure_minikube() {
    log "Checking Minikube..."

    if minikube status &> /dev/null; then
        log_success "Minikube is running"
    else
        log "Starting Minikube..."
        minikube start --memory=4096 --cpus=2
        log_success "Minikube started"
    fi
}

################################################################################
# Deploy
################################################################################

deploy_vault() {
    log "Deploying Vault to local Minikube..."

    # Create namespace
    if ! kubectl get namespace "$VAULT_NAMESPACE" &> /dev/null; then
        kubectl create namespace "$VAULT_NAMESPACE"
        log_success "Created namespace: $VAULT_NAMESPACE"
    fi

    # Add Helm repo
    helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
    helm repo update > /dev/null

    # Install/upgrade with base + local values
    helm upgrade --install vault hashicorp/vault \
        --version "$HELM_CHART_VERSION" \
        --namespace "$VAULT_NAMESPACE" \
        -f "$REPO_DIR/helm/vault/values.yaml" \
        -f "$REPO_DIR/helm/vault/values-local.yaml" \
        --timeout 5m

    log_success "Vault Helm release deployed"

    # Apply shared manifests (NetworkPolicy, PDB)
    log "Applying shared manifests..."
    kubectl apply -f "$REPO_DIR/manifests/network-policy.yaml" -n "$VAULT_NAMESPACE" || true
    kubectl apply -f "$REPO_DIR/manifests/pod-disruption-budget.yaml" -n "$VAULT_NAMESPACE" || true
    log_success "Shared manifests applied"
}

################################################################################
# Wait & Verify
################################################################################

wait_for_vault() {
    log "Waiting for vault-0 to start..."

    local attempts=0
    local max_attempts=30

    while [ $attempts -lt $max_attempts ]; do
        local phase
        phase=$(kubectl get pod vault-0 -n "$VAULT_NAMESPACE" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")

        if [ "$phase" = "Running" ]; then
            log_success "vault-0 is running (sealed — needs initialization)"
            return 0
        fi

        sleep 5
        ((attempts++))
    done

    log_error "vault-0 did not start within $((max_attempts * 5))s"
    log "Debug: kubectl describe pod vault-0 -n $VAULT_NAMESPACE"
    return 1
}

################################################################################
# Access Instructions
################################################################################

print_instructions() {
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Local Vault Deployment Ready!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BLUE}Next Steps:${NC}"
    echo ""
    echo "  1. Initialize Vault:"
    echo "     kubectl exec -n vault vault-0 -- vault operator init"
    echo ""
    echo "  2. Unseal with 3 of 5 keys:"
    echo "     kubectl exec -n vault vault-0 -- vault operator unseal <key>"
    echo ""
    echo "  3. Access Vault UI:"
    echo "     kubectl port-forward svc/vault -n vault 8200:8200"
    echo "     Then open: http://localhost:8200"
    echo ""
    echo "  4. Or use the full init script:"
    echo "     cd scripts && ./init-vault.sh"
    echo ""
    echo -e "${YELLOW}Teardown:${NC}  ./local-dev.sh --teardown"
    echo -e "${YELLOW}Status:${NC}    ./local-dev.sh --status"
    echo ""
}

################################################################################
# Main
################################################################################

main() {
    # Parse args
    for arg in "$@"; do
        case "$arg" in
            --teardown)  teardown ;;
            --status)    show_status ;;
            --help|-h)
                echo "Usage: $0 [--teardown|--status|--help]"
                exit 0
                ;;
            *) log_error "Unknown argument: $arg"; exit 1 ;;
        esac
    done

    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Vault Local Development Bootstrap${NC}"
    echo -e "${BLUE}  WSL + Minikube │ Standalone Mode${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo ""

    check_prerequisites
    ensure_minikube
    deploy_vault
    wait_for_vault
    print_instructions

    log_success "Local bootstrap complete!"
}

main "$@"
