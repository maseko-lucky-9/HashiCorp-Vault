#!/bin/bash
set -euo pipefail

# Vault Backup Script
# Creates a tar archive of the file storage backend (/vault/data)
# Designed to run manually or as a Kubernetes CronJob

VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_POD="${VAULT_POD:-vault-0}"
BACKUP_DIR="${BACKUP_DIR:-/tmp}"
S3_BUCKET="${S3_BUCKET:-}"  # e.g., s3://my-bucket/vault-backups
RETENTION_DAYS="${RETENTION_DAYS:-30}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="vault-data-backup-${TIMESTAMP}.tar.gz"

echo "=== Vault Backup Script ==="
echo "Timestamp: $TIMESTAMP"
echo "Namespace: $VAULT_NAMESPACE"
echo "Pod: $VAULT_POD"
echo ""

# Check if Vault is unsealed
if ! kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -c vault -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault status" 2>/dev/null | grep -q "Sealed.*false"; then
  echo "❌ ERROR: Vault is sealed. Cannot take backup."
  exit 1
fi

# Create tar archive of file storage data
echo "Creating file-storage backup..."
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -c vault -- \
  tar czf "/tmp/${BACKUP_FILE}" -C /vault/data .

# Copy backup from pod
echo "Copying backup from pod..."
kubectl cp "${VAULT_NAMESPACE}/${VAULT_POD}:/tmp/${BACKUP_FILE}" "${BACKUP_DIR}/${BACKUP_FILE}"

# Clean up temp file in pod
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -c vault -- rm -f "/tmp/${BACKUP_FILE}"

# Verify backup file exists
if [ ! -f "${BACKUP_DIR}/${BACKUP_FILE}" ]; then
  echo "❌ ERROR: Backup file not found at ${BACKUP_DIR}/${BACKUP_FILE}"
  exit 1
fi

BACKUP_SIZE=$(du -h "${BACKUP_DIR}/${BACKUP_FILE}" | cut -f1)
echo "✅ Backup created: ${BACKUP_FILE} (${BACKUP_SIZE})"

# Upload to S3 if bucket is configured
if [ -n "$S3_BUCKET" ]; then
  echo "Uploading to S3: ${S3_BUCKET}/${BACKUP_FILE}"
  
  # Use aws CLI or mc (MinIO client) depending on what's available
  if command -v aws &> /dev/null; then
    aws s3 cp "${BACKUP_DIR}/${BACKUP_FILE}" "${S3_BUCKET}/${BACKUP_FILE}"
  elif command -v mc &> /dev/null; then
    mc cp "${BACKUP_DIR}/${BACKUP_FILE}" "${S3_BUCKET}/${BACKUP_FILE}"
  else
    echo "⚠️  WARNING: Neither 'aws' nor 'mc' CLI found. Skipping S3 upload."
  fi
  
  # Clean up old backups
  if command -v aws &> /dev/null; then
    echo "Cleaning up backups older than ${RETENTION_DAYS} days..."
    CUTOFF_DATE=$(date -d "${RETENTION_DAYS} days ago" +%Y%m%d)
    aws s3 ls "${S3_BUCKET}/" | while read -r line; do
      BACKUP_DATE=$(echo "$line" | grep -oP 'vault-data-backup-\K\d{8}')
      if [ -n "$BACKUP_DATE" ] && [ "$BACKUP_DATE" -lt "$CUTOFF_DATE" ]; then
        BACKUP_NAME=$(echo "$line" | awk '{print $4}')
        echo "Deleting old backup: $BACKUP_NAME"
        aws s3 rm "${S3_BUCKET}/${BACKUP_NAME}"
      fi
    done
  fi
fi

# Clean up local backup (kept on host via CronJob volume mount)
rm -f "${BACKUP_DIR}/${BACKUP_FILE}"

echo ""
echo "✅ Backup complete!"
echo "Backup: ${BACKUP_FILE}"
if [ -n "$S3_BUCKET" ]; then
  echo "Location: ${S3_BUCKET}/${BACKUP_FILE}"
fi
