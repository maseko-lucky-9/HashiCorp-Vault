---
name: Backup Vault
description: Take and store Raft snapshots for disaster recovery
version: 1.0.0
last_updated: 2026-02-22
---

# Backup Vault

## Goal

Create a point-in-time Raft snapshot of the Vault cluster and store it for disaster recovery.

## Inputs

**Required:**

- `vault_namespace` (string, default: "vault"): Kubernetes namespace
- `vault_pod` (string, default: "vault-0"): Pod to snapshot (must be leader or standby)

**Optional:**

- `s3_bucket` (string): S3 URI for off-site upload (e.g. `s3://my-vault-backups`)
- `retention_days` (int, default: 7): Days to retain local backups before pruning

## Tools / Scripts

- `scripts/backup-vault.sh` — Manual one-shot Raft snapshot
- `manifests/backup-cronjob.yaml` — Automated daily CronJob (02:00 UTC)
- `execution/vault_status.py` — Pre-flight: verify Vault is unsealed before snapshot

## Outputs

- **Snapshot file**: `vault-raft-backup-YYYYMMDD-HHMMSS.snap` at `/var/backups/vault/`
- **S3 copy** (if configured): Same file uploaded to `${S3_BUCKET}/`

## Edge Cases & Error Handling

1. **Vault is sealed**: Snapshot fails. Run unseal procedure first.
2. **S3 credentials missing**: Backup stored locally only. Warning printed.
3. **Disk full on host**: `hostPath` at `/var/backups/vault` fills up. Pruning keeps only last 7 days.
4. **Pod not leader**: `vault operator raft snapshot save` works on any peer, not just leader.

## Learnings

- **2026-02-22**: Changed CronJob volume from `emptyDir` to `hostPath` (`/var/backups/vault`). Previous `emptyDir` caused all backups to be lost when the Job pod terminated.
