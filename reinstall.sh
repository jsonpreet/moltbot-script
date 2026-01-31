#!/usr/bin/env bash
# reinstall.sh — Full VPS reinstall using OpenClaw (https://github.com/openclaw/openclaw)
# Runs openclaw onboard wizard; locks gateway to loopback; optional firewall/fail2ban.
# Directories per OpenClaw: ~/.openclaw (config/state), ~/.openclaw/workspace. Default run user: openclaw.
# Requires: run as root.
# Usage: sudo bash reinstall.sh [--no-fail2ban] [--no-firewall]

set -e

NO_FAIL2BAN=false
NO_FIREWALL=false
RUN_USER=""
OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"

for arg in "$@"; do
  case "$arg" in
    --no-fail2ban)  NO_FAIL2BAN=true ;;
    --no-firewall)  NO_FIREWALL=true ;;
    --help|-h)
      echo "Usage: $0 [--no-fail2ban] [--no-firewall]"
      echo "  --no-fail2ban   Skip fail2ban install (SSH jail)"
      echo "  --no-firewall   Skip ufw firewall setup"
      echo ""
      echo "Must be run as root (e.g. sudo $0). Full reinstall with OpenClaw."
      exit 0
      ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]] && [[ -z "${OPENCLAW_ALREADY_DROPPED:-}" ]]; then
  echo "[openclaw-install] ERROR: This script must be run as root (e.g. sudo $0)."
  exit 1
fi

log() { echo "[openclaw-install] $*"; }
err() { echo "[openclaw-install] ERROR: $*" >&2; }

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    echo "${ID:-unknown}"
  else
    echo "unknown"
  fi
}

ensure_run_user() {
  if [[ "$(id -u)" -eq 0 ]]; then
    if ! id -u "$OPENCLAW_USER" &>/dev/null; then
      log "Creating dedicated user: $OPENCLAW_USER"
      useradd --system --create-home --shell /bin/bash "$OPENCLAW_USER" 2>/dev/null || true
      if ! id -u "$OPENCLAW_USER" &>/dev/null; then
        err "Could not create user $OPENCLAW_USER; continuing as root (not recommended)."
        RUN_USER=""
        return
      fi
    fi
    local sudoers_file="/etc/sudoers.d/99-openclaw-install"
    [[ -f "$sudoers_file" ]] || {
      log "Allowing $OPENCLAW_USER to run apt-get, ufw, systemctl (for install)"
      printf '%s ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/sbin/apt-get, /usr/sbin/ufw, /usr/bin/systemctl\n' "$OPENCLAW_USER" > "$sudoers_file"
      chmod 0440 "$sudoers_file"
      command -v visudo &>/dev/null && visudo -c -f "$sudoers_file" &>/dev/null || { rm -f "$sudoers_file"; err "sudoers check failed"; }
    }
    RUN_USER="$OPENCLAW_USER"
  else
    RUN_USER=""
  fi
}

ensure_required_packages() {
  local os="$1"
  if [[ "$os" != "debian" && "$os" != "ubuntu" ]]; then
    command -v curl &>/dev/null || { err "curl required."; exit 1; }
    command -v jq &>/dev/null || { err "jq required."; exit 1; }
    return 0
  fi
  local need_install=false
  for cmd in curl jq; do command -v "$cmd" &>/dev/null || need_install=true; done
  [[ "$need_install" != true ]] && return 0
  log "Installing required packages (curl, ca-certificates, jq, gnupg)..."
  if [[ "$(id -u)" -eq 0 ]]; then
    apt-get update -qq && apt-get install -y curl ca-certificates jq gnupg
  else
    sudo apt-get update -qq && sudo apt-get install -y curl ca-certificates jq gnupg
  fi
}

get_openclaw_home() {
  if [[ -n "$RUN_USER" ]]; then
    eval "echo ~$RUN_USER"
  else
    echo "$HOME"
  fi
}

# Patch User-Agent strings in OpenClaw source to fix "outdated" Antigravity warning
patch_openclaw_user_agent() {
  log "Patching OpenClaw User-Agent to fix Google OAuth outdated warning..."
  local install_path=""
  # Try user global first (most common for this script)
  if [[ -d "${HOME}/.npm-global/lib/node_modules/openclaw" ]]; then
    install_path="${HOME}/.npm-global/lib/node_modules/openclaw"
  elif [[ -d "/usr/lib/node_modules/openclaw" ]]; then
    install_path="/usr/lib/node_modules/openclaw"
  elif [[ -d "/usr/local/lib/node_modules/openclaw" ]]; then
     install_path="/usr/local/lib/node_modules/openclaw"
  else
    # Try to find via npm list
    install_path="$(npm root -g 2>/dev/null)/openclaw"
  fi

  if [[ -z "$install_path" || ! -d "$install_path" ]]; then
     log "Could not find OpenClaw install path for patching. Skipping."
     return
  fi

  log "Found OpenClaw at: $install_path"
  if command -v find &>/dev/null && command -v sed &>/dev/null; then
      # Fix specific old version strings that cause "outdated" warning
      find "$install_path" -type f -name "*.js" -exec sed -i 's/antigravity\/1\.[0-9]*\.[0-9]*/antigravity\/1.15.8/g' {} + 2>/dev/null || true
      
      # General patch for "User-Agent": "antigravity"
      find "$install_path" -type f -name "*.js" -exec sed -i 's/"User-Agent": "antigravity"/"User-Agent": "antigravity\/1.15.8 linux\/amd64"/g' {} + 2>/dev/null || true
      
      log "User-Agent patched (antigravity/1.15.8 applied)."
  else
      log "find or sed not found. Skipping patch."
  fi
  
  # Restart service if running (user or system)
  if systemctl --user is-active openclaw-gateway &>/dev/null; then
     systemctl --user restart openclaw-gateway && log "Restarted openclaw-gateway (user)"
  elif systemctl is-active openclaw-gateway &>/dev/null; then
     sudo systemctl restart openclaw-gateway 2>/dev/null && log "Restarted openclaw-gateway (system)"
  fi
}

do_install() {
  local os id_node
  os=$(detect_os)
  log "Detected OS: $os"

  # Root: install deps, Node, create user, re-exec as openclaw
  if [[ "$(id -u)" -eq 0 ]] && [[ -z "${OPENCLAW_ALREADY_DROPPED:-}" ]]; then
    # Stop existing openclaw gateway if running (free port 18789)
    systemctl stop openclaw-gateway 2>/dev/null || true
    systemctl stop clawdbot-gateway 2>/dev/null || true
    ensure_required_packages "$os"
    if ! command -v node &>/dev/null; then
      log "Node.js not found; installing Node 22 via NodeSource (as root)..."
      if [[ "$os" =~ ^(debian|ubuntu)$ ]]; then
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash -s
        apt-get install -y nodejs
      else
        err "Unsupported OS for auto Node install. Install Node >= 22 and re-run."
        exit 1
      fi
    fi
    id_node=$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)
    if [[ "${id_node:-0}" -lt 22 ]]; then
      err "Node 22+ required (found: $(node -v)). Install Node 22+ and re-run."
      exit 1
    fi
    ensure_run_user
    if [[ -n "$RUN_USER" ]]; then
      INSTALL_SCRIPT="/tmp/openclaw-reinstall-$$.sh"
      cp "$0" "$INSTALL_SCRIPT" && chmod 755 "$INSTALL_SCRIPT" || { err "Could not copy script to $INSTALL_SCRIPT"; exit 1; }
      export OPENCLAW_ALREADY_DROPPED=1
      log "Re-running install as user: $RUN_USER (interactive wizard will run next)"
      exec su - "$RUN_USER" -c "OPENCLAW_ALREADY_DROPPED=1 OPENCLAW_INSTALL_SCRIPT=$INSTALL_SCRIPT bash $INSTALL_SCRIPT $(printf '%q ' "$@")"
      exit 0
    fi
  fi

  OPENCLAW_HOME="$(get_openclaw_home)"
  OPENCLAW_DIR="${OPENCLAW_HOME}/.openclaw"
  OPENCLAW_WORKSPACE="${OPENCLAW_HOME}/.openclaw/workspace"

  ensure_required_packages "$os"
  if ! command -v node &>/dev/null; then
    err "Node.js not found. Run this script as root so it can install Node 22."
    exit 1
  fi
  id_node=$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)
  if [[ "${id_node:-0}" -lt 22 ]]; then
    err "Node 22+ required (found: $(node -v)). Run this script as root to install Node 22."
    exit 1
  fi
  log "Node $(node -v) OK"

  if ! command -v jq &>/dev/null; then
    err "jq required for config generation. Install jq and re-run."
    exit 1
  fi

  # --- OpenClaw CLI (https://github.com/openclaw/openclaw) ---
  export PATH="${HOME}/.npm-global/bin:${HOME}/.local/bin:${PATH}"
  log "Checking for existing OpenClaw installation..."
  if command -v openclaw &>/dev/null; then
    log "Removing existing OpenClaw..."
    openclaw uninstall --all --yes 2>/dev/null || openclaw uninstall --yes 2>/dev/null || true
  fi
  npm uninstall -g openclaw 2>/dev/null || true
  rm -f "${HOME}/.npm-global/bin/openclaw" 2>/dev/null || true
  rm -rf "${HOME}/.npm-global/lib/node_modules/openclaw" 2>/dev/null || true
  rm -f "${HOME}/.local/bin/openclaw" 2>/dev/null || true
  rm -rf "${HOME}/.local/lib/node_modules/openclaw" 2>/dev/null || true
  hash -r 2>/dev/null || true

  log "Installing OpenClaw (npm openclaw@latest)..."
  mkdir -p "${HOME}/.npm-global/lib" "${HOME}/.npm-global/bin"
  npm config set prefix "${HOME}/.npm-global" 2>/dev/null || true
  npm install -g openclaw@latest || {
    err "OpenClaw install failed. Try: npm install -g openclaw@latest"
    exit 1
  }
  export PATH="${HOME}/.npm-global/bin:${HOME}/.local/bin:${PATH}"
  hash -r 2>/dev/null || true

  OPENCLAW_BIN=""
  [[ -x "${HOME}/.npm-global/bin/openclaw" ]] && OPENCLAW_BIN="${HOME}/.npm-global/bin/openclaw"
  [[ -z "$OPENCLAW_BIN" ]] && OPENCLAW_BIN="$(command -v openclaw 2>/dev/null)" || true
  if [[ -z "$OPENCLAW_BIN" || ! -x "$OPENCLAW_BIN" ]]; then
    err "openclaw not found after install."
    exit 1
  fi
  log "OpenClaw installed: $OPENCLAW_BIN"
  log "Version: $("$OPENCLAW_BIN" --version 2>/dev/null || echo 'unknown')"

  mkdir -p "$OPENCLAW_DIR" "$OPENCLAW_WORKSPACE"
  chmod 700 "$OPENCLAW_DIR"
  rm -f "$OPENCLAW_DIR/openclaw.json" 2>/dev/null || true

  CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$OPENCLAW_DIR/openclaw.json}"
  export OPENCLAW_CONFIG_PATH="$CONFIG_PATH"
  log "Config will be at: $CONFIG_PATH"

  # Add openclaw to PATH and env in shell profile so `openclaw` works when logging in as this user
  if [[ -f "$HOME/.bashrc" ]]; then
    if ! grep -q '\.npm-global/bin' "$HOME/.bashrc" 2>/dev/null; then
      echo 'export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
      echo "export OPENCLAW_CONFIG_PATH=\"\$HOME/.openclaw/openclaw.json\"" >> "$HOME/.bashrc"
      log "Added openclaw to PATH in ~/.bashrc"
    fi
  fi

  echo
  log "=========================================="
  log "Running OpenClaw setup wizard (interactive)"
  log "You will choose: AI provider, channels (WhatsApp, Telegram, Discord, etc.)"
  log "=========================================="
  echo
  "$OPENCLAW_BIN" onboard --install-daemon || log "Onboard wizard exited with error (you can re-run: openclaw onboard)"
  echo

  # --- VPS lock-down: loopback bind, token auth ---
  if [[ -f "$CONFIG_PATH" ]] && command -v jq &>/dev/null; then
    log "Applying VPS lock-down to config (loopback bind, discovery off)..."
    TOKEN_EXISTING=$(jq -r '.gateway.auth.token // empty' "$CONFIG_PATH" 2>/dev/null || true)
    if [[ -z "$TOKEN_EXISTING" ]]; then
      GATEWAY_TOKEN=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p)
      echo "$GATEWAY_TOKEN" > "$OPENCLAW_DIR/gateway-token.txt"
      chmod 600 "$OPENCLAW_DIR/gateway-token.txt"
      log "Generated gateway token; saved to $OPENCLAW_DIR/gateway-token.txt"
      jq --arg t "$GATEWAY_TOKEN" '
        .gateway = ((.gateway // {}) + { bind: "loopback", port: 18789, auth: { mode: "token", token: $t } }) |
        .discovery = ((.discovery // {}) + { mdns: { mode: "off" } })
      ' "$CONFIG_PATH" > "$CONFIG_PATH.tmp" 2>/dev/null && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH" || true
    else
      jq '
        .gateway = ((.gateway // {}) + { bind: "loopback", port: 18789 }) |
        .discovery = ((.discovery // {}) + { mdns: { mode: "off" } })
      ' "$CONFIG_PATH" > "$CONFIG_PATH.tmp" 2>/dev/null && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH" || true
    fi
    chmod 600 "$CONFIG_PATH"
    log "Config patched: gateway bind=loopback"
  fi

  # --- Patch User-Agent ---
  patch_openclaw_user_agent

  if "$OPENCLAW_BIN" doctor --non-interactive 2>/dev/null; then
    log "openclaw doctor OK"
  else
    "$OPENCLAW_BIN" doctor 2>/dev/null || true
  fi

  # --- Firewall ---
  if [[ "$NO_FIREWALL" != true ]] && command -v ufw &>/dev/null; then
    log "Configuring firewall (ufw)..."
    sudo ufw allow 22/tcp 2>/dev/null || true
    sudo ufw default deny incoming 2>/dev/null || true
    sudo ufw --force enable 2>/dev/null || true
    log "Firewall enabled."
  fi

  # --- fail2ban ---
  if [[ "$NO_FAIL2BAN" != true ]] && [[ "$os" =~ ^(debian|ubuntu)$ ]]; then
    if command -v apt-get &>/dev/null && ! command -v fail2ban-client &>/dev/null; then
      log "Installing fail2ban (sshd jail)..."
      sudo apt-get install -y fail2ban 2>/dev/null || true
      command -v fail2ban-client &>/dev/null && sudo systemctl enable fail2ban 2>/dev/null && sudo systemctl start fail2ban 2>/dev/null && log "fail2ban enabled."
    fi
  fi

  # --- Systemd unit for run on boot ---
  GATEWAY_SERVICE="$OPENCLAW_DIR/openclaw-gateway.service"
  cat > "$GATEWAY_SERVICE" << EOF
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
User=$(whoami)
Group=$(whoami)
Environment="PATH=$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
Environment="OPENCLAW_CONFIG_PATH=$CONFIG_PATH"
ExecStart=$OPENCLAW_BIN gateway --port 18789
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$GATEWAY_SERVICE"
  log "Systemd unit saved to $GATEWAY_SERVICE (install as root to run on boot)"

  VPS_IP=""
  command -v curl &>/dev/null && VPS_IP=$(curl -s --connect-timeout 2 -4 https://ifconfig.me/ip 2>/dev/null || curl -s --connect-timeout 2 -4 https://api.ipify.org 2>/dev/null) || true
  [[ -z "$VPS_IP" ]] && VPS_IP=$(hostname -I 2>/dev/null | awk '{print $1}') || true
  [[ -z "$VPS_IP" || "$VPS_IP" =~ ^127\. ]] && VPS_IP="<YOUR_VPS_IP>"

  echo
  echo "=============================================="
  echo "  OpenClaw VPS install complete"
  echo "=============================================="
  echo
  echo "Gateway: 127.0.0.1:18789. From your laptop, SSH tunnel:"
  echo "  ssh -N -L 18789:127.0.0.1:18789 $(whoami)@$VPS_IP"
  echo "Then open http://127.0.0.1:18789/ and paste your gateway token."
  echo
  [[ -f "$OPENCLAW_DIR/gateway-token.txt" ]] && echo "Gateway token: $OPENCLAW_DIR/gateway-token.txt" && echo
  echo "Pairing: openclaw pairing approve <channel> <CODE>"
  echo "Config: $CONFIG_PATH"
  echo "Docs: https://docs.openclaw.ai/  |  Repo: https://github.com/openclaw/openclaw"
  echo
  echo "To run gateway on boot: as root run  ./always-openclaw.sh"
  echo "Or: sudo cp $GATEWAY_SERVICE /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable openclaw-gateway && sudo systemctl start openclaw-gateway"
  echo

  [[ -n "${OPENCLAW_INSTALL_SCRIPT:-}" && -f "${OPENCLAW_INSTALL_SCRIPT}" ]] && rm -f "${OPENCLAW_INSTALL_SCRIPT}" 2>/dev/null || true
}

do_install "$@"
