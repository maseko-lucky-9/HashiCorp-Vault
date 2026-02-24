#!/bin/bash
set -euo pipefail

# Vault Backup Script
# Takes a Raft snapshot and uploads to S3-compatible storage
# Designed to run as a Kubernetes CronJob or manually

VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_POD="${VAULT_POD:-vault-0}"
BACKUP_DIR="${BACKUP_DIR:-/tmp}"
S3_BUCKET="${S3_BUCKET:-}"  # e.g., s3://my-bucket/vault-backups
RETENTION_DAYS="${RETENTION_DAYS:-30}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SNAPSHOT_FILE="vault-raft-backup-${TIMESTAMP}.snap"

echo "=== Vault Backup Script ==="
echo "Timestamp: $TIMESTAMP"
echo "Namespace: $VAULT_NAMESPACE"
echo "Pod: $VAULT_POD"
echo ""

# Check if Vault is unsealed
if ! kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -c vault -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault status" 2>/dev/null | grep -q "Sealed.*false"; then
  echo "❌ ERROR: Vault is sealed. Cannot take snapshot."
  exit 1
fi

# Take Raft snapshot
echo "Taking Raft snapshot..."
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -c vault -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault operator raft snapshot save /tmp/${SNAPSHOT_FILE}"

# Copy snapshot from pod
echo "Copying snapshot from pod..."
kubectl cp "${VAULT_NAMESPACE}/${VAULT_POD}:/tmp/${SNAPSHOT_FILE}" "${BACKUP_DIR}/${SNAPSHOT_FILE}"

# Verify snapshot file exists
if [ ! -f "${BACKUP_DIR}/${SNAPSHOT_FILE}" ]; then
  echo "❌ ERROR: Snapshot file not found at ${BACKUP_DIR}/${SNAPSHOT_FILE}"
  exit 1
fi

SNAPSHOT_SIZE=$(du -h "${BACKUP_DIR}/${SNAPSHOT_FILE}" | cut -f1)
echo "✅ Snapshot created: ${SNAPSHOT_FILE} (${SNAPSHOT_SIZE})"

# Upload to S3 if bucket is configured
if [ -n "$S3_BUCKET" ]; then
  echo "Uploading to S3: ${S3_BUCKET}/${SNAPSHOT_FILE}"
  
  # Use aws CLI or mc (MinIO client) depending on what's available
  if command -v aws &> /dev/null; then
    aws s3 cp "${BACKUP_DIR}/${SNAPSHOT_FILE}" "${S3_BUCKET}/${SNAPSHOT_FILE}"
  elif command -v mc &> /dev/null; then
    mc cp "${BACKUP_DIR}/${SNAPSHOT_FILE}" "${S3_BUCKET}/${SNAPSHOT_FILE}"
  else
    echo "⚠️  WARNING: Neither 'aws' nor 'mc' CLI found. Skipping S3 upload."
  fi
  
  # Clean up old backups
  if command -v aws &> /dev/null; then
    echo "Cleaning up backups older than ${RETENTION_DAYS} days..."
    CUTOFF_DATE=$(date -d "${RETENTION_DAYS} days ago" +%Y%m%d)
    aws s3 ls "${S3_BUCKET}/" | while read -r line; do
      BACKUP_DATE=$(echo "$line" | grep -oP 'vault-raft-backup-\K\d{8}')
      if [ -n "$BACKUP_DATE" ] && [ "$BACKUP_DATE" -lt "$CUTOFF_DATE" ]; then
        BACKUP_NAME=$(echo "$line" | awk '{print $4}')
        echo "Deleting old backup: $BACKUP_NAME"
        aws s3 rm "${S3_BUCKET}/${BACKUP_NAME}"
      fi
    done
  fi
fi

# Clean up local snapshot
rm -f "${BACKUP_DIR}/${SNAPSHOT_FILE}"
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- rm -f "/tmp/${SNAPSHOT_FILE}"

echo ""
echo "✅ Backup complete!"
echo "Snapshot: ${SNAPSHOT_FILE}"
if [ -n "$S3_BUCKET" ]; then
  echo "Location: ${S3_BUCKET}/${SNAPSHOT_FILE}"
fi
