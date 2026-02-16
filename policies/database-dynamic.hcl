# Dynamic Database Credentials Policy
# Allows applications to request short-lived database credentials

# Read dynamic database credentials
path "database/creds/readonly" {
  capabilities = ["read"]
}

path "database/creds/readwrite" {
  capabilities = ["read"]
}

# List available roles
path "database/roles" {
  capabilities = ["list"]
}
