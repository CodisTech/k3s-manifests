#!/bin/bash
# Install Teleport agent and join cluster
# Usage: scp this script to target node, then run it
set -e

TELEPORT_VERSION="18.7.3"
PROXY_SERVER="teleport.home.example.home:443"
TOKEN="3dcf99f51f92d76f46d811feb2ae2257"
CA_PIN="sha256:77359f7f574d6eb4329c8b015a85f19e98b261af56535f2cebf87cae488033b6"

# Install Teleport
curl https://goteleport.com/static/install.sh | bash -s ${TELEPORT_VERSION}

# Create config
sudo mkdir -p /etc/teleport
sudo tee /etc/teleport.yaml > /dev/null <<CONF
version: v3
teleport:
  nodename: $(hostname)
  join_params:
    token_name: ${TOKEN}
    method: token
  ca_pin: ${CA_PIN}
  proxy_server: ${PROXY_SERVER}
ssh_service:
  enabled: true
  labels:
    env: homelab
auth_service:
  enabled: false
proxy_service:
  enabled: false
CONF

# Add --insecure override (self-signed certs)
sudo mkdir -p /etc/systemd/system/teleport.service.d
sudo tee /etc/systemd/system/teleport.service.d/override.conf > /dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/local/bin/teleport start --config /etc/teleport.yaml --pid-file=/run/teleport.pid --insecure
EOF

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable teleport
sudo systemctl start teleport
sleep 5
sudo journalctl -u teleport --no-pager --since "10 sec ago" | tail -5
echo "Teleport agent started on $(hostname)"
