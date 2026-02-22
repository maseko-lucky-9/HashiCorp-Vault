---
name: Unseal Vault
description: Unseal Vault pods after restart, reboot, or upgrade
version: 1.0.0
last_updated: 2026-02-22
---

# Unseal Vault

## Goal

Unseal all Vault pods after a node reboot, pod restart, or rolling upgrade. Vault auto-seals on restart by design — 3 of 5 unseal keys are required per pod.

## Inputs

**Required:**

- `unseal_keys` (list[string]): At least 3 of 5 base64-encoded unseal keys
- `vault_namespace` (string, default: "vault"): Kubernetes namespace

**Optional:**

- `target_pods` (list[string], default: ["vault-0", "vault-1", "vault-2"]): Specific pods to unseal

## Tools / Scripts

- `execution/vault_status.py` — Check seal status of all pods before/after unsealing

## Outputs

- **Unsealed Cluster**: All pods reporting `Sealed: false`
- **Raft Quorum**: Leader elected, all peers voting

## Edge Cases & Error Handling

1. **Wrong unseal keys**: Vault rejects invalid keys. After too many failures, Vault may require re-init (data loss).
2. **Only 1-2 pods sealed**: Safe to unseal individually — other pods maintain quorum.
3. **All 3 pods sealed simultaneously**: Vault is unavailable. Unseal vault-0 first (leader will re-elect).
4. **Auto-unseal migration**: If migrating to Transit/KMS auto-unseal, run `vault operator unseal -migrate` with Shamir keys.

## Learnings

_No learnings yet._
