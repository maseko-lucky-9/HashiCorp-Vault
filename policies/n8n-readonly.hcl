# ─────────────────────────────────────────────────────────
# N8N Application Policy — Least-Privilege Read-Only
# Bound to Kubernetes auth role: n8n-live
# ─────────────────────────────────────────────────────────

# Read N8N application secrets (all environments via path prefix)
path "secret/data/n8n/+/*" {
  capabilities = ["read"]
}

# List secret metadata (for ESO discovery and debugging)
path "secret/metadata/n8n/+/*" {
  capabilities = ["read", "list"]
}

# Optional: Allow N8N to request dynamic database credentials
# Uncomment when the database secrets engine is configured
# path "database/creds/n8n-readonly" {
#   capabilities = ["read"]
# }

# Token self-introspection (required for health checks)
path "auth/token/lookup-self" {
  capabilities = ["read"]
}

# Token self-renewal (for long-running ESO syncs)
path "auth/token/renew-self" {
  capabilities = ["update"]
}
