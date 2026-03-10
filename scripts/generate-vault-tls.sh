#!/bin/bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Generate self-signed TLS certificate for vault.local
# Creates a local CA, signs a cert with SANs, and loads into K8s as a TLS secret
#
# Usage: bash scripts/generate-vault-tls.sh [--namespace vault] [--domain vault.local]
# ──────────────────────────────────────────────────────────────────────────────

DOMAIN="${2:-vault.local}"
NAMESPACE="${1:-vault}"
SECRET_NAME="vault-tls"
CERT_DIR="/tmp/vault-tls-$(date +%Y%m%d)"
CA_DAYS=3650   # CA valid for 10 years
CERT_DAYS=365  # Server cert valid for 1 year
KEY_SIZE=4096

echo "━━━ Vault TLS Certificate Generator ━━━"
echo "  Domain:    ${DOMAIN}"
echo "  Namespace: ${NAMESPACE}"
echo "  Secret:    ${SECRET_NAME}"
echo "  Output:    ${CERT_DIR}/"
echo ""

mkdir -p "$CERT_DIR"

# ── Step 1: Generate CA ──────────────────────────────────────────────────────
echo "🔐 Generating Certificate Authority..."
openssl genrsa -out "$CERT_DIR/ca.key" $KEY_SIZE 2>/dev/null
openssl req -x509 -new -nodes \
  -key "$CERT_DIR/ca.key" \
  -sha256 \
  -days $CA_DAYS \
  -out "$CERT_DIR/ca.crt" \
  -subj "/CN=Vault Local CA/O=Homelab"
echo "   ✅ CA certificate: ${CERT_DIR}/ca.crt"

# ── Step 2: Generate server key + CSR ────────────────────────────────────────
echo "🔑 Generating server key and CSR..."
openssl genrsa -out "$CERT_DIR/tls.key" $KEY_SIZE 2>/dev/null
openssl req -new \
  -key "$CERT_DIR/tls.key" \
  -out "$CERT_DIR/tls.csr" \
  -subj "/CN=${DOMAIN}/O=Homelab"

# ── Step 3: Create SAN config and sign ───────────────────────────────────────
echo "📜 Signing certificate with SANs..."
cat > "$CERT_DIR/san.cnf" <<EOF
[req]
distinguished_name = req_dn
[req_dn]
[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${DOMAIN}
DNS.2 = vault
DNS.3 = vault.vault.svc
DNS.4 = vault.vault.svc.cluster.local
DNS.5 = vault-internal
DNS.6 = vault-internal.vault.svc
DNS.7 = vault-internal.vault.svc.cluster.local
EOF

openssl x509 -req \
  -in "$CERT_DIR/tls.csr" \
  -CA "$CERT_DIR/ca.crt" \
  -CAkey "$CERT_DIR/ca.key" \
  -CAcreateserial \
  -out "$CERT_DIR/tls.crt" \
  -days $CERT_DAYS \
  -sha256 \
  -extfile "$CERT_DIR/san.cnf" \
  -extensions v3_req \
  2>/dev/null
echo "   ✅ Server certificate: ${CERT_DIR}/tls.crt"

# ── Step 4: Verify the certificate ──────────────────────────────────────────
echo ""
echo "📋 Certificate details:"
openssl x509 -in "$CERT_DIR/tls.crt" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null | sed 's/^/   /'

# ── Step 5: Create Kubernetes TLS secret ─────────────────────────────────────
echo ""
echo "☸️  Creating Kubernetes TLS secret..."
kubectl create namespace "$NAMESPACE" 2>/dev/null || true
kubectl -n "$NAMESPACE" delete secret "$SECRET_NAME" 2>/dev/null || true
kubectl -n "$NAMESPACE" create secret tls "$SECRET_NAME" \
  --cert="$CERT_DIR/tls.crt" \
  --key="$CERT_DIR/tls.key"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ TLS secret '${SECRET_NAME}' created in namespace '${NAMESPACE}'"
echo ""
echo "📌 Next steps:"
echo "   1. Import the CA cert into your browser/OS trust store:"
echo "      ${CERT_DIR}/ca.crt"
echo ""
echo "   2. On Ubuntu/Debian:"
echo "      sudo cp ${CERT_DIR}/ca.crt /usr/local/share/ca-certificates/vault-local-ca.crt"
echo "      sudo update-ca-certificates"
echo ""
echo "   3. On macOS:"
echo "      sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ${CERT_DIR}/ca.crt"
echo ""
echo "   4. On Windows (PowerShell as Admin):"
echo "      Import-Certificate -FilePath '${CERT_DIR}/ca.crt' -CertStoreLocation Cert:\\LocalMachine\\Root"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
