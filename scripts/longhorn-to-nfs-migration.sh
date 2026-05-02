#!/usr/bin/env bash
# =============================================================================
# Longhorn → NFS Migration Runbook
# Run sections manually — this is NOT meant to be executed as one script.
# =============================================================================
set -euo pipefail

# =============================================================================
# PHASE 1: Attempt Longhorn Recovery (to extract data)
# =============================================================================

# 1a. Check the disk name mapping issue on each node
echo "=== Phase 1: Longhorn Disk Diagnosis ==="
for NODE in k3s-worker-1 k3s-worker-2 k3s-control; do
  echo "--- $NODE ---"
  kubectl -n longhorn-system get nodes.longhorn.io "$NODE" -o jsonpath='{.spec.disks}' | jq .
  echo ""
  echo "Replicas referencing this node:"
  kubectl -n longhorn-system get replicas -o json | \
    jq -r ".items[] | select(.spec.nodeID==\"$NODE\") | \"\(.metadata.name) diskID=\(.spec.diskID)\""
  echo ""
done

# 1b. Fix disk name mismatch — delete and re-add default disk
# For each node, patch the disk spec so the key matches what replicas expect
# Example (adjust per node):
#
# NODE=k3s-worker-1
# DISK_UUID=$(kubectl -n longhorn-system get replicas -o json | \
#   jq -r ".items[] | select(.spec.nodeID==\"$NODE\") | .spec.diskID" | head -1)
#
# kubectl -n longhorn-system patch nodes.longhorn.io $NODE --type merge -p \
#   "{\"spec\":{\"disks\":{\"$DISK_UUID\":{\"allowScheduling\":true,\"path\":\"/var/lib/longhorn\",\"storageReserved\":0}}}}"

# 1c. Verify volumes recover
kubectl -n longhorn-system get volumes -o wide
kubectl get pods -A | grep -v Running | grep -v Completed

# 1d. If Longhorn cannot be fixed — extract data directly from replica dirs
# SSH to each worker node:
#
# ls /var/lib/longhorn/replicas/
# # Each directory contains volume-head-xxx.img files
# # These are sparse files — the actual data is inside
#
# # For Vaultwarden (CRITICAL — password data):
# REPLICA_DIR=$(ls -d /var/lib/longhorn/replicas/vaultwarden*)
# mkdir -p /tmp/vw-recovery
# # The .img files are raw block devices. Mount the volume head:
# LOOP=$(sudo losetup --find --show "$REPLICA_DIR/volume-head-000.img")
# sudo mount "$LOOP" /tmp/vw-recovery
# sudo cp -a /tmp/vw-recovery/* /storage/k3s/pvc-vaultwarden-data/
# sudo umount /tmp/vw-recovery
# sudo losetup -d "$LOOP"
#
# # For PostgreSQL (CRITICAL — database):
# REPLICA_DIR=$(ls -d /var/lib/longhorn/replicas/postgresql*)
# mkdir -p /tmp/pg-recovery
# LOOP=$(sudo losetup --find --show "$REPLICA_DIR/volume-head-000.img")
# sudo mount "$LOOP" /tmp/pg-recovery
# # pg_dump is safer than raw copy for postgres:
# sudo cp -a /tmp/pg-recovery/pgdata/* /storage/k3s/pvc-postgresql-data/pgdata/
# sudo umount /tmp/pg-recovery
# sudo losetup -d "$LOOP"

# =============================================================================
# PHASE 2: Set Up NFS Storage on Server C
# =============================================================================

echo "=== Phase 2: NFS Setup ==="

# 2a. SSH to Server C (10.0.60.9) and create NFS export
# ssh root@10.0.60.9
#
# # Create dataset (ZFS — preferred over mkdir for snapshots)
# zfs create storage/k3s
#
# # Set permissions
# chmod 755 /storage/k3s
#
# # Add NFS export
# cat >> /etc/exports <<'EXPORTS'
# /storage/k3s 10.0.60.0/24(rw,sync,no_subtree_check,no_root_squash)
# EXPORTS
#
# # Apply exports
# exportfs -ra
# showmount -e localhost
#
# # Create subdirectories for each app's PVC
# mkdir -p /storage/k3s/pvc-homarr-data
# mkdir -p /storage/k3s/pvc-plex-config
# mkdir -p /storage/k3s/pvc-jellyfin-config
# mkdir -p /storage/k3s/pvc-vaultwarden-data
# mkdir -p /storage/k3s/pvc-postgresql-data
# mkdir -p /storage/k3s/pvc-jellyseerr-config
# mkdir -p /storage/k3s/pvc-jellystat-db

# 2b. Install NFS CSI driver on k3s (from control plane)
echo "Installing NFS CSI driver..."
curl -skSL https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/deploy/install-driver.sh | bash -s master --

echo "Waiting for CSI driver pods..."
kubectl wait --for=condition=Ready pod -l app=csi-nfs-controller -n kube-system --timeout=120s
kubectl wait --for=condition=Ready pod -l app=csi-nfs-node -n kube-system --timeout=120s
kubectl get pods -n kube-system | grep csi-nfs

# 2c. Remove Longhorn as default StorageClass (so NFS becomes default)
kubectl patch sc longhorn -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'

# 2d. Apply NFS StorageClass
kubectl apply -f nfs-storageclass.yaml
kubectl get sc

# 2e. Test with a throwaway PVC
cat <<'TEST_PVC' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfs-test-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-critical
  resources:
    requests:
      storage: 1Gi
TEST_PVC

echo "Waiting for test PVC to bind..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/nfs-test-pvc -n default --timeout=60s
kubectl get pvc nfs-test-pvc -n default

# Clean up test
kubectl delete pvc nfs-test-pvc -n default
echo "NFS StorageClass working."

# =============================================================================
# PHASE 3: Migrate Apps (Longhorn → NFS)
# =============================================================================

echo "=== Phase 3: App Migration ==="

# Migration order:
# 1. Homarr (low criticality, test the process)
# 2. Jellyseerr (low criticality)
# 3. Jellystat (low criticality)
# 4. Plex (already on emptyDir workaround)
# 5. Jellyfin (config only — media already on NFS)
# 6. PostgreSQL (CRITICAL — dump DB first)
# 7. Vaultwarden (CRITICAL — depends on PostgreSQL)

# --- Generic migration function ---
# For each app:
#   1. Scale down deployment
#   2. Delete old Longhorn PVC (data already copied in Phase 1 or app regenerates)
#   3. Apply updated manifest (now uses nfs-critical)
#   4. Scale up and verify

# --- 3a. Homarr ---
echo "Migrating Homarr..."
kubectl scale deploy homarr -n homarr --replicas=0
kubectl delete pvc homarr-data -n homarr --wait=false
# Wait for PVC to be deleted (may need to remove finalizer if stuck)
# kubectl patch pvc homarr-data -n homarr -p '{"metadata":{"finalizers":null}}'
kubectl apply -f homarr.yaml
kubectl wait --for=condition=Available deploy/homarr -n homarr --timeout=120s
echo "Homarr migrated."

# --- 3b. Jellyseerr ---
echo "Migrating Jellyseerr..."
kubectl scale deploy jellyseerr -n jellyseerr --replicas=0
kubectl delete pvc jellyseerr-config -n jellyseerr --wait=false
kubectl apply -f jellyseerr.yaml
kubectl wait --for=condition=Available deploy/jellyseerr -n jellyseerr --timeout=120s
echo "Jellyseerr migrated."

# --- 3c. Jellystat ---
echo "Migrating Jellystat..."
kubectl scale deploy jellystat -n jellystat --replicas=0
kubectl scale deploy jellystat-db -n jellystat --replicas=0
kubectl delete pvc jellystat-db -n jellystat --wait=false
kubectl apply -f jellystat.yaml
kubectl wait --for=condition=Available deploy/jellystat-db -n jellystat --timeout=120s
kubectl wait --for=condition=Available deploy/jellystat -n jellystat --timeout=120s
echo "Jellystat migrated."

# --- 3d. Plex ---
echo "Migrating Plex..."
kubectl scale deploy plex -n plex --replicas=0
kubectl delete pvc plex-config -n plex --wait=false
kubectl apply -f plex.yaml
kubectl wait --for=condition=Available deploy/plex -n plex --timeout=180s
echo "Plex migrated."

# --- 3e. Jellyfin ---
echo "Migrating Jellyfin..."
kubectl scale deploy jellyfin -n jellyfin --replicas=0
kubectl delete pvc jellyfin-config -n jellyfin --wait=false
kubectl apply -f jellyfin.yaml
kubectl wait --for=condition=Available deploy/jellyfin -n jellyfin --timeout=120s
echo "Jellyfin migrated."

# --- 3f. PostgreSQL (CRITICAL) ---
echo "Migrating PostgreSQL (CRITICAL)..."
echo "STOP — Before proceeding, dump the database:"
echo "  kubectl exec -n postgresql deploy/postgresql -- pg_dumpall -U postgres > /tmp/pg_backup.sql"
echo "  Copy to NFS: scp /tmp/pg_backup.sql root@10.0.60.9:/storage/k3s/pvc-postgresql-data/"
echo ""
echo "Press Enter after backup is confirmed..."
# read -r

kubectl scale deploy postgresql -n postgresql --replicas=0
kubectl delete pvc postgresql-data -n postgresql --wait=false
kubectl apply -f postgresql-shared.yaml
kubectl wait --for=condition=Available deploy/postgresql -n postgresql --timeout=120s

# Restore database if this is a fresh PostgreSQL (init-databases.sql only creates empty DBs)
# kubectl exec -n postgresql deploy/postgresql -- psql -U postgres < /tmp/pg_backup.sql
echo "PostgreSQL migrated."

# --- 3g. Vaultwarden (CRITICAL — depends on PostgreSQL) ---
echo "Migrating Vaultwarden (CRITICAL)..."
echo "Verify PostgreSQL is healthy first:"
echo "  kubectl exec -n postgresql deploy/postgresql -- psql -U postgres -c '\\l'"
echo ""
kubectl scale deploy vaultwarden -n vaultwarden --replicas=0
kubectl delete pvc vaultwarden-data -n vaultwarden --wait=false
kubectl apply -f vaultwarden.yaml
kubectl wait --for=condition=Available deploy/vaultwarden -n vaultwarden --timeout=120s
echo "Vaultwarden migrated."

# =============================================================================
# PHASE 4: Remove Longhorn
# =============================================================================

echo "=== Phase 4: Remove Longhorn ==="

# 4a. Verify all apps running on NFS
echo "Checking all pods..."
kubectl get pods -A | grep -v Running | grep -v Completed | grep -v kube-system
echo ""
echo "Checking all PVCs..."
kubectl get pvc -A
echo ""
echo "All PVCs should show nfs-critical, not longhorn."
echo ""

# 4b. Delete remaining Longhorn PVCs (if any still exist)
# These should have been deleted during migration, but check:
# kubectl get pvc -A -o json | jq -r '.items[] | select(.spec.storageClassName=="longhorn") | "\(.metadata.namespace)/\(.metadata.name)"'

# 4c. Uninstall Longhorn
echo "Uninstalling Longhorn..."
kubectl -n longhorn-system patch -p '{"value":"true"}' --type=merge lhs deleting-confirmation-flag
helm uninstall longhorn -n longhorn-system
kubectl delete namespace longhorn-system --wait=false

# 4d. Wait for namespace cleanup
echo "Waiting for longhorn-system namespace to be deleted (may take a few minutes)..."
# If stuck, check for finalizers:
# kubectl get ns longhorn-system -o json | jq '.spec.finalizers'

# 4e. Clean up worker node disk space
echo "Clean up Longhorn data on each worker node:"
echo "  ssh k3s-worker-1 'sudo rm -rf /var/lib/longhorn'"
echo "  ssh k3s-worker-2 'sudo rm -rf /var/lib/longhorn'"
echo "  ssh k3s-control 'sudo rm -rf /var/lib/longhorn'"

echo ""
echo "=== Migration Complete ==="
echo "Verify:"
echo "  - All pods Running: kubectl get pods -A"
echo "  - All PVCs on NFS: kubectl get pvc -A"
echo "  - Longhorn gone: kubectl get ns longhorn-system (should 404)"
echo "  - Apps accessible via browser"
