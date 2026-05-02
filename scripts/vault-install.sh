#!/bin/bash

# Add Helm repo
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Create namespace
kubectl create namespace vault

# Install Vault with persistence and UI
helm install vault hashicorp/vault \
  --namespace vault \
  --set "server.dataStorage.enabled=true" \
  --set "server.dataStorage.size=10Gi" \
  --set "server.dataStorage.storageClass=longhorn" \
  --set "ui.enabled=true" \
  --set "ui.serviceType=ClusterIP" \
  --set "server.ingress.enabled=true" \
  --set "server.ingress.ingressClassName=traefik" \
  --set "server.ingress.hosts[0].host=vault.home.example.home" \
  --set "server.ingress.tls[0].hosts[0]=vault.home.example.home" \
  --set "server.ingress.tls[0].secretName=vault-tls" \
  --set "server.ingress.annotations.cert-manager\.io/cluster-issuer=letsencrypt-cloudflare"

echo ""
echo "Vault installed. Checking pod status..."
kubectl get pods -n vault
