#!/bin/bash
set -euo pipefail

# Vault Initialization Script
# Run this ONCE after the first deployment to initialize and configure Vault

VAULT_NAMESPACE="vault"
VAULT_POD="vault-0"

echo "=== Vault Initialization Script ==="
echo ""

# Check if Vault is already initialized
if kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- vault status 2>/dev/null | grep -q "Initialized.*true"; then
  echo "⚠️  Vault is already initialized. Exiting."
  exit 0
fi

echo "Initializing Vault with 5 key shares and threshold of 3..."
INIT_OUTPUT=$(kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- vault operator init \
  -key-shares=5 \
  -key-threshold=3 \
  -format=json)

echo "$INIT_OUTPUT" | jq .

# Extract keys and root token
UNSEAL_KEYS=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[]')
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')

echo ""
echo "=== CRITICAL: Save these keys securely! They are shown ONLY ONCE ==="
echo ""
echo "Unseal Keys:"
echo "$UNSEAL_KEYS"
echo ""
echo "Root Token: $ROOT_TOKEN"
echo ""
echo "=== Store these in a password manager or encrypted offline storage ==="
echo ""

# Unseal vault-0
echo "Unsealing vault-0..."
KEYS_ARRAY=($UNSEAL_KEYS)
for i in 0 1 2; do
  kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- vault operator unseal "${KEYS_ARRAY[$i]}"
done

# Join and unseal vault-1 and vault-2
for POD in vault-1 vault-2; do
  echo "Joining $POD to Raft cluster..."
  kubectl exec -n "$VAULT_NAMESPACE" "$POD" -- vault operator raft join https://vault-0.vault-internal:8200
  
  echo "Unsealing $POD..."
  for i in 0 1 2; do
    kubectl exec -n "$VAULT_NAMESPACE" "$POD" -- vault operator unseal "${KEYS_ARRAY[$i]}"
  done
done

# Login with root token
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- vault login "$ROOT_TOKEN"

echo ""
echo "=== Configuring Vault ==="

# Enable Kubernetes auth
echo "Enabling Kubernetes auth method..."
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- vault auth enable kubernetes

echo "Configuring Kubernetes auth..."
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

# Enable KV v2 secrets engine
echo "Enabling KV v2 secrets engine at path 'secret'..."
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- vault secrets enable -path=secret kv-v2

# Enable audit logging
echo "Enabling file audit device..."
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- vault audit enable file file_path=/vault/audit/vault-audit.log

echo "Enabling syslog audit device..."
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- vault audit enable -path=syslog syslog tag="vault" facility="LOCAL0"

# Apply policies
echo "Applying Vault policies..."
for POLICY in app-readonly admin database-dynamic; do
  kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -i -- vault policy write "$POLICY" - < "../policies/${POLICY}.hcl"
done

echo ""
echo "✅ Vault initialization complete!"
echo ""
echo "Next steps:"
echo "1. IMMEDIATELY save the unseal keys and root token to secure offline storage"
echo "2. Create Kubernetes roles: vault write auth/kubernetes/role/app-role ..."
echo "3. Revoke the root token: vault token revoke $ROOT_TOKEN"
echo "4. Test secret injection with a sample application"
