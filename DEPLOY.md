# k3s Manifests - GitOps Deployment

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Mac (Development)                             │
│  ~/HomeLab Vault/08_Automation/k3s-manifests/                   │
│                                                                  │
│  Claude Code edits → git commit → git push                       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                 Gitea (Source of Truth)                          │
│  https://git.local.example.home/john/k3s-manifests            │
│                                                                  │
│  - Version history                                               │
│  - Rollback capability                                           │
│  - Diff review before deploy                                     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│            k3s-control (10.0.60.21)                           │
│  /opt/k3s-manifests/                                             │
│                                                                  │
│  k3s-deploy → git pull → kubectl apply (changed files only)      │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    k3s Cluster                                   │
│  *.home.example.home                                           │
│  3 nodes: control + worker-1 (GPU) + worker-2                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Repository Structure

```
k3s-manifests/
├── apps/                      # Application workloads
│   ├── homarr.yaml
│   ├── jellyfin.yaml
│   ├── jellyseerr.yaml
│   ├── jellystat.yaml
│   ├── jellystat-externalsecret.yaml
│   ├── plex.yaml
│   ├── plex-nodeport.yaml
│   ├── postgresql-shared.yaml
│   ├── postgresql-externalsecret.yaml
│   ├── tautulli.yaml
│   ├── vaultwarden.yaml
│   └── vaultwarden-externalsecret.yaml
│
├── infrastructure/            # Cluster infrastructure
│   ├── cert-manager-cloudflare.yaml
│   ├── metallb-config.yaml
│   ├── nfs-storageclass.yaml
│   ├── nfs-media-storage.yaml
│   ├── nvidia-device-plugin.yaml
│   ├── nvidia-runtimeclass.yaml
│   ├── traefik-dashboard-ingress.yaml
│   ├── vault-eso-config.yaml
│   └── vault-transit-values.yaml
│
├── external-services/         # Routing to non-k3s services
│   ├── docker-apps.yaml
│   ├── infrastructure.yaml
│   ├── proxmox-server-a-ingress.yaml
│   ├── proxmox-server-c-ingress.yaml
│   └── proxmox-server-d.yaml
│
├── monitoring/                # Observability stack
│   ├── grafana.yaml
│   ├── prometheus-values.yaml
│   ├── loki-values.yaml
│   ├── pihole-exporter.yaml
│   ├── pve-exporter.yaml
│   ├── dcgm-exporter.yaml
│   └── ...
│
├── scripts/                   # Install/migration scripts
│   ├── k3s-deploy             # Deploy script (install on control plane)
│   ├── install-traefik.sh
│   └── longhorn-to-nfs-migration.sh
│
├── DEPLOY.md                  # This file
└── .gitignore
```

**Apply order matters**: infrastructure → apps → external-services → monitoring

The `k3s-deploy` script handles this automatically.

---

## Environments

| Environment | Target | Access |
|-------------|--------|--------|
| k3s cluster | 10.0.60.21 (control plane) | SSH as john |
| Apps | `*.home.example.home` | Via Traefik (10.0.60.31) |

No staging environment for k3s — manifests are tested with `--dry-run` before applying.

---

## Workflow

### Making Changes (Development)

1. **Edit manifests in vault** using Claude Code or any editor:
   ```
   ~/HomeLab Vault/08_Automation/k3s-manifests/
   ```

2. **Commit changes**:
   ```bash
   cd ~/Documents/NextCloud/CODISTECH/HomeLab/HomeLab\ Vault/08_Automation/k3s-manifests
   git add -A
   git commit -m "Description of changes"
   ```

3. **Push to Gitea**:
   ```bash
   git push origin main
   ```

### Deploying to Cluster

1. **SSH to k3s-control**:
   ```bash
   ssh john@10.0.60.21
   ```

2. **Deploy all changed manifests**:
   ```bash
   k3s-deploy
   ```

3. **Or deploy a specific category**:
   ```bash
   k3s-deploy apps           # Only app manifests
   k3s-deploy infrastructure  # Only infra manifests
   k3s-deploy monitoring      # Only monitoring
   k3s-deploy external        # Only external services
   ```

4. **Dry run first** (preview changes without applying):
   ```bash
   k3s-deploy --dry-run
   k3s-deploy apps --dry-run
   ```

5. **Force reapply everything** (even unchanged files):
   ```bash
   k3s-deploy --force
   ```

---

## Quick Commands

### From Mac

```bash
# Alias for convenience (add to ~/.zshrc)
alias k3s-repo='cd ~/Documents/NextCloud/CODISTECH/HomeLab/HomeLab\ Vault/08_Automation/k3s-manifests'

# Quick commit and push
k3s-repo && git add -A && git commit -m "Update" && git push

# View status
k3s-repo && git status

# View what changed
k3s-repo && git diff
```

### From k3s-control

```bash
# Deploy all changes
k3s-deploy

# Deploy only apps
k3s-deploy apps

# Preview what would change
k3s-deploy --dry-run

# View current deployed version
cd /opt/k3s-manifests && git log -1 --oneline

# View recent changes
cd /opt/k3s-manifests && git log --oneline -10

# Check what would change (without deploying)
cd /opt/k3s-manifests && git fetch && git diff HEAD..origin/main --stat

# Quick cluster health check
kubectl get pods -A | grep -v Running | grep -v Completed
kubectl get pvc -A
kubectl get nodes
```

---

## Rollback

### Rollback to Previous Commit

```bash
ssh john@10.0.60.21
cd /opt/k3s-manifests

# View history
git log --oneline -10

# Rollback to specific commit
git checkout <commit-hash> -- .
k3s-deploy --force

# Or rollback one commit
git checkout HEAD~1 -- .
k3s-deploy --force
```

### Rollback via Gitea

1. Revert commit in Gitea UI or locally
2. Push the revert
3. Run `k3s-deploy` on control plane

### Rollback a Single App

```bash
ssh john@10.0.60.21
cd /opt/k3s-manifests

# Restore a single file from a previous commit
git checkout <commit-hash> -- apps/plex.yaml
kubectl apply -f apps/plex.yaml
```

---

## Files

| Location | Purpose |
|----------|---------|
| Mac vault `k3s-manifests/` | Development — edit here |
| Gitea `k3s-manifests` | Source of truth — version control |
| k3s-control `/opt/k3s-manifests/` | Deployed copy — applies to cluster |

---

## Deploy Script (k3s-control)

**Location**: `/usr/local/bin/k3s-deploy`

**Source**: `scripts/k3s-deploy` in this repo

**Features**:
- Pulls latest from Gitea
- Detects which files changed (only applies diffs)
- Supports category filtering (apps, infrastructure, monitoring, external)
- Dry-run mode for previewing changes
- Post-deploy health check (shows unhealthy pods + PVC status)

---

## Initial Setup (One-Time)

### 1. Create Gitea Repository

Create repo at: https://git.local.example.home/john/k3s-manifests

### 2. Mac (Development)

```bash
cd ~/Documents/NextCloud/CODISTECH/HomeLab/HomeLab\ Vault/08_Automation/k3s-manifests
git init
git remote add origin https://git.local.example.home/john/k3s-manifests.git
git branch -M main
git add -A
git commit -m "Initial k3s manifests — NFS storage, all apps"
git push -u origin main
```

### 3. k3s-control (10.0.60.21)

```bash
# Clone from Gitea
sudo git clone https://git.local.example.home/john/k3s-manifests.git /opt/k3s-manifests
sudo chown -R john:john /opt/k3s-manifests

# Install deploy script
sudo cp /opt/k3s-manifests/scripts/k3s-deploy /usr/local/bin/k3s-deploy
sudo chmod +x /usr/local/bin/k3s-deploy

# Test
k3s-deploy --dry-run
```

---

## Security Notes

- Gitea requires authentication (Authentik SSO or local credentials)
- k3s-control uses HTTPS to pull from Gitea (VLAN 60 internal)
- **No secrets in this repo** — all secrets managed via:
  - ExternalSecrets pulling from HashiCorp Vault
  - cert-manager for TLS certificates
- `.gitignore` blocks `*-secret.yaml`, `*.key`, `*.pem`
- Manifests are declarative — `kubectl apply` is idempotent and safe to re-run

---

## Troubleshooting

### Push Rejected

```bash
# If Gitea has changes you don't have locally
git pull --rebase origin main
git push origin main
```

### Permission Denied on k3s-control

```bash
sudo chown -R john:john /opt/k3s-manifests
```

### Manifest Apply Failed

```bash
# Check the specific error
kubectl apply -f /opt/k3s-manifests/apps/problem-app.yaml --dry-run=server

# Check events
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -10
```

### Pod Not Starting After Deploy

```bash
# Check pod status
kubectl describe pod -n <namespace> <pod-name>

# Check PVC binding
kubectl get pvc -n <namespace>

# Check NFS connectivity
showmount -e 10.0.60.9
```

---

## Related Documentation

- [[Storage_Classes]] — NFS StorageClass configuration
- [[K3s_Deployment_Summary]] — Cluster overview
- [[Docker_to_k3s_Migration]] — Migration status

---

## Tags

#kubernetes #k3s #gitops #gitea #deployment #nfs #manifests #phase4-migration
