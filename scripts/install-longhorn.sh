#!/bin/bash
# Install Longhorn via Helm

helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --set defaultSettings.defaultDataPath="/var/lib/longhorn" \
  --set defaultSettings.defaultReplicaCount=2

echo "Waiting for Longhorn to start (this takes a few minutes)..."
sleep 30

kubectl get pods -n longhorn-system
kubectl get storageclass
