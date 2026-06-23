#!/bin/bash
# ==========================================================
# Automated Remote Deployment Script (Docker Compose)
# ==========================================================
set -e

# Required Environment Variables check
if [ -z "$TARGET_HOST" ] || [ -z "$TARGET_USER" ] || [ -z "$TARGET_KEY" ]; then
    echo "[ERROR] Missing required environment variables: TARGET_HOST, TARGET_USER, TARGET_KEY"
    echo "Please set them before running this script."
    exit 1
fi

# SSH Port Configuration (default to 22 if not provided)
SSH_PORT=${TARGET_PORT:-22}

DEPLOY_DIR="openvpn-hardened"
SSH_KEY_FILE="/tmp/target_ssh_key"

echo "[INFO] Setting up SSH private key..."
echo "$TARGET_KEY" > "$SSH_KEY_FILE"
chmod 600 "$SSH_KEY_FILE"
trap 'rm -f "$SSH_KEY_FILE"' EXIT

echo "[INFO] Creating deployment archive..."
# Exclude git, local pki files (secrets should be generated/restored securely on target or injected), and temp files
TAR_FILE="deploy.tar.gz"
tar --exclude='docker/config/pki/ca.key' \
    --exclude='docker/config/pki/server-node*.key' \
    --exclude='docker/config/pki/client.key' \
    --exclude='frontend/node_modules' \
    --exclude='frontend/.next' \
    -czf "$TAR_FILE" \
    docker/ \
    haproxy/ \
    docker-compose.yml \
    tests/ \
    scripts/ \
    frontend/

echo "[INFO] Preparing remote directory structure on $TARGET_USER@$TARGET_HOST:$SSH_PORT..."
ssh -p "$SSH_PORT" -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no "$TARGET_USER@$TARGET_HOST" \
    "mkdir -p $DEPLOY_DIR"

echo "[INFO] Uploading deployment package to target server..."
scp -P "$SSH_PORT" -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no "$TAR_FILE" "$TARGET_USER@$TARGET_HOST:$DEPLOY_DIR/"
rm -f "$TAR_FILE"

echo "[INFO] Extracting files and starting containers on target..."
# NOTE: The heredoc delimiter is QUOTED ('EOF') so that NO variable expansion
# happens on the CI runner. Every $VAR below is evaluated on the remote machine.
ssh -p "$SSH_PORT" -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no "$TARGET_USER@$TARGET_HOST" << 'EOF'
set -e
DEPLOY_DIR="openvpn-hardened"
TAR_FILE="deploy.tar.gz"

cd "$DEPLOY_DIR"

echo "[INFO] Extracting release..."
tar -xzf "$TAR_FILE"
rm -f "$TAR_FILE"

# Check if a production PKI exists. If not, generate one for bootstrap/testing.
if [ ! -f "docker/config/pki/ca.crt" ]; then
    echo "[WARNING] No PKI keys found on target. Executing local PKI bootstrap for testing..."
    chmod +x scripts/init-pki.sh
    ./scripts/init-pki.sh
fi

# -------------------------------------------------------------------
# FIX: Docker Desktop on Windows uses 'wincred' as the credential
# store, which requires an active interactive Windows logon session.
# When connecting via SSH there is no such session, so any Docker
# command that touches the registry fails with:
#   "A specified logon session does not exist."
#
# Root-cause fix: override DOCKER_CONFIG to a temporary directory
# containing a minimal config.json with NO credsStore entry.
# Docker then uses anonymous (file-based) auth for all image pulls,
# which works correctly in headless/SSH environments.
#
# All images used in this project are public (alpine, node-alpine,
# haproxy, postgres, svhd/logto) and do not require authentication.
# -------------------------------------------------------------------
echo "[INFO] Configuring Docker for headless SSH session (bypassing wincred)..."
mkdir -p docker_config_headless
printf '{"auths": {}}' > docker_config_headless/config.json
export DOCKER_CONFIG="$(cygpath -m "$(pwd)/docker_config_headless")"
export DOCKER_BUILDKIT=0
export COMPOSE_DOCKER_CLI_BUILD=0
# Clean up the temp config on exit
trap 'rm -rf docker_config_headless' EXIT

echo "[INFO] Building and starting containers via Docker Compose..."
docker compose down --remove-orphans 2>/dev/null || docker-compose down --remove-orphans 2>/dev/null || true
docker compose up --build -d || docker-compose up --build -d

echo "[INFO] Waiting for containers to initialize..."
sleep 15

echo "[INFO] Verifying container status..."
# docker compose ps is scoped to THIS project only — avoids false negatives
# from unrelated containers on the host machine.
RUNNING=$(docker compose ps --status running --quiet 2>/dev/null | wc -l)
FAILED=$(docker compose ps --status exited --status dead --quiet 2>/dev/null | wc -l)

echo "[INFO] Running: $RUNNING | Failed/Exited: $FAILED"
docker compose ps 2>/dev/null || docker-compose ps 2>/dev/null

if [ "$RUNNING" -lt 1 ]; then
    echo "[ERROR] No containers are running. Deployment failed!"
    exit 1
fi

if [ "$FAILED" -gt 0 ]; then
    echo "[ERROR] $FAILED container(s) exited unexpectedly."
    exit 1
fi

echo "[SUCCESS] Active-Active OpenVPN cluster deployed successfully on target!"
EOF
