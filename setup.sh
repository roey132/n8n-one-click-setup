#!/usr/bin/env bash
set -euo pipefail

# =========================
# n8n + Redis + Nginx One-Click Setup for Ubuntu 24.04
# Usage:
#   sudo bash setup.sh [path/to/.env]
# If no .env is given, uses ./.env or falls back to ./.env.example.
# This script copies compose + env into /opt/n8n and runs from there.
# =========================

log()  { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
err()  { echo -e "\033[1;31m[✗] $*\033[0m" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Please run as root: sudo bash $0"
    exit 1
  fi
}

detect_os() {
  . /etc/os-release
  if [[ "${ID}" != "ubuntu" || "${VERSION_ID}" != "24.04" ]]; then
    warn "Script is tested on Ubuntu 24.04. Continuing anyway..."
  fi
  PKG_MGR="apt-get"
}

# Resolve env file precedence: arg > ./ .env > ./.env.example
resolve_env_file() {
  if [[ -n "${1:-}" && -f "$1" ]]; then
    ENV_SRC="$1"
  elif [[ -f ".env" ]]; then
    ENV_SRC=".env"
  elif [[ -f ".env.example" ]]; then
    ENV_SRC=".env.example"
  else
    err "No .env or .env.example found. Please provide one."
    exit 1
  fi
  log "Using env from: $ENV_SRC"
}

# Load env into current shell (exports)
load_env() {
  set -a
  # shellcheck disable=SC1090
  . "$ENV_SRC"
  set +a

  : "${N8N_PORT:=5678}"
  : "${N8N_TAG:=latest}"
  : "${DOMAIN:=}"                 # optional
  : "${USE_LETSENCRYPT:=false}"   # "true" to enable certbot
  : "${NGINX_EMAIL:=}"            # required if USE_LETSENCRYPT=true
  : "${REDIS_PASSWORD:=change-me-strong}"
  : "${WEBHOOK_URL:=http://localhost/}"  # can be updated later
}

install_base() {
  log "Updating apt and installing prerequisites..."
  $PKG_MGR update -y
  DEBIAN_FRONTEND=noninteractive $PKG_MGR install -y \
    ca-certificates curl gnupg lsb-release ufw

  # Docker CE
  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker CE + Compose plugin..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo "$VERSION_CODENAME") stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null
    $PKG_MGR update -y
    DEBIAN_FRONTEND=noninteractive $PKG_MGR install -y \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
  else
    log "Docker already installed."
  fi

  # Nginx
  if ! command -v nginx >/dev/null 2>&1; then
    log "Installing Nginx..."
    DEBIAN_FRONTEND=noninteractive $PKG_MGR install -y nginx
    systemctl enable --now nginx
  else
    log "Nginx already installed."
  fi

  # Certbot if requested
  if [[ "$USE_LETSENCRYPT" == "true" ]]; then
    if [[ -z "${DOMAIN}" || -z "${NGINX_EMAIL}" ]]; then
      warn "USE_LETSENCRYPT=true but DOMAIN/NGINX_EMAIL not set. Skipping TLS."
      USE_LETSENCRYPT="false"
    else
      DEBIAN_FRONTEND=noninteractive $PKG_MGR install -y certbot python3-certbot-nginx
    fi
  fi
}

configure_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "Status: active"; then
      log "Opening UFW for Nginx (HTTP/HTTPS)..."
      ufw allow 'Nginx Full' || true
    fi
  fi
}

stage_compose_stack() {
  APP_DIR="/opt/n8n"
  mkdir -p "$APP_DIR"
  log "Copying compose + env into $APP_DIR"
  cp -f docker-compose.yml "$APP_DIR/docker-compose.yml"

  # Write env
  if [[ "$ENV_SRC" != "$APP_DIR/.env" ]]; then
    cp -f "$ENV_SRC" "$APP_DIR/.env"
  fi

  # Ensure data dirs
  mkdir -p "$APP_DIR/n8n_data" "$APP_DIR/redis_data"

  # Make sure these values exist in /opt/n8n/.env for Compose substitutions
  if ! grep -q '^N8N_TAG=' "$APP_DIR/.env"; then echo "N8N_TAG=$N8N_TAG" >> "$APP_DIR/.env"; fi
  if ! grep -q '^N8N_PORT=' "$APP_DIR/.env"; then echo "N8N_PORT=$N8N_PORT" >> "$APP_DIR/.env"; fi
  if ! grep -q '^REDIS_PASSWORD=' "$APP_DIR/.env"; then echo "REDIS_PASSWORD=$REDIS_PASSWORD" >> "$APP_DIR/.env"; fi
  if ! grep -q '^WEBHOOK_URL=' "$APP_DIR/.env"; then echo "WEBHOOK_URL=$WEBHOOK_URL" >> "$APP_DIR/.env"; fi
}

deploy_compose() {
  log "Starting n8n + Redis via Docker Compose..."
  (cd /opt/n8n && docker compose pull && docker compose up -d)
}

configure_nginx() {
  local avail="/etc/nginx/sites-available/n8n.conf"
  local enable="/etc/nginx/sites-enabled/n8n.conf"

  log "Installing Nginx site config..."
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  # Render template
  sed -e "s/{{DOMAIN}}/${DOMAIN:-_}/g" \
      -e "s/{{N8N_PORT}}/${N8N_PORT}/g" \
      nginx/n8n.conf.template > "$avail"

  ln -sf "$avail" "$enable"
  # Remove default site if present
  [[ -f /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default

  nginx -t
  systemctl reload nginx

  if [[ "$USE_LETSENCRYPT" == "true" ]]; then
    log "Requesting Let's Encrypt certificate for ${DOMAIN}..."
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$NGINX_EMAIL" --redirect || {
      warn "Certbot failed; keeping HTTP only."
    }
  fi
}

install_systemd_unit() {
  local unit="/etc/systemd/system/n8n-compose.service"
  log "Creating systemd unit to ensure stack starts on boot..."
  cat > "$unit" <<'UNIT'
[Unit]
Description=n8n + Redis via Docker Compose
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=/opt/n8n
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
RemainAfterExit=yes
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable n8n-compose.service
  systemctl start n8n-compose.service || true
}

summary() {
  echo
  log "Setup complete!"
  echo "n8n URL: http${USE_LETSENCRYPT:+s}://${DOMAIN:-<server-ip>}/"
  echo "Compose dir: /opt/n8n"
  echo "View logs:   cd /opt/n8n && docker compose logs -f"
}

main() {
  require_root
  detect_os
  resolve_env_file "${1:-}"
  load_env
  install_base
  configure_firewall
  stage_compose_stack
  deploy_compose
  configure_nginx
  install_systemd_unit
  summary
}

main "$@"
