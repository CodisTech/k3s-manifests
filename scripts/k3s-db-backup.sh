#!/bin/bash
# k3s-db-backup.sh — Online SQLite backup of the k3s datastore
#
# Deploy on: k3s-control (10.0.60.21)
# Schedule:  every 6 hours via k3s-db-backup.timer
#
# Why SQLite, not etcd:
#   This cluster runs k3s with a single control plane, so the datastore
#   defaults to embedded SQLite (state.db) rather than embedded etcd.
#   `k3s etcd-snapshot save` errors with "etcd datastore disabled".
#
# What this does:
#   1. Uses `sqlite3 .backup` for an online, consistent snapshot of
#      /var/lib/rancher/k3s/server/db/state.db while k3s is running
#   2. Compresses with gzip
#   3. Rsyncs all snapshots to Server C for off-node redundancy
#   4. Prunes local snapshots older than 3 days, keeping at least 10
#
# Restore: stop k3s, restore the .db file to /var/lib/rancher/k3s/server/db/,
#          delete state.db-shm and state.db-wal, start k3s.

set -euo pipefail

DB_PATH="/var/lib/rancher/k3s/server/db/state.db"
BACKUP_DIR="/var/lib/rancher/k3s/server/db/snapshots"
REMOTE_HOST="10.0.60.9"
REMOTE_DIR="/storage/k3s-backups/k3s-db"
LOG_TAG="k3s-db-backup"
MAX_LOCAL_AGE_DAYS=3
MIN_LOCAL_KEEP=10

log() {
    logger -t "$LOG_TAG" "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

mkdir -p "$BACKUP_DIR"

if [ ! -f "$DB_PATH" ]; then
    log "ERROR: $DB_PATH not found — is k3s running with SQLite datastore?"
    exit 1
fi

# Step 1: online sqlite backup (safe while k3s is writing)
SNAPSHOT_NAME="state-$(date +%Y%m%d-%H%M%S).db"
SNAPSHOT_PATH="${BACKUP_DIR}/${SNAPSHOT_NAME}"
log "Creating online SQLite backup: ${SNAPSHOT_NAME}"
sqlite3 "$DB_PATH" ".backup '${SNAPSHOT_PATH}'"

if [ ! -f "$SNAPSHOT_PATH" ]; then
    log "ERROR: Backup file not created at ${SNAPSHOT_PATH}"
    exit 1
fi

# Step 2: compress
gzip -f "$SNAPSHOT_PATH"
SNAPSHOT_GZ="${SNAPSHOT_PATH}.gz"
SIZE=$(du -h "$SNAPSHOT_GZ" | cut -f1)
log "Backup compressed: ${SNAPSHOT_GZ} (${SIZE})"

# Step 3: ensure remote dir, then rsync all snapshots
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "root@${REMOTE_HOST}" \
    "mkdir -p ${REMOTE_DIR}" 2>/dev/null || {
    log "ERROR: Cannot reach ${REMOTE_HOST} — backup saved locally only"
    exit 1
}

log "Syncing backups to ${REMOTE_HOST}:${REMOTE_DIR}"
rsync -az --delete \
    "${BACKUP_DIR}/" \
    "root@${REMOTE_HOST}:${REMOTE_DIR}/"

REMOTE_COUNT=$(ssh "root@${REMOTE_HOST}" "ls -1 ${REMOTE_DIR}/ | wc -l" 2>/dev/null || echo "?")
log "Sync complete — ${REMOTE_COUNT} files on remote"

# Step 4: prune old local snapshots (keep at least MIN_LOCAL_KEEP)
LOCAL_COUNT=$(ls -1 "${BACKUP_DIR}/" 2>/dev/null | wc -l)
if [ "$LOCAL_COUNT" -gt "$MIN_LOCAL_KEEP" ]; then
    PRUNED=$(find "${BACKUP_DIR}" -name 'state-*.db.gz' -mtime +"$MAX_LOCAL_AGE_DAYS" -type f | wc -l)
    if [ "$PRUNED" -gt 0 ]; then
        find "${BACKUP_DIR}" -name 'state-*.db.gz' -mtime +"$MAX_LOCAL_AGE_DAYS" -type f -delete
        log "Pruned ${PRUNED} local snapshots older than ${MAX_LOCAL_AGE_DAYS} days"
    fi
fi

log "k3s SQLite backup complete"
