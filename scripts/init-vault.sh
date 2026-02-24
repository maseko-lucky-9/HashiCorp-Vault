#!/bin/bash
set -euo pipefail

################################################################################
# Vault Initialization Script
#
# Run this ONCE after the first deployment to initialize and configure Vault.
#
# ⚠️  SECURITY: This script prints unseal keys and root token to stdout.
#    NEVER run this in CI/CD pipelines — keys will be captured in logs.
#    Always run interactively via SSH to the server.
#
# Usage:
#   ./init-vault.sh                  # Initialize and unseal all pods
#   ./init-vault.sh --unseal-only    # Only unseal (skip init, use saved keys)
################################################################################

# ── Configuration ────────────────────────────────────────────────────────────
VAULT_NAMESPACE="vault"
VAULT_ADDR="http://127.0.0.1:8200"   # TLS is disabled in this deployment
PODS=("vault-0")  # Standalone mode — single pod
KEY_SHARES=5
KEY_THRESHOLD=3

# ── Color Output ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()         { echo -e "${CYAN}[$(date +'%H:%M:%S')]${NC} $*"; }
log_success() { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✅ $*${NC}"; }
log_error()   { echo -e "${RED}[$(date +'%H:%M:%S')] ❌ $*${NC}" >&2; }
log_warning() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠️  $*${NC}"; }

# ── Helper: execute vault command inside a pod ────────────────────────────────
vault_exec() {
    local pod="$1"; shift
    kubectl exec -n "$VAULT_NAMESPACE" "$pod" -c vault -- \
        sh -c "VAULT_ADDR=$VAULT_ADDR vault $*"
}

################################################################################
# Phase 1: Pre-flight Checks
################################################################################

preflight() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Vault Initialization Script${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""

    # Check kubectl connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    log_success "Cluster connectivity confirmed"

    # Check vault namespace exists
    if ! kubectl get namespace "$VAULT_NAMESPACE" &> /dev/null; then
        log_error "Namespace '$VAULT_NAMESPACE' not found — deploy Vault first"
        exit 1
    fi

    # Check vault pods exist
    local pod_count
    pod_count=$(kubectl get pods -n "$VAULT_NAMESPACE" -l app.kubernetes.io/name=vault \
        --no-headers 2>/dev/null | wc -l)

    if [ "$pod_count" -eq 0 ]; then
        log_error "No Vault pods found in namespace '$VAULT_NAMESPACE'"
        exit 1
    fi
    log "Found $pod_count Vault pod(s)"
}

################################################################################
# Phase 2: Wait for pod to be running (handles CrashLoopBackOff)
################################################################################

wait_for_pod_running() {
    local pod="$1"
    local max_wait=120
    local elapsed=0

    log "Waiting for $pod container to be running..."

    while [ $elapsed -lt $max_wait ]; do
        local phase
        phase=$(kubectl get pod "$pod" -n "$VAULT_NAMESPACE" \
            -o jsonpath='{.status.containerStatuses[?(@.name=="vault")].state}' 2>/dev/null || echo "")

        # Check if the vault container has a "running" state
        if echo "$phase" | grep -q "running"; then
            log_success "$pod vault container is running"
            return 0
        fi

        # If in CrashLoopBackOff with high backoff, delete pod to reset
        local restart_count
        restart_count=$(kubectl get pod "$pod" -n "$VAULT_NAMESPACE" \
            -o jsonpath='{.status.containerStatuses[?(@.name=="vault")].restartCount}' 2>/dev/null || echo "0")

        if [ "$restart_count" -gt 5 ] && [ $elapsed -gt 30 ]; then
            log_warning "$pod has restarted $restart_count times — deleting to reset backoff"
            kubectl delete pod "$pod" -n "$VAULT_NAMESPACE" --wait=false 2>/dev/null || true
            sleep 5
        fi

        sleep 3
        elapsed=$((elapsed + 3))
    done

    log_error "$pod did not reach Running state within ${max_wait}s"
    return 1
}

################################################################################
# Phase 3: Check initialization state
################################################################################

check_init_status() {
    wait_for_pod_running "vault-0"

    local status
    status=$(vault_exec "vault-0" "status -format=json" 2>/dev/null || echo '{}')

    VAULT_INITIALIZED=$(echo "$status" | grep -o '"initialized":[a-z]*' | cut -d: -f2 || echo "false")
    VAULT_SEALED=$(echo "$status" | grep -o '"sealed":[a-z]*' | cut -d: -f2 || echo "true")

    log "Vault status — initialized: $VAULT_INITIALIZED, sealed: $VAULT_SEALED"
}

################################################################################
# Phase 4: Initialize Vault
################################################################################

initialize_vault() {
    if [ "$VAULT_INITIALIZED" = "true" ]; then
        log_warning "Vault is already initialized — skipping init"
        return 0
    fi

    log "Initializing Vault with $KEY_SHARES key shares, threshold $KEY_THRESHOLD..."

    INIT_OUTPUT=$(vault_exec "vault-0" "operator init -key-shares=$KEY_SHARES -key-threshold=$KEY_THRESHOLD -format=json")

    # Extract keys and root token
    UNSEAL_KEYS=()
    while IFS= read -r key; do
        UNSEAL_KEYS+=("$key")
    done < <(echo "$INIT_OUTPUT" | grep -oP '"unseal_keys_b64":\s*\[([^\]]+)\]' | grep -oP '"[A-Za-z0-9+/=]+"' | tr -d '"')

    ROOT_TOKEN=$(echo "$INIT_OUTPUT" | grep -oP '"root_token":\s*"[^"]+"' | grep -oP '"[^"]+"\s*$' | tr -d '"' | xargs)

    if [ ${#UNSEAL_KEYS[@]} -eq 0 ]; then
        # Fallback: try jq if available
        if command -v jq &>/dev/null; then
            mapfile -t UNSEAL_KEYS < <(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[]')
            ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')
        else
            log_error "Failed to parse init output. Raw output:"
            echo "$INIT_OUTPUT"
            exit 1
        fi
    fi

    echo ""
    echo -e "${RED}${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}${BOLD}  CRITICAL: Save these credentials NOW — shown ONLY ONCE!    ${NC}"
    echo -e "${RED}${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Unseal Keys:${NC}"
    for i in "${!UNSEAL_KEYS[@]}"; do
        echo "  Key $((i+1)): ${UNSEAL_KEYS[$i]}"
    done
    echo ""
    echo -e "${CYAN}Root Token:${NC}  $ROOT_TOKEN"
    echo ""
    echo -e "${YELLOW}Store these in a password manager or encrypted offline storage${NC}"
    echo ""

    VAULT_INITIALIZED="true"
    log_success "Vault initialized successfully"
}

################################################################################
# Phase 5: Unseal vault-0
################################################################################

unseal_pod() {
    local pod="$1"

    wait_for_pod_running "$pod"

    # Check if already unsealed
    local sealed
    sealed=$(vault_exec "$pod" "status -format=json" 2>/dev/null | \
        grep -o '"sealed":[a-z]*' | cut -d: -f2 || echo "true")

    if [ "$sealed" = "false" ]; then
        log_success "$pod is already unsealed"
        return 0
    fi

    log "Unsealing $pod..."
    for i in $(seq 0 $((KEY_THRESHOLD - 1))); do
        vault_exec "$pod" "operator unseal ${UNSEAL_KEYS[$i]}" > /dev/null 2>&1
    done

    # Verify
    sealed=$(vault_exec "$pod" "status -format=json" 2>/dev/null | \
        grep -o '"sealed":[a-z]*' | cut -d: -f2 || echo "true")

    if [ "$sealed" = "false" ]; then
        log_success "$pod unsealed successfully"
    else
        log_error "$pod is still sealed after unseal attempt"
        return 1
    fi
}

unseal_all() {
    if [ ${#UNSEAL_KEYS[@]} -eq 0 ]; then
        log_error "No unseal keys available. Provide keys via --unseal-only mode."
        exit 1
    fi

    for pod in "${PODS[@]}"; do
        unseal_pod "$pod"
    done
}

################################################################################
# Phase 6: Configure Vault (first-time only)
################################################################################

configure_vault() {
    if [ "$1" = "skip" ]; then
        return 0
    fi

    log "Logging in with root token..."
    vault_exec "vault-0" "login $ROOT_TOKEN" > /dev/null 2>&1

    echo ""
    log "Configuring Vault..."

    # Enable Kubernetes auth
    log "Enabling Kubernetes auth method..."
    vault_exec "vault-0" "auth enable kubernetes" 2>/dev/null || \
        log_warning "Kubernetes auth already enabled"

    log "Configuring Kubernetes auth..."
    vault_exec "vault-0" "write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443"

    # Enable KV v2 secrets engine
    log "Enabling KV v2 secrets engine at 'secret'..."
    vault_exec "vault-0" "secrets enable -path=secret kv-v2" 2>/dev/null || \
        log_warning "KV v2 already enabled"

    # Enable audit logging
    log "Enabling file audit device..."
    vault_exec "vault-0" "audit enable file file_path=/vault/audit/vault-audit.log" 2>/dev/null || \
        log_warning "File audit already enabled"

    # Apply policies
    log "Applying Vault policies..."
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local policies_dir="$script_dir/../policies"

    for policy in app-readonly admin database-dynamic; do
        if [ -f "$policies_dir/${policy}.hcl" ]; then
            kubectl exec -n "$VAULT_NAMESPACE" vault-0 -c vault -i -- \
                sh -c "VAULT_ADDR=$VAULT_ADDR vault policy write $policy -" < "$policies_dir/${policy}.hcl"
            log_success "Policy '$policy' applied"
        else
            log_warning "Policy file not found: $policies_dir/${policy}.hcl"
        fi
    done

    log_success "Vault configuration complete"
}

################################################################################
# Phase 7: Health Check
################################################################################

health_check() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  System Health Check${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""

    local all_healthy=true

    for pod in "${PODS[@]}"; do
        local status
        status=$(vault_exec "$pod" "status -format=json" 2>/dev/null || echo '{}')

        local initialized sealed ha_mode
        initialized=$(echo "$status" | grep -o '"initialized":[a-z]*' | cut -d: -f2 || echo "unknown")
        sealed=$(echo "$status" | grep -o '"sealed":[a-z]*' | cut -d: -f2 || echo "unknown")

        if [ "$initialized" = "true" ] && [ "$sealed" = "false" ]; then
            log_success "$pod — initialized, unsealed ✅"
        elif [ "$initialized" = "true" ] && [ "$sealed" = "true" ]; then
            log_warning "$pod — initialized but SEALED ⚠️"
            all_healthy=false
        else
            log_error "$pod — not healthy (initialized=$initialized, sealed=$sealed)"
            all_healthy=false
        fi
    done

    echo ""

    # Check Raft peers (only if using Raft storage backend)
    log "Checking storage backend..."
    local raft_peers
    raft_peers=$(vault_exec "vault-0" "operator raft list-peers -format=json" 2>/dev/null || echo "")

    if [ -n "$raft_peers" ]; then
        local peer_count
        peer_count=$(echo "$raft_peers" | grep -o '"node_id"' | wc -l || echo "0")
        log_success "Raft cluster has $peer_count peer(s)"
    else
        log "File storage backend detected — no Raft peers (expected for standalone)"
    fi

    # Check Kubernetes pods
    echo ""
    log "Kubernetes pod status:"
    kubectl get pods -n "$VAULT_NAMESPACE" -l app.kubernetes.io/name=vault -o wide

    # Check PVCs
    echo ""
    log "PVC status:"
    kubectl get pvc -n "$VAULT_NAMESPACE"

    # Check services
    echo ""
    log "Service status:"
    kubectl get svc -n "$VAULT_NAMESPACE"

    echo ""
    if $all_healthy; then
        echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  ✅ All Vault pods are healthy and unsealed${NC}"
        echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
    else
        echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}  ⚠️  Some pods are not fully healthy${NC}"
        echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
    fi

    echo ""
    echo -e "${CYAN}Next steps:${NC}"
    echo "  1. Save unseal keys and root token to secure storage"
    echo "  2. Revoke root token: vault token revoke <ROOT_TOKEN>"
    echo "  3. Create app roles: vault write auth/kubernetes/role/app-role ..."
    echo "  4. Test secret injection with a sample workload"
    echo ""
}

################################################################################
# Unseal-Only Mode (for server reboots)
################################################################################

unseal_only_mode() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Vault Unseal Mode${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""
    echo "Enter $KEY_THRESHOLD unseal keys (one per line):"

    UNSEAL_KEYS=()
    for i in $(seq 1 "$KEY_THRESHOLD"); do
        read -r -s -p "  Key $i: " key
        echo ""
        UNSEAL_KEYS+=("$key")
    done

    unseal_all
    health_check
}

################################################################################
# Main
################################################################################

main() {
    # Parse arguments
    local mode="full"
    for arg in "$@"; do
        case "$arg" in
            --unseal-only) mode="unseal" ;;
            --health-check) mode="health" ;;
            --help|-h)
                echo "Usage: $(basename "$0") [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --unseal-only   Unseal pods using saved keys (no init)"
                echo "  --health-check  Run health check only"
                echo "  --help          Show this help"
                exit 0
                ;;
            *) log_error "Unknown argument: $arg"; exit 1 ;;
        esac
    done

    preflight

    case "$mode" in
        unseal)
            unseal_only_mode
            ;;
        health)
            health_check
            ;;
        full)
            check_init_status
            initialize_vault
            unseal_all
            configure_vault "apply"
            health_check
            ;;
    esac
}

main "$@"
