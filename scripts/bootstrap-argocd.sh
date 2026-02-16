#!/bin/bash
set -euo pipefail

################################################################################
# ArgoCD Bootstrap Script
# 
# Purpose: Automated first-time deployment of ArgoCD and initial applications
# Features:
#   - Idempotent (safe to run multiple times)
#   - Detects existing ArgoCD installation
#   - Installs ArgoCD with production-ready configuration
#   - Deploys Vault application via ArgoCD
#   - Comprehensive health checks and error handling
#
# Prerequisites:
#   - kubectl configured and connected to cluster
#   - Cluster admin permissions
#   - Internet connectivity for downloading manifests
################################################################################

# Configuration
ARGOCD_VERSION="v2.14.0"
ARGOCD_NAMESPACE="argocd"
VAULT_NAMESPACE="vault"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/argocd-bootstrap-$(date +%Y%m%d-%H%M%S).log"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

################################################################################
# Logging Functions
################################################################################

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✅ $*${NC}" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ❌ ERROR: $*${NC}" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠️  WARNING: $*${NC}" | tee -a "$LOG_FILE"
}

################################################################################
# Prerequisite Checks
################################################################################

check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl first."
        exit 1
    fi
    
    # Check cluster connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
        exit 1
    fi
    
    # Check cluster admin permissions
    if ! kubectl auth can-i create namespace &> /dev/null; then
        log_error "Insufficient permissions. Cluster admin access required."
        exit 1
    fi
    
    log_success "All prerequisites met"
}

################################################################################
# ArgoCD Detection
################################################################################

is_argocd_installed() {
    if kubectl get namespace "$ARGOCD_NAMESPACE" &> /dev/null; then
        if kubectl get deployment argocd-server -n "$ARGOCD_NAMESPACE" &> /dev/null; then
            return 0  # ArgoCD is installed
        fi
    fi
    return 1  # ArgoCD is not installed
}

check_argocd_health() {
    log "Checking ArgoCD health..."
    
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if kubectl wait --for=condition=available --timeout=10s \
            deployment/argocd-server -n "$ARGOCD_NAMESPACE" &> /dev/null; then
            log_success "ArgoCD server is healthy"
            return 0
        fi
        
        log "Waiting for ArgoCD to become healthy (attempt $attempt/$max_attempts)..."
        sleep 10
        ((attempt++))
    done
    
    log_error "ArgoCD failed to become healthy after $max_attempts attempts"
    return 1
}

################################################################################
# ArgoCD Installation
################################################################################

install_argocd() {
    log "Installing ArgoCD ${ARGOCD_VERSION}..."
    
    # Create namespace
    if ! kubectl get namespace "$ARGOCD_NAMESPACE" &> /dev/null; then
        kubectl create namespace "$ARGOCD_NAMESPACE"
        log_success "Created namespace: $ARGOCD_NAMESPACE"
    else
        log_warning "Namespace $ARGOCD_NAMESPACE already exists"
    fi
    
    # Install ArgoCD
    log "Applying ArgoCD manifests..."
    kubectl apply -n "$ARGOCD_NAMESPACE" \
        -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
    
    log_success "ArgoCD manifests applied"
    
    # Wait for ArgoCD to be ready
    if ! check_argocd_health; then
        log_error "ArgoCD installation failed"
        return 1
    fi
    
    log_success "ArgoCD installed successfully"
}

################################################################################
# ArgoCD Configuration
################################################################################

configure_argocd() {
    log "Configuring ArgoCD..."
    
    # Label the ArgoCD namespace
    kubectl label namespace "$ARGOCD_NAMESPACE" \
        kubernetes.io/metadata.name=argocd \
        --overwrite
    
    # Configure custom health checks for Vault
    log "Configuring custom health checks for Vault..."
    
    kubectl patch configmap argocd-cm -n "$ARGOCD_NAMESPACE" --type merge -p '
{
  "data": {
    "resource.customizations.health.apps_StatefulSet": "hs = {}\nif obj.status ~= nil then\n  if obj.status.readyReplicas ~= nil and obj.status.replicas ~= nil then\n    if obj.status.readyReplicas == obj.status.replicas then\n      hs.status = \"Healthy\"\n      hs.message = \"All replicas ready\"\n      return hs\n    end\n  end\nend\nhs.status = \"Progressing\"\nhs.message = \"Waiting for replicas\"\nreturn hs"
  }
}'
    
    log_success "ArgoCD configuration applied"
}

get_argocd_password() {
    log "Retrieving ArgoCD admin password..."
    
    local password
    password=$(kubectl get secret argocd-initial-admin-secret \
        -n "$ARGOCD_NAMESPACE" \
        -o jsonpath="{.data.password}" 2>/dev/null | base64 -d)
    
    if [ -n "$password" ]; then
        echo ""
        log_success "ArgoCD admin password retrieved"
        echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  ArgoCD Admin Credentials${NC}"
        echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
        echo -e "  Username: ${BLUE}admin${NC}"
        echo -e "  Password: ${BLUE}${password}${NC}"
        echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
        echo ""
        log_warning "IMPORTANT: Change this password immediately after first login!"
        echo ""
    else
        log_warning "Could not retrieve ArgoCD password"
    fi
}

################################################################################
# Namespace Setup
################################################################################

setup_namespaces() {
    log "Setting up required namespaces..."
    
    # Create Vault namespace
    if ! kubectl get namespace "$VAULT_NAMESPACE" &> /dev/null; then
        kubectl create namespace "$VAULT_NAMESPACE"
        log_success "Created namespace: $VAULT_NAMESPACE"
    else
        log_warning "Namespace $VAULT_NAMESPACE already exists"
    fi
    
    # Create apps namespace
    if ! kubectl get namespace apps &> /dev/null; then
        kubectl create namespace apps
        kubectl label namespace apps vault-client=true
        log_success "Created namespace: apps (labeled vault-client=true)"
    else
        log_warning "Namespace apps already exists"
        kubectl label namespace apps vault-client=true --overwrite
    fi
    
    # Label kube-system for NetworkPolicy
    kubectl label namespace kube-system \
        kubernetes.io/metadata.name=kube-system \
        --overwrite
    
    log_success "All namespaces configured"
}

################################################################################
# Application Deployment
################################################################################

deploy_vault_application() {
    log "Deploying Vault application via ArgoCD..."
    
    local app_manifest="${SCRIPT_DIR}/../argocd/vault-application.yaml"
    
    if [ ! -f "$app_manifest" ]; then
        log_error "Vault application manifest not found: $app_manifest"
        return 1
    fi
    
    # Apply the Vault Application
    kubectl apply -f "$app_manifest"
    
    log_success "Vault application deployed"
    
    # Wait for application to sync
    log "Waiting for Vault application to sync..."
    local max_attempts=12
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        local sync_status
        sync_status=$(kubectl get application vault -n "$ARGOCD_NAMESPACE" \
            -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
        
        if [ "$sync_status" = "Synced" ]; then
            log_success "Vault application synced successfully"
            return 0
        fi
        
        log "Sync status: $sync_status (attempt $attempt/$max_attempts)"
        sleep 10
        ((attempt++))
    done
    
    log_warning "Vault application sync is taking longer than expected"
    log_warning "This is normal for first-time Vault deployment (pods start sealed)"
}

################################################################################
# Health Checks
################################################################################

verify_deployment() {
    log "Verifying deployment..."
    
    # Check ArgoCD components
    log "Checking ArgoCD components..."
    local argocd_pods
    argocd_pods=$(kubectl get pods -n "$ARGOCD_NAMESPACE" \
        --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    
    if [ "$argocd_pods" -ge 5 ]; then
        log_success "ArgoCD components running ($argocd_pods pods)"
    else
        log_warning "Some ArgoCD pods may not be ready yet ($argocd_pods running)"
    fi
    
    # Check Vault pods
    log "Checking Vault pods..."
    local vault_pods
    vault_pods=$(kubectl get pods -n "$VAULT_NAMESPACE" \
        --no-headers 2>/dev/null | wc -l)
    
    if [ "$vault_pods" -ge 3 ]; then
        log_success "Vault pods deployed ($vault_pods pods)"
        log_warning "Note: Vault pods will be sealed until initialized"
    else
        log_warning "Vault pods not yet deployed (this may take a few minutes)"
    fi
    
    # Check ArgoCD Application
    log "Checking ArgoCD Application status..."
    if kubectl get application vault -n "$ARGOCD_NAMESPACE" &> /dev/null; then
        local health_status
        health_status=$(kubectl get application vault -n "$ARGOCD_NAMESPACE" \
            -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
        
        log "Vault application health: $health_status"
    fi
}

################################################################################
# Access Instructions
################################################################################

print_access_instructions() {
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Bootstrap Complete!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BLUE}Next Steps:${NC}"
    echo ""
    echo "1. Access ArgoCD UI:"
    echo "   kubectl port-forward svc/argocd-server -n argocd 8080:443"
    echo "   Then open: https://localhost:8080"
    echo ""
    echo "2. Initialize Vault:"
    echo "   cd scripts"
    echo "   ./init-vault.sh"
    echo ""
    echo "3. Monitor Vault deployment:"
    echo "   kubectl get pods -n vault -w"
    echo ""
    echo "4. View ArgoCD applications:"
    echo "   kubectl get applications -n argocd"
    echo ""
    echo -e "${YELLOW}Important:${NC}"
    echo "  - Change ArgoCD admin password after first login"
    echo "  - Save Vault unseal keys securely when running init-vault.sh"
    echo "  - Review DEPLOYMENT.md for detailed setup instructions"
    echo ""
    echo -e "Log file: ${BLUE}${LOG_FILE}${NC}"
    echo ""
}

################################################################################
# Main Execution
################################################################################

main() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  ArgoCD Bootstrap Script${NC}"
    echo -e "${BLUE}  Version: ${ARGOCD_VERSION}${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Run prerequisite checks
    check_prerequisites
    
    # Check if ArgoCD is already installed
    if is_argocd_installed; then
        log_warning "ArgoCD is already installed in namespace: $ARGOCD_NAMESPACE"
        
        # Verify it's healthy
        if check_argocd_health; then
            log_success "Existing ArgoCD installation is healthy"
        else
            log_error "Existing ArgoCD installation is unhealthy"
            log "You may need to troubleshoot the existing installation"
            exit 1
        fi
    else
        log "ArgoCD not detected. Proceeding with installation..."
        
        # Install ArgoCD
        if ! install_argocd; then
            log_error "ArgoCD installation failed"
            exit 1
        fi
        
        # Configure ArgoCD
        configure_argocd
        
        # Display admin password
        get_argocd_password
    fi
    
    # Setup namespaces
    setup_namespaces
    
    # Deploy Vault application
    deploy_vault_application
    
    # Verify deployment
    verify_deployment
    
    # Print access instructions
    print_access_instructions
    
    log_success "Bootstrap completed successfully!"
}

# Execute main function
main "$@"
