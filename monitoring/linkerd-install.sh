#!/bin/bash
# Linkerd Service Mesh Installation
# Provides automatic mTLS for all pod-to-pod traffic
#
# Reference: https://linkerd.io/2.14/getting-started/

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v linkerd &> /dev/null; then
        log_info "Installing Linkerd CLI..."
        curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/install | sh
        export PATH=$HOME/.linkerd2/bin:$PATH
        echo 'export PATH=$HOME/.linkerd2/bin:$PATH' >> ~/.bashrc
    fi

    linkerd version --client

    log_info "Running pre-installation checks..."
    linkerd check --pre
}

# Generate certificates using step-cli (recommended) or openssl
generate_certificates() {
    log_info "Generating Linkerd trust anchor and issuer certificates..."

    CERT_DIR="$HOME/.linkerd2/certs"
    mkdir -p "$CERT_DIR"

    if command -v step &> /dev/null; then
        log_info "Using step-cli for certificate generation..."

        # Trust anchor (root CA) - valid for 10 years
        step certificate create root.linkerd.cluster.local \
            "$CERT_DIR/ca.crt" "$CERT_DIR/ca.key" \
            --profile root-ca \
            --no-password --insecure \
            --not-after=87600h

        # Identity issuer - valid for 1 year
        step certificate create identity.linkerd.cluster.local \
            "$CERT_DIR/issuer.crt" "$CERT_DIR/issuer.key" \
            --profile intermediate-ca \
            --ca "$CERT_DIR/ca.crt" \
            --ca-key "$CERT_DIR/ca.key" \
            --no-password --insecure \
            --not-after=8760h
    else
        log_info "Using openssl for certificate generation..."

        # Trust anchor (root CA)
        openssl ecparam -name prime256v1 -genkey -noout -out "$CERT_DIR/ca.key"
        openssl req -x509 -new -nodes -key "$CERT_DIR/ca.key" \
            -sha256 -days 3650 \
            -out "$CERT_DIR/ca.crt" \
            -subj "/CN=root.linkerd.cluster.local"

        # Identity issuer
        openssl ecparam -name prime256v1 -genkey -noout -out "$CERT_DIR/issuer.key"
        openssl req -new -key "$CERT_DIR/issuer.key" \
            -out "$CERT_DIR/issuer.csr" \
            -subj "/CN=identity.linkerd.cluster.local"
        openssl x509 -req -in "$CERT_DIR/issuer.csr" \
            -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" \
            -CAcreateserial -out "$CERT_DIR/issuer.crt" \
            -days 365 -sha256
    fi

    log_info "Certificates generated in $CERT_DIR"
    ls -la "$CERT_DIR"
}

# Install Linkerd CRDs
install_crds() {
    log_info "Installing Linkerd CRDs..."
    linkerd install --crds | kubectl apply -f -
}

# Install Linkerd control plane
install_control_plane() {
    log_info "Installing Linkerd control plane with mTLS..."

    CERT_DIR="$HOME/.linkerd2/certs"

    linkerd install \
        --identity-trust-anchors-file "$CERT_DIR/ca.crt" \
        --identity-issuer-certificate-file "$CERT_DIR/issuer.crt" \
        --identity-issuer-key-file "$CERT_DIR/issuer.key" \
        | kubectl apply -f -

    log_info "Waiting for control plane to be ready..."
    linkerd check
}

# Install Linkerd Viz extension (optional, for dashboard)
install_viz() {
    log_info "Installing Linkerd Viz extension..."
    linkerd viz install | kubectl apply -f -

    log_info "Waiting for Viz to be ready..."
    linkerd viz check
}

# Inject Linkerd proxy into monitoring namespace
inject_monitoring() {
    log_info "Annotating monitoring namespace for automatic proxy injection..."

    kubectl annotate namespace monitoring \
        linkerd.io/inject=enabled \
        --overwrite

    log_info "Restarting deployments to inject Linkerd proxy..."

    # Restart all deployments in monitoring namespace
    kubectl rollout restart deployment -n monitoring
    kubectl rollout restart statefulset -n monitoring 2>/dev/null || true
    kubectl rollout restart daemonset -n monitoring 2>/dev/null || true

    log_info "Waiting for pods to be ready with Linkerd proxy..."
    sleep 10
    kubectl get pods -n monitoring
}

# Verify mTLS
verify_mtls() {
    log_info "Verifying mTLS is active..."

    # Check if proxies are injected
    linkerd check --proxy -n monitoring

    # Show mTLS status
    echo ""
    log_info "mTLS edges in monitoring namespace:"
    linkerd viz edges deployment -n monitoring 2>/dev/null || log_warn "Viz not installed, skipping edge view"

    echo ""
    log_info "To view live traffic encryption status:"
    echo "  linkerd viz tap deployment/grafana -n monitoring"
    echo "  linkerd viz dashboard"
}

# Main
main() {
    case "${1:-all}" in
        check)
            check_prerequisites
            ;;
        certs)
            generate_certificates
            ;;
        install)
            install_crds
            install_control_plane
            ;;
        viz)
            install_viz
            ;;
        inject)
            inject_monitoring
            ;;
        verify)
            verify_mtls
            ;;
        all)
            check_prerequisites
            generate_certificates
            install_crds
            install_control_plane
            inject_monitoring
            verify_mtls
            ;;
        *)
            echo "Usage: $0 {check|certs|install|viz|inject|verify|all}"
            echo ""
            echo "  check   - Verify prerequisites and run pre-checks"
            echo "  certs   - Generate trust anchor and issuer certificates"
            echo "  install - Install Linkerd CRDs and control plane"
            echo "  viz     - Install Linkerd Viz dashboard (optional)"
            echo "  inject  - Inject Linkerd proxy into monitoring namespace"
            echo "  verify  - Verify mTLS is working"
            echo "  all     - Run all steps (default)"
            exit 1
            ;;
    esac
}

main "$@"
