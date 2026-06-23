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
# Root-cause fix: use --pull=never during docker compose build so the
# build daemon (which runs inside Docker Desktop's Linux VM and does
# NOT inherit environment variables from the SSH host shell) never
# contacts any registry. All base images must be pre-pulled locally.
#
# Additionally we disable BuildKit and isolate DOCKER_CONFIG as a
# belt-and-suspenders measure.
# -------------------------------------------------------------------
echo "[INFO] Configuring Docker for headless SSH session (bypassing wincred)..."
mkdir -p docker_config_headless
printf '{"auths":{},"credsStore":""}' > docker_config_headless/config.json
export DOCKER_CONFIG="$(cygpath -m "$(pwd)/docker_config_headless" 2>/dev/null || echo "$(pwd)/docker_config_headless")"
export DOCKER_BUILDKIT=0
export COMPOSE_DOCKER_CLI_BUILD=0

# Clean up the temp config on exit
trap 'rm -rf docker_config_headless' EXIT

echo "[INFO] Stopping existing containers..."
docker compose down --remove-orphans 2>/dev/null || docker-compose down --remove-orphans 2>/dev/null || true

echo "[INFO] Building images (--no-pull prevents any registry contact)..."
# --no-pull -> use ONLY locally cached base images, never contact the registry
# --no-cache is intentionally NOT used so that layer cache is reused
docker compose build --no-pull || docker-compose build --pull=false

echo "[INFO] Starting containers (no build, images are ready)..."
docker compose up -d --no-build || docker-compose up -d

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
