#!/bin/bash
# ==========================================================
# Automated Integration Test - OpenVPN Cluster Connectivity
# ==========================================================
set -e

CLIENT_NAME="vpn-client-test"
TEST_PROFILE="tests/test-client.ovpn"

echo "=== Starting Integration Tests ==="

# 1. Initialize local test PKI if certs are missing
if [ ! -f "docker/config/pki/ca.crt" ] || [ ! -f "docker/config/pki/client.crt" ] || [ ! -f "docker/config/pki/client.key" ] || [ ! -f "docker/config/pki/tls-crypt.key" ] || [ ! -f "docker/config/pki/server-node1.crt" ]; then
    echo "[INFO] PKI not fully initialized. Running PKI bootstrap..."
    chmod +x scripts/init-pki.sh
    ./scripts/init-pki.sh
fi

# 2. Build and start the cluster services in the background
echo "[INFO] Cleaning up any conflicting containers and networks..."
docker rm -f haproxy-lb openvpn-node1 openvpn-node2 vpn-frontend "$CLIENT_NAME" >/dev/null 2>&1 || true
docker network rm openvpn-hardened_vpn_network >/dev/null 2>&1 || true

echo "[INFO] Starting Docker Compose cluster..."
docker compose down --remove-orphans >/dev/null 2>&1 || true
docker compose up --build -d

# Ensure services have time to initialize
echo "[INFO] Waiting for nodes to initialize..."
sleep 5

# 3. Compile the test client OVPN profile
echo "[INFO] Compiling test client profile..."
cp docker/config/client.ovpn.template "$TEST_PROFILE"

# Read keys
ca_data=$(cat docker/config/pki/ca.crt)
cert_data=$(cat docker/config/pki/client.crt)
key_data=$(cat docker/config/pki/client.key)
tls_crypt_data=$(cat docker/config/pki/tls-crypt.key)

# Inline replace placeholders
# Note: Using python or sed to replace placeholders. Python is cleaner for multiline variables in cross-platform shells.
python3 -c "
with open('$TEST_PROFILE', 'r') as f:
    content = f.read()

content = content.replace('# CA Cert goes here', \"\"\"$ca_data\"\"\")
content = content.replace('# Client Cert goes here', \"\"\"$cert_data\"\"\")
content = content.replace('# Client Private Key goes here', \"\"\"$key_data\"\"\")
content = content.replace('# tls-crypt key goes here', \"\"\"$tls_crypt_data\"\"\")
# Replace production domains with the docker-network load balancer container name
content = content.replace('vpn.tu-dominio.lat', 'haproxy-lb')

with open('$TEST_PROFILE', 'w') as f:
    f.write(content)
"

# 4. Spawn a temporary Client Container running OpenVPN
echo "[INFO] Spawning client test container..."
docker rm -f "$CLIENT_NAME" >/dev/null 2>&1 || true

# Run our local hardened image and connect to the cluster
docker run -d --name "$CLIENT_NAME" \
  --network openvpn-hardened_vpn_network \
  --cap-add=NET_ADMIN \
  --device /dev/net/tun:/dev/net/tun \
  -v "$(pwd)/$TEST_PROFILE:/etc/openvpn/client.ovpn:ro" \
  openvpn-hardened:latest /etc/openvpn/client.ovpn

echo "[INFO] Establishing VPN connection (waiting 15s)..."
sleep 15

# 5. Run Validation Checks
echo "[INFO] Running connectivity validation..."

# Check if client container is still running
RUNNING=$(docker inspect -f '{{.State.Running}}' "$CLIENT_NAME" 2>/dev/null || echo "false")
if [ "$RUNNING" != "true" ]; then
    echo "[ERROR] Client container crashed! Printing logs:"
    docker logs "$CLIENT_NAME"
    exit 1
fi

# Check if client got a tun0 interface and received a 10.8.x.x IP address
IP_INFO=$(docker exec "$CLIENT_NAME" ip addr show dev tun0 2>/dev/null || echo "")
if [ -z "$IP_INFO" ]; then
    echo "[ERROR] tun0 interface not created on client!"
    echo "=== Client logs ==="
    docker logs "$CLIENT_NAME"
    echo "=== HAProxy logs ==="
    docker logs haproxy-lb 2>/dev/null || true
    echo "=== Node 1 logs ==="
    docker logs openvpn-node1 2>/dev/null || true
    echo "=== Node 2 logs ==="
    docker logs openvpn-node2 2>/dev/null || true
    exit 1
fi

CLIENT_IP=$(echo "$IP_INFO" | grep -oE "inet 10\.8\.[0-9]+\.[0-9]+")
if [ -z "$CLIENT_IP" ]; then
    echo "[ERROR] Client tun0 did not receive a 10.8.x.x IP address!"
    echo "IP Info: $IP_INFO"
    exit 1
else
    echo "[SUCCESS] Client successfully connected and received IP: $CLIENT_IP"
fi

# Verify two-way data tunnel traffic by pinging the VPN gateway
# Since sticky sessions pin the client to one node, we check ping to Node 1 (10.8.1.1) or Node 2 (10.8.2.1)
echo "[INFO] Testing routing and pinging gateway..."
if docker exec "$CLIENT_NAME" ping -c 3 10.8.1.1 >/dev/null 2>&1; then
    echo "[SUCCESS] Client successfully pinged Node 1 gateway (10.8.1.1)"
elif docker exec "$CLIENT_NAME" ping -c 3 10.8.2.1 >/dev/null 2>&1; then
    echo "[SUCCESS] Client successfully pinged Node 2 gateway (10.8.2.1)"
else
    echo "[ERROR] Client failed to ping Node 1 (10.8.1.1) and Node 2 (10.8.2.1) gateways!"
    exit 1
fi

# Clean up
echo "[INFO] Cleaning up test containers..."
docker rm -f "$CLIENT_NAME" >/dev/null 2>&1 || true
docker compose down >/dev/null 2>&1 || true
rm -f "$TEST_PROFILE"

echo "=== [PASSED] Integration tests completed successfully! ==="
exit 0
