# Admin Policy
# Full administrative access except for sealing the cluster

# Full access to secrets
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Manage policies
path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Manage auth methods
path "sys/auth/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Manage secrets engines
path "sys/mounts/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Read system health
path "sys/health" {
  capabilities = ["read"]
}

# Read audit devices
path "sys/audit" {
  capabilities = ["read", "list"]
}

# Manage audit devices
path "sys/audit/*" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}

# Prevent accidental sealing
path "sys/seal" {
  capabilities = ["deny"]
}
