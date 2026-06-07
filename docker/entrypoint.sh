#!/bin/bash
set -e

echo "[INFO] Starting OpenVPN container initialization..."

# 1. Ensure TUN device node exists
if [ ! -c /dev/net/tun ]; then
    echo "[INFO] Creating TUN device node..."
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

# 2. Enable IP forwarding (required to route client traffic to external networks)
# Gracefully handle write errors if running without privilege to modify sysctl directly
echo "[INFO] Checking IP forwarding status..."
if ! sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
    echo "[WARNING] Unable to configure sysctl net.ipv4.ip_forward. Ensuring host has it enabled."
    # Fallback check
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" -ne 1 ]; then
        echo "[ERROR] IP forwarding is disabled on the host/container and cannot be enabled."
        exit 1
    fi
fi

# 3. Configure SNAT (Masquerade) for return routing
# We apply MASQUERADE to all traffic originating from the client VPN supernet (10.8.0.0/16)
# to ensure servers in the internal network reply back to this node's IP address.
echo "[INFO] Configuring iptables SNAT rules..."
iptables -t nat -C POSTROUTING -s 10.8.0.0/16 -o eth0 -j MASQUERADE >/dev/null 2>&1 || \
iptables -t nat -A POSTROUTING -s 10.8.0.0/16 -o eth0 -j MASQUERADE

# 4. Start OpenVPN using the provided configuration
# We use exec to replace the shell process, preserving PID 1 for correct signal handling (SIGTERM)
if [ -z "$1" ]; then
    echo "[ERROR] No configuration file specified. Usage: entrypoint.sh /etc/openvpn/server.conf"
    exit 1
fi

echo "[INFO] Handing control over to OpenVPN with configuration: $1"
exec openvpn --config "$1"
