#!/bin/bash
# pve-config-backup.sh — Export Proxmox VM configs from all hosts to local directory
#
# Deploy on: k3s-control-1 (10.0.60.21) or any host with SSH access to all PVE nodes
# Schedule:  Daily via cron or systemd timer
#
# What it does:
#   1. SSH to each Proxmox host
#   2. Copy /etc/pve/qemu-server/*.conf and /etc/pve/lxc/*.conf
#   3. Store locally with timestamps
#   4. Optionally push to Gitea repo
#
# These files are tiny (KB each) but critical for VM recreation

set -euo pipefail

BACKUP_BASE="/storage/k3s-backups/pve-configs"
HOSTS=(
    "10.0.60.10:pve-server-a"
    "10.0.60.9:nas"
    "10.0.60.8:pve-server-d"
)
DATE=$(date +%Y-%m-%d)
LOG_TAG="pve-config-backup"

log() {
    logger -t "$LOG_TAG" "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Starting Proxmox VM config backup"

for HOST_ENTRY in "${HOSTS[@]}"; do
    IP="${HOST_ENTRY%%:*}"
    NAME="${HOST_ENTRY##*:}"
    DEST="${BACKUP_BASE}/${NAME}"

    mkdir -p "${DEST}/qemu-server" "${DEST}/lxc"

    log "Backing up ${NAME} (${IP})..."

    # Copy VM configs
    scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "root@${IP}:/etc/pve/qemu-server/*.conf" \
        "${DEST}/qemu-server/" 2>/dev/null || log "  No QEMU configs on ${NAME}"

    # Copy LXC configs
    scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "root@${IP}:/etc/pve/lxc/*.conf" \
        "${DEST}/lxc/" 2>/dev/null || log "  No LXC configs on ${NAME}"

    # Copy storage config
    scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "root@${IP}:/etc/pve/storage.cfg" \
        "${DEST}/storage.cfg" 2>/dev/null || true

    # Copy cluster config if exists
    scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "root@${IP}:/etc/pve/corosync.conf" \
        "${DEST}/corosync.conf" 2>/dev/null || true

    QEMU_COUNT=$(ls -1 "${DEST}/qemu-server/" 2>/dev/null | wc -l)
    LXC_COUNT=$(ls -1 "${DEST}/lxc/" 2>/dev/null | wc -l)
    log "  ${NAME}: ${QEMU_COUNT} VMs, ${LXC_COUNT} containers"
done

# Write manifest
log "Writing backup manifest..."
cat > "${BACKUP_BASE}/manifest.txt" <<EOF
Proxmox VM Config Backup
Date: ${DATE}
Time: $(date '+%H:%M:%S')
Hosts backed up:
EOF

for HOST_ENTRY in "${HOSTS[@]}"; do
    NAME="${HOST_ENTRY##*:}"
    DEST="${BACKUP_BASE}/${NAME}"
    QEMU_COUNT=$(ls -1 "${DEST}/qemu-server/" 2>/dev/null | wc -l)
    LXC_COUNT=$(ls -1 "${DEST}/lxc/" 2>/dev/null | wc -l)
    echo "  ${NAME}: ${QEMU_COUNT} VMs, ${LXC_COUNT} containers" >> "${BACKUP_BASE}/manifest.txt"
done

# Optional: Git commit if repo is initialized
if [ -d "${BACKUP_BASE}/.git" ]; then
    cd "${BACKUP_BASE}"
    git add -A
    git diff --cached --quiet || {
        git commit -m "PVE config backup ${DATE}"
        log "Committed changes to git"
        # Push to Gitea if remote is configured
        git push origin main 2>/dev/null && log "Pushed to Gitea" || log "Git push skipped (no remote or auth)"
    }
fi

log "Proxmox config backup complete"
