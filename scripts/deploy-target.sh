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
ssh -p "$SSH_PORT" -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no "$TARGET_USER@$TARGET_HOST" << EOF
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
    
    echo "[INFO] Fixing Docker credential store for non-interactive SSH session..."
    # Windows Docker Desktop uses 'wincred' which requires an active Windows logon session.
    # When deploying via SSH (no interactive session), the credential helper fails.
    # Override the credsStore to use plain file-based storage for this deployment.
    DOCKER_CONFIG_DIR="$HOME/.docker"
    mkdir -p "$DOCKER_CONFIG_DIR"
    if [ -f "$DOCKER_CONFIG_DIR/config.json" ]; then
        # Remove credsStore entry so Docker falls back to file-based auth
        powershell -Command "
            \$cfg = Get-Content '$DOCKER_CONFIG_DIR/config.json' | ConvertFrom-Json;
            if (\$cfg.PSObject.Properties['credsStore']) {
                \$cfg.PSObject.Properties.Remove('credsStore')
            };
            \$cfg | ConvertTo-Json -Depth 10 | Set-Content '$DOCKER_CONFIG_DIR/config.json'
        " 2>/dev/null || \
        python3 -c "
import json, sys
with open('$DOCKER_CONFIG_DIR/config.json', 'r') as f:
    cfg = json.load(f)
cfg.pop('credsStore', None)
with open('$DOCKER_CONFIG_DIR/config.json', 'w') as f:
    json.dump(cfg, f, indent=2)
" 2>/dev/null || true
    else
        echo '{"auths": {}}' > "$DOCKER_CONFIG_DIR/config.json"
    fi

    echo "[INFO] Building and starting containers via Docker Compose..."
    docker compose down --remove-orphans || docker-compose down --remove-orphans || true
    docker compose up --build -d || docker-compose up --build -d
    
    echo "[INFO] Waiting for containers to initialize..."
    sleep 15
    
    echo "[INFO] Verifying container status..."
    # Use docker compose ps to check only THIS project's containers
    RUNNING=$(docker compose ps --status running --quiet 2>/dev/null | wc -l || docker-compose ps -q 2>/dev/null | wc -l)
    if [ "$RUNNING" -lt 1 ]; then
        echo "[ERROR] One or more containers failed to start!"
        docker compose ps -a 2>/dev/null || docker-compose ps -a 2>/dev/null || docker ps -a
        exit 1
    fi
    
    echo "[INFO] Container status:"
    docker compose ps 2>/dev/null || docker-compose ps 2>/dev/null
    
    echo "[SUCCESS] Active-Active OpenVPN cluster deployed successfully on target!"
EOF
