---
name: Unseal Vault
description: Unseal Vault pod after restart, reboot, or upgrade
version: 1.0.0
last_updated: 2026-02-22
---

# Unseal Vault

## Goal

Unseal vault-0 after a node reboot, pod restart, or rolling upgrade. Vault auto-seals on restart by design — 3 of 5 unseal keys are required.

## Inputs

**Required:**

- `unseal_keys` (list[string]): At least 3 of 5 base64-encoded unseal keys
- `vault_namespace` (string, default: "vault"): Kubernetes namespace

**Optional:**

- `target_pods` (list[string], default: ["vault-0"]): Pod(s) to unseal

## Tools / Scripts

- `execution/vault_status.py` — Check seal status of all pods before/after unsealing

## Outputs

- **Unsealed Instance**: vault-0 reporting `Sealed: false`
- **Vault Healthy**: Initialized and unsealed, serving requests

## Edge Cases & Error Handling

1. **Wrong unseal keys**: Vault rejects invalid keys. After too many failures, Vault may require re-init (data loss).
2. **Auto-unseal migration**: If migrating to Transit/KMS auto-unseal, run `vault operator unseal -migrate` with Shamir keys.

## Learnings

- **2026-02-24**: Simplified for standalone mode — only vault-0 needs unsealing.
