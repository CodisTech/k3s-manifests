#!/bin/bash
# Prometheus & Loki Migration Install Script
# Migrates monitoring stack from Docker (VM 100) to k3s
#
# Usage: ./install-monitoring.sh [phase]
#   phase 1: Add Helm repos
#   phase 2: Install kube-prometheus-stack
#   phase 3: Install Loki
#   phase 4: Deploy exporters
#   phase 5: Update Grafana datasources
#   phase 6: Expose Loki externally
#   all: Run all phases (default)

set -e

NAMESPACE="monitoring"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl."
        exit 1
    fi

    # Check helm
    if ! command -v helm &> /dev/null; then
        log_error "Helm not found. Please install Helm 3."
        exit 1
    fi

    # Check cluster connection
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
        exit 1
    fi

    # Check namespace exists
    if ! kubectl get namespace $NAMESPACE &> /dev/null; then
        log_warn "Namespace $NAMESPACE does not exist. It should have been created with Grafana."
        log_info "Creating namespace $NAMESPACE..."
        kubectl create namespace $NAMESPACE
    fi

    # Check NFS storage class
    if ! kubectl get storageclass nfs-critical &> /dev/null; then
        log_error "nfs-critical storage class not found. Deploy infrastructure/nfs-storageclass.yaml first."
        exit 1
    fi

    log_info "Prerequisites check passed."
}

phase_1_helm_repos() {
    log_info "Phase 1: Adding Helm repositories..."

    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
    helm repo add grafana https://grafana.github.io/helm-charts || true
    helm repo update

    log_info "Helm repositories added and updated."
}

phase_2_prometheus() {
    log_info "Phase 2: Installing kube-prometheus-stack..."

    if helm status prometheus -n $NAMESPACE &> /dev/null; then
        log_warn "prometheus release already exists. Upgrading..."
        helm upgrade prometheus prometheus-community/kube-prometheus-stack \
            --namespace $NAMESPACE \
            --values "$SCRIPT_DIR/prometheus-values.yaml" \
            --wait \
            --timeout 10m
    else
        helm install prometheus prometheus-community/kube-prometheus-stack \
            --namespace $NAMESPACE \
            --values "$SCRIPT_DIR/prometheus-values.yaml" \
            --wait \
            --timeout 10m
    fi

    log_info "Waiting for Prometheus pods to be ready..."
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=prometheus \
        -n $NAMESPACE \
        --timeout=300s || true

    log_info "kube-prometheus-stack installed."
}

phase_3_loki() {
    log_info "Phase 3: Installing Loki..."

    if helm status loki -n $NAMESPACE &> /dev/null; then
        log_warn "loki release already exists. Upgrading..."
        helm upgrade loki grafana/loki-stack \
            --namespace $NAMESPACE \
            --values "$SCRIPT_DIR/loki-values.yaml" \
            --wait \
            --timeout 10m
    else
        helm install loki grafana/loki-stack \
            --namespace $NAMESPACE \
            --values "$SCRIPT_DIR/loki-values.yaml" \
            --wait \
            --timeout 10m
    fi

    log_info "Waiting for Loki pods to be ready..."
    kubectl wait --for=condition=ready pod \
        -l app=loki \
        -n $NAMESPACE \
        --timeout=300s || true

    log_info "Loki installed."
}

phase_4_exporters() {
    log_info "Phase 4: Deploying exporters..."

    log_warn "IMPORTANT: Before applying, update credentials in:"
    log_warn "  - pve-exporter.yaml (Proxmox credentials)"
    log_warn "  - pihole-exporter.yaml (Pi-hole API token)"
    read -p "Have you updated the credentials? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warn "Skipping exporter deployment. Update credentials and re-run."
        return
    fi

    kubectl apply -f "$SCRIPT_DIR/pve-exporter.yaml"
    kubectl apply -f "$SCRIPT_DIR/pihole-exporter.yaml"
    kubectl apply -f "$SCRIPT_DIR/blackbox-exporter.yaml"
    kubectl apply -f "$SCRIPT_DIR/speedtest-exporter.yaml"

    log_info "Waiting for exporter pods to be ready..."
    kubectl wait --for=condition=ready pod \
        -l app=pve-exporter \
        -n $NAMESPACE \
        --timeout=120s || true
    kubectl wait --for=condition=ready pod \
        -l app=pihole-exporter \
        -n $NAMESPACE \
        --timeout=120s || true
    kubectl wait --for=condition=ready pod \
        -l app=blackbox-exporter \
        -n $NAMESPACE \
        --timeout=120s || true
    kubectl wait --for=condition=ready pod \
        -l app=speedtest-exporter \
        -n $NAMESPACE \
        --timeout=120s || true

    log_info "Exporters deployed."
}

phase_5_grafana_datasources() {
    log_info "Phase 5: Updating Grafana datasources..."

    kubectl apply -f "$SCRIPT_DIR/grafana-datasources-updated.yaml"

    log_info "Restarting Grafana to pick up new datasources..."
    kubectl rollout restart deployment grafana -n $NAMESPACE
    kubectl rollout status deployment grafana -n $NAMESPACE --timeout=120s

    log_info "Grafana datasources updated."
}

phase_6_loki_external() {
    log_info "Phase 6: Exposing Loki externally..."

    kubectl apply -f "$SCRIPT_DIR/loki-external.yaml"

    log_info "Waiting for LoadBalancer IP assignment..."
    sleep 10

    EXTERNAL_IP=$(kubectl get svc loki-external -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")

    if [ "$EXTERNAL_IP" == "pending" ] || [ -z "$EXTERNAL_IP" ]; then
        log_warn "LoadBalancer IP not yet assigned. Check with:"
        log_warn "  kubectl get svc loki-external -n $NAMESPACE"
    else
        log_info "Loki external service available at: http://$EXTERNAL_IP:3100"
    fi

    log_info "External Loki access configured."
    log_info ""
    log_info "Update Promtail on external hosts:"
    log_info "  Pi-hole (10.0.60.55): Change Loki URL to http://10.0.60.32:3100/loki/api/v1/push"
    log_info "  VM 111 (10.0.70.10): Change Loki URL to http://10.0.60.32:3100/loki/api/v1/push"
}

show_status() {
    log_info "Current monitoring stack status:"
    echo ""
    echo "=== Pods ==="
    kubectl get pods -n $NAMESPACE -l 'app.kubernetes.io/name in (prometheus,alertmanager,prometheus-node-exporter,kube-state-metrics)'
    kubectl get pods -n $NAMESPACE -l 'app in (loki,promtail,grafana,pve-exporter,pihole-exporter,blackbox-exporter,speedtest-exporter)'
    echo ""
    echo "=== Services ==="
    kubectl get svc -n $NAMESPACE
    echo ""
    echo "=== Ingresses ==="
    kubectl get ingress -n $NAMESPACE
    echo ""
    echo "=== PVCs ==="
    kubectl get pvc -n $NAMESPACE
}

verify_installation() {
    log_info "Verification checklist:"
    echo ""
    echo "Manual verification steps:"
    echo "  1. Access Prometheus UI: https://prometheus.home.example.home"
    echo "     - Check Status > Targets - all scrape targets should be UP"
    echo ""
    echo "  2. Access Alertmanager UI: https://alertmanager.home.example.home"
    echo "     - Verify it's receiving alerts"
    echo ""
    echo "  3. Access Grafana: https://grafana.home.example.home"
    echo "     - Go to Configuration > Data Sources"
    echo "     - Test Prometheus connection"
    echo "     - Test Loki connection"
    echo "     - Verify all 13 dashboards load correctly"
    echo ""
    echo "  4. Check Loki log ingestion:"
    echo "     - In Grafana Explore, select Loki datasource"
    echo "     - Query: {job=\"kubernetes-pods\"}"
    echo "     - Verify k3s pod logs are appearing"
    echo ""
    echo "  5. Check external Promtail connections:"
    echo "     - Query: {hostname=\"pihole\"}"
    echo "     - Query: {hostname=~\"vm111.*\"}"
    echo ""
}

# Main execution
PHASE="${1:-all}"

check_prerequisites

case $PHASE in
    1)
        phase_1_helm_repos
        ;;
    2)
        phase_2_prometheus
        ;;
    3)
        phase_3_loki
        ;;
    4)
        phase_4_exporters
        ;;
    5)
        phase_5_grafana_datasources
        ;;
    6)
        phase_6_loki_external
        ;;
    all)
        phase_1_helm_repos
        phase_2_prometheus
        phase_3_loki
        phase_4_exporters
        phase_5_grafana_datasources
        phase_6_loki_external
        ;;
    status)
        show_status
        ;;
    verify)
        verify_installation
        ;;
    *)
        echo "Usage: $0 [phase]"
        echo "  phase 1: Add Helm repos"
        echo "  phase 2: Install kube-prometheus-stack"
        echo "  phase 3: Install Loki"
        echo "  phase 4: Deploy exporters"
        echo "  phase 5: Update Grafana datasources"
        echo "  phase 6: Expose Loki externally"
        echo "  all: Run all phases (default)"
        echo "  status: Show current status"
        echo "  verify: Show verification checklist"
        exit 1
        ;;
esac

echo ""
log_info "Phase $PHASE completed."
echo ""
show_status
