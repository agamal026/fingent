#!/usr/bin/env bash
# =============================================================================
# Finance Department Full Automation Sandbox — VPS Setup Script
# Tested on: Ubuntu 22.04 LTS / Debian 12
# Usage: bash scripts/setup.sh
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Validate environment
# -----------------------------------------------------------------------------
[[ $EUID -eq 0 ]] && die "Do not run as root. Use a non-root user with sudo privileges."
command -v curl  >/dev/null 2>&1 || die "curl is required but not installed."
command -v sudo  >/dev/null 2>&1 || die "sudo is required but not installed."

# -----------------------------------------------------------------------------
# 2. Install Node.js 24 via NodeSource
# -----------------------------------------------------------------------------
log "Installing Node.js 24..."
if ! command -v node >/dev/null 2>&1 || [[ "$(node --version | cut -d. -f1 | tr -d 'v')" -lt 24 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
  sudo apt-get install -y nodejs
  log "Node.js $(node --version) installed."
else
  log "Node.js $(node --version) already satisfies requirement (>=24)."
fi

# -----------------------------------------------------------------------------
# 3. Install Docker Engine
# -----------------------------------------------------------------------------
log "Installing Docker Engine..."
if ! command -v docker >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates gnupg lsb-release
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo usermod -aG docker "$USER"
  log "Docker installed. NOTE: Log out and back in for group membership to take effect."
else
  log "Docker $(docker --version) already installed."
fi

# -----------------------------------------------------------------------------
# 4. Install OpenClaw Gateway
# -----------------------------------------------------------------------------
log "Installing OpenClaw Gateway..."
if ! command -v openclaw >/dev/null 2>&1; then
  npm install -g openclaw@latest
  log "OpenClaw $(openclaw --version) installed."
else
  log "OpenClaw $(openclaw --version) already installed."
fi

# -----------------------------------------------------------------------------
# 5. Install DataSynth
# -----------------------------------------------------------------------------
log "Installing DataSynth..."
if ! command -v datasynth-data >/dev/null 2>&1; then
  # DataSynth is a Rust CLI distributed as a pre-built binary
  DATASYNTH_VERSION="1.0.0"
  DATASYNTH_URL="https://github.com/datasynth-rs/datasynth/releases/download/v${DATASYNTH_VERSION}/datasynth-x86_64-unknown-linux-musl.tar.gz"
  curl -fsSL "$DATASYNTH_URL" -o /tmp/datasynth.tar.gz
  tar -xzf /tmp/datasynth.tar.gz -C /tmp
  sudo mv /tmp/datasynth-data /usr/local/bin/datasynth-data
  sudo chmod +x /usr/local/bin/datasynth-data
  rm -f /tmp/datasynth.tar.gz
  log "DataSynth $(datasynth-data --version) installed."
else
  log "DataSynth $(datasynth-data --version) already installed."
fi

# -----------------------------------------------------------------------------
# 6. Configure OpenClaw directory structure
# -----------------------------------------------------------------------------
log "Setting up OpenClaw directory structure..."
mkdir -p \
  "${REPO_DIR}/inbox/invoices" \
  "${REPO_DIR}/archive/posted" \
  "${REPO_DIR}/archive/duplicates" \
  "${REPO_DIR}/archive/errors" \
  "${REPO_DIR}/processing" \
  "${REPO_DIR}/reports" \
  "${REPO_DIR}/logs" \
  "${REPO_DIR}/data"

# Create .gitkeep placeholders so empty directories are tracked
touch \
  "${REPO_DIR}/inbox/invoices/.gitkeep" \
  "${REPO_DIR}/archive/posted/.gitkeep" \
  "${REPO_DIR}/archive/duplicates/.gitkeep" \
  "${REPO_DIR}/archive/errors/.gitkeep" \
  "${REPO_DIR}/processing/.gitkeep" \
  "${REPO_DIR}/reports/.gitkeep" \
  "${REPO_DIR}/data/.gitkeep"

# Copy OpenClaw config to user home
mkdir -p ~/.openclaw/cron
cp "${REPO_DIR}/openclaw.json" ~/.openclaw/openclaw.json
cp "${REPO_DIR}/config/cron/jobs.json" ~/.openclaw/cron/jobs.json
log "OpenClaw configuration deployed to ~/.openclaw/"

# -----------------------------------------------------------------------------
# 7. Build the Docker sandbox image
# -----------------------------------------------------------------------------
log "Building Docker sandbox image (fingent-sandbox:latest)..."
docker build \
  -t fingent-sandbox:latest \
  -f "${REPO_DIR}/docker/Dockerfile" \
  "${REPO_DIR}/docker"
log "Docker sandbox image ready."

# -----------------------------------------------------------------------------
# 8. Register OpenClaw as a systemd service
# -----------------------------------------------------------------------------
log "Registering OpenClaw Gateway as a systemd service..."
OPENCLAW_BIN="$(command -v openclaw)"
cat <<EOF | sudo tee /etc/systemd/system/openclaw.service > /dev/null
[Unit]
Description=OpenClaw Gateway — Finance Automation Sandbox
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=${USER}
WorkingDirectory=${REPO_DIR}
ExecStart=${OPENCLAW_BIN} start --config ${HOME}/.openclaw/openclaw.json
Restart=on-failure
RestartSec=10
Environment="NODE_ENV=production"
EnvironmentFile=-${REPO_DIR}/.env

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable openclaw.service
log "openclaw.service enabled. Start with: sudo systemctl start openclaw"

# -----------------------------------------------------------------------------
# 9. Summary
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Setup complete!"
echo "============================================================"
echo " Node.js:   $(node --version)"
echo " npm:       $(npm --version)"
echo " Docker:    $(docker --version)"
echo " OpenClaw:  deployed to ${HOME}/.openclaw/"
echo ""
echo " Next steps:"
echo "  1. Copy .env.example to .env and fill in secrets"
echo "  2. Run: make validate"
echo "  3. Run: bash scripts/generate-data.sh"
echo "  4. Start the gateway: sudo systemctl start openclaw"
echo "  5. Verify: openclaw status"
echo "============================================================"
