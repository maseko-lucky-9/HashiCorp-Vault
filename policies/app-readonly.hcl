# Application Read-Only Policy
# Grants read access to secrets under the app's namespace path

path "secret/data/apps/{{identity.entity.aliases.auth_kubernetes_*.metadata.service_account_namespace}}/*" {
  capabilities = ["read"]
}

path "secret/metadata/apps/*" {
  capabilities = ["read", "list"]
}

# Deny everything else (Vault is deny-by-default, but explicit is better)
