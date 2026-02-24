#!/bin/bash
set -euo pipefail

################################################################################
# Vault StatefulSet StorageClass Migration / PV Rebind Script
#
# Usage:
#   ./fix-storageclass.sh                  # Default: preserve data (safe)
#   ./fix-storageclass.sh --preserve-data  # Explicit: preserve data (safe)
#   ./fix-storageclass.sh --delete-data    # Destructive: wipe all Vault data
#
# Modes:
#   --preserve-data (default)
#     - Uninstalls Vault Helm release (pods + PVCs deleted)
#     - PVs are RETAINED (reclaimPolicy: Retain on StorageClass)
#     - Clears claimRef on Released PVs so they can rebind to new PVCs
#     - Reinstalls Vault — new PVCs bind to existing PVs with preserved data
#     - Use this for StorageClass migrations or pod recreation
#
#   --delete-data
#     - Uninstalls Vault Helm release
#     - Explicitly deletes all PVs (destroys data permanently)
#     - Reinstalls Vault with fresh empty volumes
#     - Use ONLY for non-production or after a confirmed backup restore
################################################################################

NAMESPACE="vault"
RELEASE_NAME="vault"
MODE="preserve"

# ── Parse arguments ────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --preserve-data) MODE="preserve" ;;
    --delete-data)   MODE="delete"   ;;
    *)
      echo "Unknown argument: $arg"
      echo "Usage: $0 [--preserve-data|--delete-data]"
      exit 1
      ;;
  esac
done

# ── Banner ─────────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════"
echo "  Vault StatefulSet Migration Script"
echo "  Mode: $([ "$MODE" = "preserve" ] && echo "PRESERVE DATA (safe)" || echo "DELETE DATA (destructive)")"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ── Safety confirmation ────────────────────────────────────────────────────────
if [ "$MODE" = "delete" ]; then
  echo "⚠️  WARNING: --delete-data will PERMANENTLY DESTROY all Vault data!"
  echo "   This cannot be undone. Ensure you have a verified backup."
  echo ""
  read -p "Type 'DELETE ALL DATA' to confirm: " confirm
  if [ "$confirm" != "DELETE ALL DATA" ]; then
    echo "Aborted."
    exit 0
  fi
else
  echo "ℹ️  Running in PRESERVE DATA mode."
  echo "   PVs will be retained and rebound to new PVCs."
  echo ""
  read -p "Continue? (type 'yes' to confirm): " confirm
  if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 0
  fi
fi

# ── Step 1: Capture existing PV names before uninstall ────────────────────────
echo ""
echo "Step 1: Capturing existing PV names..."
EXISTING_PVS=$(kubectl get pv \
  --field-selector=spec.storageClassName=microk8s-hostpath-immediate \
  --no-headers 2>/dev/null | grep "vault" | awk '{print $1}' || true)

if [ -n "$EXISTING_PVS" ]; then
  echo "  Found PVs:"
  echo "$EXISTING_PVS" | sed 's/^/    /'
else
  echo "  No existing Vault PVs found."
fi

# ── Step 2: Uninstall Helm release ────────────────────────────────────────────
echo ""
echo "Step 2: Uninstalling Vault Helm release..."
helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || echo "  (release not found, continuing)"

echo ""
echo "Step 3: Waiting for pods to terminate..."
kubectl wait --for=delete pod -l app.kubernetes.io/name=vault \
  -n "$NAMESPACE" --timeout=120s 2>/dev/null || true

# ── Step 4: Delete PVCs (PVs are retained by StorageClass policy) ─────────────
echo ""
echo "Step 4: Deleting PVCs..."
kubectl delete pvc -l app.kubernetes.io/name=vault -n "$NAMESPACE" 2>/dev/null || true
sleep 5

# ── Step 5: Handle PVs based on mode ──────────────────────────────────────────
echo ""
if [ "$MODE" = "delete" ]; then
  echo "Step 5: Deleting PVs (--delete-data mode)..."
  if [ -n "$EXISTING_PVS" ]; then
    echo "$EXISTING_PVS" | xargs -r kubectl delete pv
    echo "  ✅ PVs deleted"
  else
    echo "  No PVs to delete"
  fi
else
  echo "Step 5: Clearing claimRef on Released PVs (--preserve-data mode)..."
  echo "  Waiting for PVs to enter Released state..."
  sleep 5

  RELEASED_COUNT=0
  if [ -n "$EXISTING_PVS" ]; then
    while IFS= read -r PV_NAME; do
      PV_PHASE=$(kubectl get pv "$PV_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

      if [ "$PV_PHASE" = "Released" ]; then
        echo "  Clearing claimRef on PV: $PV_NAME"
        kubectl patch pv "$PV_NAME" \
          --type=json \
          -p='[{"op": "remove", "path": "/spec/claimRef"}]'
        RELEASED_COUNT=$((RELEASED_COUNT + 1))
        echo "  ✅ $PV_NAME is now Available"

      elif [ "$PV_PHASE" = "Available" ]; then
        echo "  ✅ $PV_NAME is already Available (no action needed)"

      elif [ "$PV_PHASE" = "NotFound" ]; then
        echo "  ⚠️  $PV_NAME not found (may have been deleted)"

      else
        echo "  ⚠️  $PV_NAME is in phase '$PV_PHASE' — manual inspection may be needed"
      fi
    done <<< "$EXISTING_PVS"

    echo ""
    echo "  $RELEASED_COUNT PV(s) cleared and set to Available"
  else
    echo "  No existing PVs to process — fresh volumes will be provisioned"
  fi
fi

# ── Step 6: Reinstall Vault ────────────────────────────────────────────────────
echo ""
echo "Step 6: Reinstalling Vault..."
helm upgrade --install "$RELEASE_NAME" hashicorp/vault \
  --version 0.32.0 \
  --namespace "$NAMESPACE" \
  --create-namespace \
  -f helm/vault/values.yaml \
  --timeout 10m

echo ""
echo "Step 7: Waiting for pods to be created..."
sleep 15
kubectl get pods -n "$NAMESPACE"

echo ""
echo "Step 8: Verifying PVC binding..."
sleep 5
kubectl get pvc -n "$NAMESPACE" -o custom-columns=\
NAME:.metadata.name,\
STATUS:.status.phase,\
VOLUME:.spec.volumeName,\
STORAGECLASS:.spec.storageClassName

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
if [ "$MODE" = "preserve" ]; then
  echo "  ✅ Vault reinstalled with data preserved"
  echo ""
  echo "  Next steps:"
  echo "  1. If Vault is already initialized: unseal vault-0"
  echo "     kubectl exec -n vault vault-0 -- vault operator unseal <key>"
  echo "  2. If this is a fresh deployment: initialize Vault"
  echo "     cd scripts && ./init-vault.sh"
else
  echo "  ✅ Vault reinstalled with fresh empty volumes"
  echo ""
  echo "  Next steps:"
  echo "  1. Initialize Vault: cd scripts && ./init-vault.sh"
  echo "  2. Save unseal keys securely"
  echo "  3. Configure Kubernetes auth and policies"
fi
echo "═══════════════════════════════════════════════════════════"
