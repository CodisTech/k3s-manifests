#!/bin/bash
# Install Traefik via Helm

helm install traefik traefik/traefik \
  --namespace traefik \
  --create-namespace \
  --set service.type=LoadBalancer \
  --set ingressRoute.dashboard.enabled=true \
  --set ports.web.exposedPort=80 \
  --set ports.websecure.exposedPort=443

echo "Waiting for Traefik to start..."
sleep 10

kubectl get pods -n traefik
kubectl get svc -n traefik
