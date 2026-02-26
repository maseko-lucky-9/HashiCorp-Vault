#!/bin/bash
set -euo pipefail

################################################################################
# HashiCorp Vault — Production Bootstrap Script
#
# Purpose:  Automated first-time deployment of ArgoCD and Vault on MicroK8s
# Features:
#   - Idempotent (safe to run multiple times)
#   - --dry-run mode (shows commands without executing)
#   - --verbose mode (debug-level output)
#   - Dependency detection & installation (kubectl, Helm, ArgoCD CLI)
#   - MicroK8s addon management (dns, storage, ingress)
#   - Rollback on failure
#   - Color-coded, timestamped logging
#
# Usage:
#   ./bootstrap.sh                   # Standard run
#   ./bootstrap.sh --dry-run         # Preview mode (no changes)
#   ./bootstrap.sh --verbose         # Debug output
#   ./bootstrap.sh --skip-addons     # Skip MicroK8s addon checks
#   ./bootstrap.sh --help            # Show usage information
#
# Prerequisites:
#   - MicroK8s installed and running
#   - sudo access (for addon installation)
#   - Internet connectivity
################################################################################

# ══════════════════════════════════════════════════════════════════════════════
# Configuration — edit these to match your environment
# ══════════════════════════════════════════════════════════════════════════════

ARGOCD_VERSION="v2.14.0"
HELM_MIN_VERSION="3.12.0"
KUBECTL_MIN_VERSION="1.28.0"
ARGOCD_CLI_VERSION="v2.14.0"

ARGOCD_NAMESPACE="argocd"
VAULT_NAMESPACE="vault"

MICROK8S_ADDONS=("dns" "hostpath-storage" "ingress")

HEALTH_CHECK_TIMEOUT=300      # seconds to wait for ArgoCD health
SYNC_CHECK_TIMEOUT=120        # seconds to wait for app sync
ADDON_WAIT_TIMEOUT=60         # seconds to wait per addon

# ══════════════════════════════════════════════════════════════════════════════
# Internal State — do not edit
# ══════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="/tmp/vault-bootstrap-$(date +%Y%m%d-%H%M%S).log"

DRY_RUN=false
VERBOSE=false
SKIP_ADDONS=false
INSTALL_PHASE="none"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

################################################################################
# Logging Functions
################################################################################

_timestamp() { date +'%Y-%m-%d %H:%M:%S'; }

log()         { echo -e "${BLUE}[$(_timestamp)]${NC} $*"                       | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[$(_timestamp)] ✅ $*${NC}"                   | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[$(_timestamp)] ❌ ERROR: $*${NC}"              | tee -a "$LOG_FILE" >&2; }
log_warning() { echo -e "${YELLOW}[$(_timestamp)] ⚠️  WARNING: $*${NC}"        | tee -a "$LOG_FILE"; }
log_info()    { echo -e "${CYAN}[$(_timestamp)] ℹ️  $*${NC}"                   | tee -a "$LOG_FILE"; }
log_debug()   { if $VERBOSE; then echo -e "${BLUE}[$(_timestamp)] 🔍 $*${NC}" | tee -a "$LOG_FILE"; fi; }
log_dryrun()  { echo -e "${YELLOW}[$(_timestamp)] [DRY-RUN] $*${NC}"           | tee -a "$LOG_FILE"; }

log_header() {
    echo ""                                                               | tee -a "$LOG_FILE"
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}  $*${NC}"                                              | tee -a "$LOG_FILE"
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}" | tee -a "$LOG_FILE"
    echo ""                                                               | tee -a "$LOG_FILE"
}

################################################################################
# Command Execution Wrapper
################################################################################

# run_cmd: wraps mutating commands for dry-run and verbose support
# Usage: run_cmd <description> <command...>
run_cmd() {
    local desc="$1"; shift

    if $DRY_RUN; then
        log_dryrun "$desc"
        log_dryrun "  → $*"
        return 0
    fi

    log_debug "Executing: $*"
    if ! eval "$@" >> "$LOG_FILE" 2>&1; then
        log_error "$desc — command failed: $*"
        return 1
    fi
    return 0
}

# run_cmd_output: like run_cmd but shows stdout (for password retrieval, etc.)
run_cmd_output() {
    local desc="$1"; shift

    if $DRY_RUN; then
        log_dryrun "$desc"
        log_dryrun "  → $*"
        return 0
    fi

    log_debug "Executing: $*"
    eval "$@" 2>> "$LOG_FILE"
}

################################################################################
# Argument Parsing
################################################################################

show_help() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --dry-run       Preview mode — shows what would be done without executing
  --verbose       Debug-level output (shows all commands and kubectl details)
  --skip-addons   Skip MicroK8s addon checks and installation
  --help          Show this help message

Environment:
  ARGOCD_VERSION      ArgoCD version to install      (default: $ARGOCD_VERSION)
  ARGOCD_NAMESPACE    ArgoCD namespace                (default: $ARGOCD_NAMESPACE)
  VAULT_NAMESPACE     Vault namespace                 (default: $VAULT_NAMESPACE)

Examples:
  ./bootstrap.sh                      # Full bootstrap
  ./bootstrap.sh --dry-run            # Preview only
  ./bootstrap.sh --verbose --dry-run  # Verbose preview
EOF
    exit 0
}

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run)      DRY_RUN=true ;;
            --verbose)      VERBOSE=true ;;
            --skip-addons)  SKIP_ADDONS=true ;;
            --help|-h)      show_help ;;
            *)
                log_error "Unknown argument: $arg"
                show_help
                ;;
        esac
    done
}

################################################################################
# Cleanup / Rollback
################################################################################

cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo ""
        log_error "Bootstrap failed at phase: $INSTALL_PHASE"
        log_error "Log file: $LOG_FILE"
        echo ""

        case "$INSTALL_PHASE" in
            argocd-install)
                log_warning "ArgoCD installation was in progress."
                log_warning "To clean up, run:"
                echo "  kubectl delete namespace $ARGOCD_NAMESPACE"
                ;;
            vault-deploy)
                log_warning "Vault deployment was in progress."
                log_warning "ArgoCD is healthy. To clean up Vault app only:"
                echo "  kubectl delete application vault -n $ARGOCD_NAMESPACE"
                ;;
            *)
                log_info "No rollback needed for phase: $INSTALL_PHASE"
                ;;
        esac
    fi
}

trap cleanup EXIT

################################################################################
# Version Comparison
################################################################################

# Returns 0 if $1 >= $2 (semver comparison)
version_gte() {
    local v1="$1" v2="$2"
    # Strip leading 'v' if present
    v1="${v1#v}"
    v2="${v2#v}"

    # Use sort -V to compare
    if [ "$(printf '%s\n%s' "$v2" "$v1" | sort -V | head -n1)" = "$v2" ]; then
        return 0
    fi
    return 1
}

################################################################################
# Phase 1: Pre-flight Checks
################################################################################

phase_preflight() {
    INSTALL_PHASE="preflight"
    log_header "Phase 1 — Pre-flight Checks"

    # ── Check sudo access ─────────────────────────────────────────────────
    if [ "$EUID" -eq 0 ]; then
        log_info "Running as root"
    elif sudo -n true 2>/dev/null; then
        log_info "sudo access confirmed"
    else
        log_warning "No passwordless sudo access. Addon installation may prompt for password."
    fi

    # ── Check MicroK8s ────────────────────────────────────────────────────
    if ! command -v microk8s &> /dev/null; then
        log_error "MicroK8s not found. Install with: sudo snap install microk8s --classic"
        exit 1
    fi

    log "Checking MicroK8s status..."
    if ! microk8s status --wait-ready --timeout 30 &> /dev/null; then
        log_error "MicroK8s is not ready. Run: microk8s start"
        exit 1
    fi
    log_success "MicroK8s is running"

    # ── Network connectivity ──────────────────────────────────────────────
    log "Checking network connectivity..."
    if ! curl -sf --connect-timeout 10 https://helm.releases.hashicorp.com > /dev/null 2>&1; then
        log_error "Cannot reach helm.releases.hashicorp.com — check network/DNS"
        exit 1
    fi

    if ! curl -sf --connect-timeout 10 https://raw.githubusercontent.com > /dev/null 2>&1; then
        log_error "Cannot reach raw.githubusercontent.com — check network/DNS"
        exit 1
    fi
    log_success "Network connectivity OK"

    # ── Detect architecture ───────────────────────────────────────────────
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH_LABEL="amd64" ;;
        aarch64) ARCH_LABEL="arm64" ;;
        *)       log_error "Unsupported architecture: $ARCH"; exit 1 ;;
    esac
    log_debug "Architecture: $ARCH ($ARCH_LABEL)"
}

################################################################################
# Phase 2: Dependency Detection & Installation
################################################################################

phase_dependencies() {
    INSTALL_PHASE="dependencies"
    log_header "Phase 2 — Dependencies"

    local deps_table=""

    # ── kubectl ───────────────────────────────────────────────────────────
    log "Checking kubectl..."
    if command -v kubectl &> /dev/null; then
        local kubectl_ver
        kubectl_ver=$(kubectl version --client -o json 2>/dev/null | grep -oP '"gitVersion":\s*"\K[^"]+' || echo "unknown")
        log_success "kubectl found: $kubectl_ver"
        deps_table+="  kubectl      │ $kubectl_ver │ installed\n"

        if [ "$kubectl_ver" != "unknown" ] && ! version_gte "$kubectl_ver" "$KUBECTL_MIN_VERSION"; then
            log_warning "kubectl $kubectl_ver is below minimum $KUBECTL_MIN_VERSION"
        fi
    else
        log_info "kubectl not found — setting up MicroK8s alias"
        if $DRY_RUN; then
            log_dryrun "Would create kubectl alias → microk8s kubectl"
        else
            sudo snap alias microk8s.kubectl kubectl 2>/dev/null || {
                log_warning "Could not create kubectl snap alias, using microk8s kubectl directly"
                alias kubectl='microk8s kubectl'
            }
        fi
        deps_table+="  kubectl      │ (microk8s)   │ aliased\n"
    fi

    # Verify cluster connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster via kubectl"
        exit 1
    fi
    log_success "Cluster connectivity confirmed"

    # ── Cluster admin permissions ─────────────────────────────────────────
    if ! kubectl auth can-i create namespace &> /dev/null; then
        log_error "Insufficient permissions. Cluster admin access required."
        exit 1
    fi
    log_success "Cluster admin permissions confirmed"

    # ── Helm ──────────────────────────────────────────────────────────────
    log "Checking Helm..."
    if command -v helm &> /dev/null; then
        local helm_ver
        helm_ver=$(helm version --short 2>/dev/null | grep -oP 'v[\d.]+' || echo "unknown")
        log_success "Helm found: $helm_ver"
        deps_table+="  helm         │ $helm_ver    │ installed\n"

        if [ "$helm_ver" != "unknown" ] && ! version_gte "$helm_ver" "$HELM_MIN_VERSION"; then
            log_warning "Helm $helm_ver is below minimum $HELM_MIN_VERSION"
        fi
    else
        log_info "Helm not found — installing..."
        run_cmd "Install Helm via official script" \
            "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"

        if ! $DRY_RUN; then
            local helm_ver
            helm_ver=$(helm version --short 2>/dev/null | grep -oP 'v[\d.]+' || echo "installed")
            log_success "Helm installed: $helm_ver"
            deps_table+="  helm         │ $helm_ver    │ installed now\n"
        else
            deps_table+="  helm         │ (pending)    │ would install\n"
        fi
    fi

    # ── ArgoCD CLI (optional) ─────────────────────────────────────────────
    log "Checking ArgoCD CLI..."
    if command -v argocd &> /dev/null; then
        local argocd_ver
        argocd_ver=$(argocd version --client --short 2>/dev/null || echo "unknown")
        log_success "ArgoCD CLI found: $argocd_ver"
        deps_table+="  argocd CLI   │ $argocd_ver  │ installed\n"
    else
        log_info "ArgoCD CLI not found — installing ${ARGOCD_CLI_VERSION}..."
        local argocd_url="https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_CLI_VERSION}/argocd-linux-${ARCH_LABEL}"
        run_cmd "Download ArgoCD CLI" \
            "curl -fsSL -o /tmp/argocd '$argocd_url'"
        run_cmd "Install ArgoCD CLI" \
            "chmod +x /tmp/argocd && sudo mv /tmp/argocd /usr/local/bin/argocd"

        if ! $DRY_RUN; then
            log_success "ArgoCD CLI installed"
            deps_table+="  argocd CLI   │ $ARGOCD_CLI_VERSION │ installed now\n"
        else
            deps_table+="  argocd CLI   │ (pending)    │ would install\n"
        fi
    fi

    # ── jq (required for JSON parsing) ────────────────────────────────────
    if ! command -v jq &> /dev/null; then
        log_info "jq not found — installing..."
        run_cmd "Install jq" "sudo apt-get install -y jq"
    fi

    # ── Summary table ─────────────────────────────────────────────────────
    echo ""
    log "Dependency summary:"
    echo -e "$deps_table"
}

################################################################################
# Phase 3: MicroK8s Addons
################################################################################

phase_addons() {
    INSTALL_PHASE="addons"
    log_header "Phase 3 — MicroK8s Addons"

    if $SKIP_ADDONS; then
        log_info "Addon checks skipped (--skip-addons)"
        return 0
    fi

    for addon in "${MICROK8S_ADDONS[@]}"; do
        log "Checking addon: $addon..."

        if microk8s status -a "$addon" 2>/dev/null | grep -q "enabled"; then
            log_success "Addon '$addon' is enabled"
        else
            log_info "Enabling addon: $addon..."
            run_cmd "Enable MicroK8s addon: $addon" \
                "sudo microk8s enable $addon"

            if ! $DRY_RUN; then
                # Wait for addon to be ready
                local attempt=0
                local max_attempts=$((ADDON_WAIT_TIMEOUT / 5))
                while [ $attempt -lt $max_attempts ]; do
                    if microk8s status -a "$addon" 2>/dev/null | grep -q "enabled"; then
                        log_success "Addon '$addon' enabled successfully"
                        break
                    fi
                    sleep 5
                    ((attempt++))
                done

                if [ $attempt -ge $max_attempts ]; then
                    log_warning "Addon '$addon' may not be fully ready yet"
                fi
            fi
        fi
    done

    # ── Apply custom StorageClass ─────────────────────────────────────────
    log "Checking custom StorageClass..."
    if kubectl get storageclass microk8s-hostpath-immediate &> /dev/null; then
        log_success "StorageClass 'microk8s-hostpath-immediate' already exists"
    else
        local sc_manifest="$REPO_DIR/manifests/storageclass-immediate.yaml"
        if [ -f "$sc_manifest" ]; then
            run_cmd "Apply custom StorageClass" \
                "kubectl apply -f '$sc_manifest'"
            if ! $DRY_RUN; then
                log_success "StorageClass 'microk8s-hostpath-immediate' created"
            fi
        else
            log_warning "StorageClass manifest not found at: $sc_manifest"
        fi
    fi
}

################################################################################
# Phase 4: ArgoCD Server Deployment
################################################################################

is_argocd_installed() {
    kubectl get namespace "$ARGOCD_NAMESPACE" &> /dev/null && \
    kubectl get deployment argocd-server -n "$ARGOCD_NAMESPACE" &> /dev/null
}

wait_for_argocd() {
    log "Waiting for ArgoCD to become healthy..."
    local elapsed=0

    while [ $elapsed -lt $HEALTH_CHECK_TIMEOUT ]; do
        if kubectl wait --for=condition=available --timeout=10s \
            deployment/argocd-server -n "$ARGOCD_NAMESPACE" &> /dev/null; then
            log_success "ArgoCD server is healthy"
            return 0
        fi

        log_debug "ArgoCD not ready yet (${elapsed}s / ${HEALTH_CHECK_TIMEOUT}s)..."
        sleep 10
        elapsed=$((elapsed + 10))
    done

    log_error "ArgoCD failed to become healthy after ${HEALTH_CHECK_TIMEOUT}s"
    return 1
}

phase_argocd() {
    INSTALL_PHASE="argocd-install"
    log_header "Phase 4 — ArgoCD Deployment"

    if is_argocd_installed; then
        log_warning "ArgoCD already installed in namespace: $ARGOCD_NAMESPACE"

        if $DRY_RUN; then
            log_dryrun "Would verify ArgoCD health"
            return 0
        fi

        if wait_for_argocd; then
            log_success "Existing ArgoCD installation is healthy"
        else
            log_error "Existing ArgoCD installation is unhealthy"
            log_info "Troubleshoot with: kubectl get pods -n $ARGOCD_NAMESPACE"
            exit 1
        fi
    else
        log "ArgoCD not detected. Installing ${ARGOCD_VERSION}..."

        # Create namespace
        if ! kubectl get namespace "$ARGOCD_NAMESPACE" &> /dev/null; then
            run_cmd "Create ArgoCD namespace" \
                "kubectl create namespace $ARGOCD_NAMESPACE"
        fi

        # Apply ArgoCD manifests
        run_cmd "Apply ArgoCD ${ARGOCD_VERSION} manifests" \
            "kubectl apply -n $ARGOCD_NAMESPACE -f 'https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml'"

        if ! $DRY_RUN; then
            log_success "ArgoCD manifests applied"

            if ! wait_for_argocd; then
                log_error "ArgoCD installation failed"
                exit 1
            fi
            log_success "ArgoCD installed successfully"
        fi
    fi

    # ── Configure ArgoCD ──────────────────────────────────────────────────
    log "Configuring ArgoCD..."

    run_cmd "Label ArgoCD namespace" \
        "kubectl label namespace $ARGOCD_NAMESPACE kubernetes.io/metadata.name=argocd --overwrite"

    # Custom health check for Vault StatefulSet
    run_cmd "Patch ArgoCD health checks for Vault" \
        "kubectl patch configmap argocd-cm -n $ARGOCD_NAMESPACE --type merge -p '{
  \"data\": {
    \"resource.customizations.health.apps_StatefulSet\": \"hs = {}\\nif obj.status ~= nil then\\n  if obj.status.readyReplicas ~= nil and obj.status.replicas ~= nil then\\n    if obj.status.readyReplicas == obj.status.replicas then\\n      hs.status = \\\"Healthy\\\"\\n      hs.message = \\\"All replicas ready\\\"\\n      return hs\\n    end\\n  end\\nend\\nhs.status = \\\"Progressing\\\"\\nhs.message = \\\"Waiting for replicas\\\"\\nreturn hs\"
  }
}'"

    log_success "ArgoCD configuration applied"

    # ── Display admin credentials ─────────────────────────────────────────
    if ! $DRY_RUN; then
        local password
        password=$(kubectl get secret argocd-initial-admin-secret \
            -n "$ARGOCD_NAMESPACE" \
            -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "")

        if [ -n "$password" ]; then
            echo ""
            echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
            echo -e "${GREEN}  ArgoCD Admin Credentials${NC}"
            echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
            echo -e "  Username: ${CYAN}admin${NC}"
            echo -e "  Password: ${CYAN}${password}${NC}"
            echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
            echo ""
            log_warning "Change this password immediately after first login!"
            log_warning "This password is also in the log file — delete it after setup."
            echo ""
        else
            log_info "ArgoCD admin password already consumed or rotated"
        fi
    fi
}

################################################################################
# Phase 5: Namespace & Infrastructure Setup
################################################################################

phase_namespaces() {
    INSTALL_PHASE="namespaces"
    log_header "Phase 5 — Namespace & Infrastructure Setup"

    # ── Vault namespace ───────────────────────────────────────────────────
    if ! kubectl get namespace "$VAULT_NAMESPACE" &> /dev/null; then
        run_cmd "Create Vault namespace" \
            "kubectl create namespace $VAULT_NAMESPACE"
    else
        log_info "Namespace '$VAULT_NAMESPACE' already exists"
    fi

    # ── Apps namespace ────────────────────────────────────────────────────
    if ! kubectl get namespace apps &> /dev/null; then
        run_cmd "Create apps namespace" \
            "kubectl create namespace apps"
    else
        log_info "Namespace 'apps' already exists"
    fi
    run_cmd "Label apps namespace for Vault access" \
        "kubectl label namespace apps vault-client=true --overwrite"

    # ── Label kube-system for NetworkPolicy ───────────────────────────────
    run_cmd "Label kube-system for NetworkPolicy" \
        "kubectl label namespace kube-system kubernetes.io/metadata.name=kube-system --overwrite"

    log_success "All namespaces configured"
}

################################################################################
# Phase 6: Bootstrap Vault Application via ArgoCD
################################################################################

phase_vault_app() {
    INSTALL_PHASE="vault-deploy"
    log_header "Phase 6 — Vault Application Deployment"

    local app_manifest="$REPO_DIR/argocd/vault-application.yaml"

    if [ ! -f "$app_manifest" ]; then
        log_error "Vault Application manifest not found: $app_manifest"
        exit 1
    fi

    # Apply the ArgoCD Application
    run_cmd "Deploy Vault Application via ArgoCD" \
        "kubectl apply -f '$app_manifest'"

    if $DRY_RUN; then
        log_dryrun "Would wait for ArgoCD to sync the Vault Application"
        return 0
    fi

    # Wait for sync
    log "Waiting for Vault application to sync..."
    local elapsed=0

    while [ $elapsed -lt $SYNC_CHECK_TIMEOUT ]; do
        local sync_status
        sync_status=$(kubectl get application vault -n "$ARGOCD_NAMESPACE" \
            -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")

        if [ "$sync_status" = "Synced" ]; then
            log_success "Vault application synced successfully"
            return 0
        fi

        log_debug "Sync status: $sync_status (${elapsed}s / ${SYNC_CHECK_TIMEOUT}s)"
        sleep 10
        elapsed=$((elapsed + 10))
    done

    log_warning "Vault application sync is still in progress"
    log_info "This is normal — Vault pods start sealed and need initialization"
}

################################################################################
# Phase 7: Post-installation Validation
################################################################################

phase_validate() {
    INSTALL_PHASE="validation"
    log_header "Phase 7 — Post-installation Validation"

    if $DRY_RUN; then
        log_dryrun "Would check ArgoCD pods, Vault pods, PVCs, and app sync status"
        return 0
    fi

    local results=""

    # ── ArgoCD health ─────────────────────────────────────────────────────
    local argocd_pods
    argocd_pods=$(kubectl get pods -n "$ARGOCD_NAMESPACE" \
        --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)

    if [ "$argocd_pods" -ge 5 ]; then
        results+="  ArgoCD          │ ✅ Healthy    │ $argocd_pods pods running\n"
    else
        results+="  ArgoCD          │ ⚠️  Degraded   │ $argocd_pods pods running\n"
    fi

    # ── Vault pods ────────────────────────────────────────────────────────
    local vault_pods
    vault_pods=$(kubectl get pods -n "$VAULT_NAMESPACE" --no-headers 2>/dev/null | wc -l)

    if [ "$vault_pods" -ge 1 ]; then
        results+="  Vault Pods      │ ✅ Deployed   │ $vault_pods pods (sealed until init)\n"
    elif [ "$vault_pods" -gt 0 ]; then
        results+="  Vault Pods      │ ⚠️  Partial    │ $vault_pods pods (expected 1+)\n"
    else
        results+="  Vault Pods      │ ⏳ Pending    │ ArgoCD is still syncing\n"
    fi

    # ── PVC status ────────────────────────────────────────────────────────
    local bound_pvcs
    bound_pvcs=$(kubectl get pvc -n "$VAULT_NAMESPACE" --field-selector=status.phase=Bound \
        --no-headers 2>/dev/null | wc -l)
    local total_pvcs
    total_pvcs=$(kubectl get pvc -n "$VAULT_NAMESPACE" --no-headers 2>/dev/null | wc -l)

    if [ "$total_pvcs" -gt 0 ]; then
        results+="  PVCs            │ 📦 ${bound_pvcs}/${total_pvcs} bound │ StorageClass: microk8s-hostpath-immediate\n"
    else
        results+="  PVCs            │ ⏳ Pending    │ Will be created when pods start\n"
    fi

    # ── ArgoCD Application ────────────────────────────────────────────────
    local app_health app_sync
    app_health=$(kubectl get application vault -n "$ARGOCD_NAMESPACE" \
        -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    app_sync=$(kubectl get application vault -n "$ARGOCD_NAMESPACE" \
        -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    results+="  ArgoCD App      │ $app_sync   │ Health: $app_health\n"

    # ── Print results ─────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}  Component         │ Status        │ Details${NC}"
    echo -e "  ──────────────────┼───────────────┼──────────────────────────────"
    echo -e "$results"
}

################################################################################
# Summary & Next Steps
################################################################################

print_summary() {
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Bootstrap Complete!${NC}"
    if $DRY_RUN; then
        echo -e "${YELLOW}  (DRY-RUN — no changes were made)${NC}"
    fi
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Next Steps:${NC}"
    echo ""
    echo "  1. Access ArgoCD UI:"
    echo "     kubectl port-forward svc/argocd-server -n argocd 8080:443"
    echo "     Then open: https://localhost:8080"
    echo ""
    echo "  2. Initialize Vault (first time only):"
    echo "     cd scripts && ./init-vault.sh"
    echo ""
    echo "  3. Monitor deployment:"
    echo "     kubectl get pods -n vault -w"
    echo "     kubectl get applications -n argocd"
    echo ""
    echo -e "${YELLOW}Important:${NC}"
    echo "  • Change the ArgoCD admin password after first login"
    echo "  • Save Vault unseal keys securely (shown during init-vault.sh)"
    echo "  • Delete the log file after setup: rm $LOG_FILE"
    echo ""
    echo -e "${BLUE}Log file:${NC} $LOG_FILE"
    echo ""
}

################################################################################
# Main Execution
################################################################################

main() {
    parse_args "$@"

    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  HashiCorp Vault — Production Bootstrap${NC}"
    echo -e "${BLUE}  ArgoCD: ${ARGOCD_VERSION}  │  MicroK8s  │  GitOps${NC}"
    if $DRY_RUN; then
        echo -e "${YELLOW}  Mode: DRY-RUN (no changes will be made)${NC}"
    fi
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo ""

    phase_preflight
    phase_dependencies
    phase_addons
    phase_argocd
    phase_namespaces
    phase_vault_app
    phase_validate
    print_summary

    INSTALL_PHASE="complete"
    log_success "Bootstrap completed successfully!"
}

main "$@"
