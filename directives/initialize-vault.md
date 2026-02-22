---
name: Initialize Vault
description: First-time initialization of a freshly deployed Vault cluster
version: 1.0.0
last_updated: 2026-02-22
---

# Initialize Vault

## Goal

Initialize a freshly deployed Vault cluster — generate unseal keys, unseal all pods, join Raft peers, enable auth/engines, and apply policies.

## Inputs

**Required:**

- `vault_namespace` (string, default: "vault"): Kubernetes namespace where Vault is deployed
- `vault_pod` (string, default: "vault-0"): Primary pod to initialize

**Optional:**

- `key_shares` (int, default: 5): Number of Shamir key shares
- `key_threshold` (int, default: 3): Minimum keys required to unseal
- `enable_kv` (bool, default: true): Enable KV v2 at `secret/`
- `enable_k8s_auth` (bool, default: true): Enable Kubernetes auth method

## Tools / Scripts

- `scripts/init-vault.sh` — Runs initialization end-to-end (interactive only)
- `execution/vault_status.py` — Pre-flight check: verifies pods exist and Vault is not yet initialized

## Outputs

- **Unseal Keys**: 5 base64-encoded keys printed to stdout (SAVE IMMEDIATELY)
- **Root Token**: Single root token printed to stdout (revoke after setup)
- **Configured Cluster**: K8s auth, KV v2, file+syslog audit, all policies applied

## Edge Cases & Error Handling

1. **Vault already initialized**: Script exits cleanly with a warning — no destructive action
2. **Pod not running**: Pre-check fails if `vault-0` is not in Running state. Fix: check `kubectl get pods -n vault`
3. **Raft join fails**: Most common cause is protocol mismatch (http vs https). Ensure `init-vault.sh` join URL matches `values.yaml` `retry_join` protocol
4. **Syslog audit enable fails**: Non-fatal on MicroK8s (syslog may not be available). Script continues.

## Learnings

- **2026-02-22**: Fixed HTTPS→HTTP mismatch in `init-vault.sh` raft join command. Must match `values.yaml` `tls_disable` setting.
