#!/bin/bash
# Linkerd Installation with Vault PKI Backend
# Uses HashiCorp Vault as the certificate authority for Linkerd mTLS
#
# Prerequisites:
#   - Vault running, unsealed, and PKI configured per vault-pki-integration.yaml
#   - cert-manager installed with Vault ClusterIssuer configured
#   - kubectl and linkerd CLI installed

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

VAULT_ADDR="${VAULT_ADDR:-http://10.0.60.11:8200}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check Vault connectivity
    if ! curl -s "${VAULT_ADDR}/v1/sys/health" > /dev/null; then
        log_error "Cannot connect to Vault at ${VAULT_ADDR}"
        exit 1
    fi
    log_info "Vault is reachable at ${VAULT_ADDR}"

    # Check Vault is unsealed
    SEALED=$(curl -s "${VAULT_ADDR}/v1/sys/health" | jq -r '.sealed')
    if [ "$SEALED" == "true" ]; then
        log_error "Vault is sealed. Unseal before proceeding."
        exit 1
    fi
    log_info "Vault is unsealed"

    # Check linkerd CLI
    if ! command -v linkerd &> /dev/null; then
        log_info "Installing Linkerd CLI..."
        curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/install | sh
        export PATH=$HOME/.linkerd2/bin:$PATH
    fi

    # Check cert-manager
    if ! kubectl get deployment cert-manager -n cert-manager &> /dev/null; then
        log_error "cert-manager not found. Install cert-manager first."
        exit 1
    fi
    log_info "cert-manager is installed"

    # Check Vault ClusterIssuer
    if ! kubectl get clusterissuer vault-linkerd-issuer &> /dev/null; then
        log_warn "vault-linkerd-issuer ClusterIssuer not found."
        log_warn "Apply vault-pki-integration.yaml first."
        read -p "Apply now? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kubectl apply -f "$SCRIPT_DIR/vault-pki-integration.yaml"
        else
            exit 1
        fi
    fi
    log_info "Vault ClusterIssuer is configured"
}

create_linkerd_namespace() {
    log_info "Creating linkerd namespace..."
    kubectl create namespace linkerd --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace linkerd-viz --dry-run=client -o yaml | kubectl apply -f -
}

request_certificates() {
    log_info "Requesting certificates from Vault via cert-manager..."

    # Apply certificate requests
    cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: linkerd-trust-anchor
  namespace: linkerd
spec:
  secretName: linkerd-trust-anchor
  duration: 87600h
  renewBefore: 8760h
  isCA: true
  commonName: root.linkerd.cluster.local
  issuerRef:
    name: vault-linkerd-issuer
    kind: ClusterIssuer
  privateKey:
    algorithm: ECDSA
    size: 256
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: linkerd-identity-issuer
  namespace: linkerd
spec:
  secretName: linkerd-identity-issuer
  duration: 8760h
  renewBefore: 720h
  isCA: true
  commonName: identity.linkerd.cluster.local
  dnsNames:
    - identity.linkerd.cluster.local
  issuerRef:
    name: vault-linkerd-issuer
    kind: ClusterIssuer
  privateKey:
    algorithm: ECDSA
    size: 256
EOF

    log_info "Waiting for certificates to be issued..."
    kubectl wait --for=condition=Ready certificate/linkerd-trust-anchor -n linkerd --timeout=120s
    kubectl wait --for=condition=Ready certificate/linkerd-identity-issuer -n linkerd --timeout=120s

    log_info "Certificates issued successfully"
}

install_linkerd_crds() {
    log_info "Installing Linkerd CRDs..."
    linkerd install --crds | kubectl apply -f -
}

install_linkerd_control_plane() {
    log_info "Installing Linkerd control plane with Vault-issued certificates..."

    # Extract certificates from secrets
    TRUST_ANCHOR=$(kubectl get secret linkerd-trust-anchor -n linkerd -o jsonpath='{.data.ca\.crt}' | base64 -d)
    ISSUER_CRT=$(kubectl get secret linkerd-identity-issuer -n linkerd -o jsonpath='{.data.tls\.crt}' | base64 -d)
    ISSUER_KEY=$(kubectl get secret linkerd-identity-issuer -n linkerd -o jsonpath='{.data.tls\.key}' | base64 -d)

    # Install with certificates
    linkerd install \
        --identity-trust-anchors-pem "$TRUST_ANCHOR" \
        --identity-issuer-certificate-pem "$ISSUER_CRT" \
        --identity-issuer-key-pem "$ISSUER_KEY" \
        --identity-external-issuer=true \
        | kubectl apply -f -

    log_info "Waiting for control plane..."
    linkerd check --wait 5m
}

configure_certificate_rotation() {
    log_info "Configuring automatic certificate rotation..."

    # cert-manager will automatically renew certificates
    # Linkerd will pick up new certificates via external issuer

    # Annotate the identity issuer secret for cert-manager
    kubectl annotate secret linkerd-identity-issuer -n linkerd \
        cert-manager.io/issuer-name=vault-linkerd-issuer \
        cert-manager.io/issuer-kind=ClusterIssuer \
        --overwrite

    log_info "Certificate rotation configured via cert-manager"
}

inject_monitoring_namespace() {
    log_info "Injecting Linkerd proxy into monitoring namespace..."

    kubectl annotate namespace monitoring \
        linkerd.io/inject=enabled \
        config.linkerd.io/proxy-log-level=warn \
        --overwrite

    log_info "Restarting monitoring deployments..."
    kubectl rollout restart deployment -n monitoring
    kubectl rollout restart statefulset -n monitoring 2>/dev/null || true
    kubectl rollout restart daemonset -n monitoring 2>/dev/null || true

    log_info "Waiting for pods to be ready..."
    sleep 15
    kubectl get pods -n monitoring
}

verify_mtls() {
    log_info "Verifying mTLS with Vault-issued certificates..."

    # Check control plane
    linkerd check

    # Verify certificate chain
    log_info "Certificate chain verification:"
    kubectl get secret linkerd-trust-anchor -n linkerd -o jsonpath='{.data.ca\.crt}' | base64 -d | openssl x509 -text -noout | grep -E "(Subject:|Issuer:|Not After)"

    log_info "Identity issuer certificate:"
    kubectl get secret linkerd-identity-issuer -n linkerd -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | grep -E "(Subject:|Issuer:|Not After)"

    # Check proxy injection in monitoring
    log_info "Checking mTLS in monitoring namespace..."
    linkerd check --proxy -n monitoring

    log_info ""
    log_info "Vault PKI integration complete!"
    log_info "All pod-to-pod traffic in injected namespaces is now encrypted with Vault-issued certificates."
}

show_status() {
    echo ""
    echo "=== Linkerd Status ==="
    linkerd check 2>/dev/null || true
    echo ""
    echo "=== Certificates ==="
    kubectl get certificates -n linkerd
    echo ""
    echo "=== Certificate Status ==="
    kubectl describe certificates -n linkerd | grep -A5 "Status:"
    echo ""
    echo "=== Injected Namespaces ==="
    kubectl get namespaces -l linkerd.io/inject=enabled
}

main() {
    case "${1:-all}" in
        check)
            check_prerequisites
            ;;
        certs)
            create_linkerd_namespace
            request_certificates
            ;;
        install)
            install_linkerd_crds
            install_linkerd_control_plane
            configure_certificate_rotation
            ;;
        inject)
            inject_monitoring_namespace
            ;;
        verify)
            verify_mtls
            ;;
        status)
            show_status
            ;;
        all)
            check_prerequisites
            create_linkerd_namespace
            request_certificates
            install_linkerd_crds
            install_linkerd_control_plane
            configure_certificate_rotation
            inject_monitoring_namespace
            verify_mtls
            ;;
        *)
            echo "Usage: $0 {check|certs|install|inject|verify|status|all}"
            echo ""
            echo "  check   - Verify prerequisites (Vault, cert-manager)"
            echo "  certs   - Request certificates from Vault"
            echo "  install - Install Linkerd with Vault certificates"
            echo "  inject  - Inject proxy into monitoring namespace"
            echo "  verify  - Verify mTLS is working"
            echo "  status  - Show current status"
            echo "  all     - Run all steps (default)"
            exit 1
            ;;
    esac
}

main "$@"
