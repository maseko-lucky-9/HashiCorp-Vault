#!/bin/bash
set -euo pipefail

################################################################################
# Vault StatefulSet StorageClass Migration Script
# 
# Purpose: Safely delete and recreate Vault StatefulSet with new StorageClass
# 
# WARNING: This script will DELETE all Vault data!
# Only use this if:
#   1. Vault is not yet initialized, OR
#   2. You have a recent backup and can restore from it
#
# For production systems with data, see the manual migration steps in
# STATEFULSET-STORAGECLASS-FIX.md
################################################################################

NAMESPACE="vault"
RELEASE_NAME="vault"

echo "═══════════════════════════════════════════════════════════"
echo "  Vault StatefulSet StorageClass Migration"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "⚠️  WARNING: This will DELETE all Vault pods and PVCs!"
echo ""
read -p "Are you sure you want to continue? (type 'yes' to confirm): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "Step 1: Uninstalling Vault Helm release..."
helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" || true

echo ""
echo "Step 2: Waiting for pods to terminate..."
kubectl wait --for=delete pod -l app.kubernetes.io/name=vault -n "$NAMESPACE" --timeout=120s || true

echo ""
echo "Step 3: Deleting PersistentVolumeClaims..."
kubectl delete pvc -l app.kubernetes.io/name=vault -n "$NAMESPACE" || true

echo ""
echo "Step 4: Waiting for PVCs to be deleted..."
sleep 5

echo ""
echo "Step 5: Reinstalling Vault with new StorageClass..."
helm upgrade --install "$RELEASE_NAME" hashicorp/vault \
  --version 0.32.0 \
  --namespace "$NAMESPACE" \
  --create-namespace \
  -f helm/vault/values.yaml \
  --wait \
  --timeout 10m

echo ""
echo "✅ Vault reinstalled successfully!"
echo ""
echo "Next steps:"
echo "1. Initialize Vault: cd scripts && ./init-vault.sh"
echo "2. Save unseal keys securely"
echo "3. Configure Kubernetes auth and policies"
echo ""
echo "Verify new PVCs are using microk8s-hostpath:"
kubectl get pvc -n "$NAMESPACE" -o custom-columns=NAME:.metadata.name,STORAGECLASS:.spec.storageClassName
