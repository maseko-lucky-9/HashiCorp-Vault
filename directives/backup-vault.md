---
name: Backup Vault
description: Take and store file-storage backups for disaster recovery
version: 1.0.0
last_updated: 2026-02-22
---

# Backup Vault

## Goal

Create a tar archive of the Vault file storage backend (`/vault/data`) for disaster recovery.

## Inputs

**Required:**

- `vault_namespace` (string, default: "vault"): Kubernetes namespace
- `vault_pod` (string, default: "vault-0"): Pod to backup (standalone mode)

**Optional:**

- `s3_bucket` (string): S3 URI for off-site upload (e.g. `s3://my-vault-backups`)
- `retention_days` (int, default: 7): Days to retain local backups before pruning

## Tools / Scripts

- `scripts/backup-vault.sh` — Creates tar archive of file storage data and uploads to S3
- `manifests/backup-cronjob.yaml` — Automated daily CronJob (02:00 UTC)
- `execution/vault_status.py` — Pre-flight: verify Vault is unsealed before backup

## Outputs

- **Backup file**: `vault-data-backup-YYYYMMDD-HHMMSS.tar.gz` at `/var/backups/vault/`
- **S3 copy** (if configured): Same file uploaded to `${S3_BUCKET}/`

## Edge Cases & Error Handling

1. **Vault is sealed**: Backup fails. Run unseal procedure first.
2. **S3 credentials missing**: Backup stored locally only. Warning printed.
3. **Disk full on host**: `hostPath` at `/var/backups/vault` fills up. Pruning keeps only last 7 days.
4. **Concurrent writes**: File-storage tar is not guaranteed consistent; for crash-consistent backup, seal Vault briefly.

## Learnings

- **2026-02-22**: Changed CronJob volume from `emptyDir` to `hostPath` (`/var/backups/vault`). Previous `emptyDir` caused all backups to be lost when the Job pod terminated.
- **2026-02-24**: Migrated from Raft snapshots to file-storage tar backups after HA → standalone transition.
