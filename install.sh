#!/usr/bin/env bash
# install.sh — Single-script VPS install for OpenClaw (https://docs.openclaw.ai/)
# Runs full openclaw onboard wizard; then locks down gateway to loopback + optional firewall/fail2ban.
# Directories per OpenClaw docs: ~/.openclaw (config/state), ~/.openclaw/workspace. Default run user: openclaw.
# Requires: run as root (root access required for user creation, apt, Node install).
# Usage: curl -fsSL https://raw.githubusercontent.com/.../install.sh | sudo bash
#        sudo bash install.sh [--no-fail2ban] [--no-firewall]

set -e

# --- Options ---
NO_FAIL2BAN=false
NO_FIREWALL=false
RUN_USER=""
# Default run user (OpenClaw docs use ~/.openclaw and OPENCLAW_* env; user name is our choice)
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
      echo "Must be run as root (e.g. sudo $0 or as root shell)."
      exit 0
      ;;
  esac
done

# Require root so we can create user, install packages, and Node without sudo prompts when re-execing as openclaw user
if [[ "$(id -u)" -ne 0 ]] && [[ -z "${OPENCLAW_ALREADY_DROPPED:-}" ]]; then
  err "This script must be run as root (e.g. sudo $0). Root is required for user creation, apt, and Node install."
  exit 1
fi

# --- Helpers ---
log() { echo "[openclaw-install] $*"; }
err() { echo "[openclaw-install] ERROR: $*" >&2; }

# Detect Linux (Debian/Ubuntu preferred)
detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    echo "${ID:-unknown}"
  else
    echo "unknown"
  fi
}

# Ensure we have a non-root user for running the gateway (when running as root)
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
    ensure_openclaw_sudoers
    RUN_USER="$OPENCLAW_USER"
    export OPENCLAW_RUN_AS_USER="$RUN_USER"
  else
    RUN_USER=""
  fi
}

# Allow openclaw user to run apt-get, ufw, systemctl (for install script when re-exec'd as that user)
ensure_openclaw_sudoers() {
  local sudoers_file="/etc/sudoers.d/99-openclaw-install"
  [[ -f "$sudoers_file" ]] && return 0
  log "Allowing $OPENCLAW_USER to run apt-get, ufw, systemctl (for install)"
  # NOPASSWD only for the commands the install script needs
  printf '%s ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/sbin/apt-get, /usr/sbin/ufw, /usr/bin/systemctl\n' "$OPENCLAW_USER" > "$sudoers_file"
  chmod 0440 "$sudoers_file"
  if command -v visudo &>/dev/null; then
    visudo -c -f "$sudoers_file" &>/dev/null || { rm -f "$sudoers_file"; err "sudoers check failed; removed $sudoers_file"; }
  fi
}

# Install required packages (curl, ca-certificates, jq, gnupg) on Debian/Ubuntu so script can proceed
ensure_required_packages() {
  local os="$1"
  if [[ "$os" != "debian" && "$os" != "ubuntu" ]]; then
    command -v curl &>/dev/null || { err "curl required. On this OS install curl and re-run."; exit 1; }
    command -v jq &>/dev/null || { err "jq required. On this OS install jq and re-run."; exit 1; }
    return 0
  fi
  local need_install=false
  for cmd in curl jq; do
    command -v "$cmd" &>/dev/null || need_install=true
  done
  if [[ "$need_install" != true ]]; then
    return 0
  fi
  log "Installing required packages (curl, ca-certificates, jq, gnupg)..."
  if [[ "$(id -u)" -eq 0 ]]; then
    apt-get update -qq && apt-get install -y curl ca-certificates jq gnupg
  else
    sudo apt-get update -qq && sudo apt-get install -y curl ca-certificates jq gnupg
  fi
}

# Run a command as the target user (if we created one), otherwise as current user
run_as_openclaw() {
  if [[ -n "$RUN_USER" ]]; then
    su - "$RUN_USER" -c "HOME=~$RUN_USER $*"
  else
    eval "$*"
  fi
}

# Get home directory for the user we're running the gateway as
get_openclaw_home() {
  if [[ -n "$RUN_USER" ]]; then
    eval "echo ~$RUN_USER"
  else
    echo "$HOME"
  fi
}

# Patch User-Agent strings in OpenClaw source to fix Google/OAuth issues
patch_openclaw_user_agent() {
  log "Patching OpenClaw User-Agent to fix Google OAuth..."
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
      find "$install_path" -type f -name "*.js" -exec sed -i 's/"User-Agent": "antigravity"/"User-Agent": "antigravity\/1.15.8 linux\/amd64"/g' {} + 2>/dev/null || true
      find "$install_path" -type f -name "*.js" -exec sed -i 's/"User-Agent": "google-api-nodejs-client\/[^"]*"/"User-Agent": "antigravity\/1.15.8 linux\/amd64"/g' {} + 2>/dev/null || true
      log "User-Agent patched."
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

# --- Main (when not re-execing as openclaw user) ---
do_install() {
  local os id_node
  os=$(detect_os)

  log "Detected OS: $os"

  # When running as root, install system deps and Node as root (avoids sudo/TTY issues), then re-exec as openclaw user
  if [[ "$(id -u)" -eq 0 ]] && [[ -z "${OPENCLAW_ALREADY_DROPPED:-}" ]]; then
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
      # Copy script to /tmp so we can run it without redirecting stdin; then onboard wizard gets a TTY and can prompt
      INSTALL_SCRIPT="/tmp/openclaw-install-$$.sh"
      cp "$0" "$INSTALL_SCRIPT" && chmod 755 "$INSTALL_SCRIPT" || { err "Could not copy script to $INSTALL_SCRIPT"; exit 1; }
      export OPENCLAW_ALREADY_DROPPED=1
      log "Re-running install as user: $RUN_USER (interactive wizard will run next)"
      exec su - "$RUN_USER" -c "OPENCLAW_ALREADY_DROPPED=1 OPENCLAW_INSTALL_SCRIPT=$INSTALL_SCRIPT bash $INSTALL_SCRIPT $(printf '%q ' "$@")"
      exit 0
    fi
  fi

  # Per OpenClaw docs: config/state in ~/.openclaw, workspace in ~/.openclaw/workspace (https://docs.openclaw.ai/)
  OPENCLAW_HOME="$(get_openclaw_home)"
  OPENCLAW_DIR="${OPENCLAW_HOME}/.openclaw"
  CLAWD_DIR="${OPENCLAW_HOME}/.openclaw/workspace"

  # --- Required packages (when not root or re-exec'd; already done above when run as root) ---
  ensure_required_packages "$os"

  # --- Node 22+ (already installed when we were root; here just verify when running as openclaw user) ---
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

  # --- jq (required for config patching; installed above on Debian/Ubuntu) ---
  if ! command -v jq &>/dev/null; then
    err "jq required for config generation. Install jq and re-run."
    exit 1
  fi

  # --- OpenClaw CLI ---
  # Ensure PATH includes user npm global bin (openclaw.ai/install.sh installs to ~/.npm-global/bin)
  export PATH="${HOME}/.npm-global/bin:${HOME}/.local/bin:${PATH}"
  
  # Always remove existing OpenClaw CLI so we do a clean install
  log "Checking for existing OpenClaw installation..."
  # Try uninstall command (works with both openclaw and old command names)
  if command -v openclaw &>/dev/null; then
    log "Removing existing OpenClaw via openclaw uninstall..."
    openclaw uninstall --all --yes 2>/dev/null || openclaw uninstall --yes 2>/dev/null || true
  fi
  if command -v moltbot &>/dev/null; then
    log "Removing existing Moltbot via moltbot uninstall..."
    moltbot uninstall --all --yes 2>/dev/null || moltbot uninstall --yes 2>/dev/null || true
  fi
  if command -v clawdbot &>/dev/null; then
    log "Removing existing Moltbot via clawdbot uninstall..."
    clawdbot uninstall --all --yes 2>/dev/null || clawdbot uninstall --yes 2>/dev/null || true
  fi
  # Remove npm global packages (try both package names)
  npm uninstall -g openclaw 2>/dev/null || true
  npm uninstall -g moltbot 2>/dev/null || true
  npm uninstall -g clawdbot 2>/dev/null || true
  # Remove binaries from common install locations
  rm -f "${HOME}/.npm-global/bin/openclaw" "${HOME}/.npm-global/bin/moltbot" "${HOME}/.npm-global/bin/clawdbot" 2>/dev/null || true
  rm -rf "${HOME}/.npm-global/lib/node_modules/openclaw" "${HOME}/.npm-global/lib/node_modules/moltbot" "${HOME}/.npm-global/lib/node_modules/clawdbot" 2>/dev/null || true
  rm -f "${HOME}/.local/bin/openclaw" "${HOME}/.local/bin/moltbot" "${HOME}/.local/bin/clawdbot" 2>/dev/null || true
  rm -rf "${HOME}/.local/lib/node_modules/openclaw" "${HOME}/.local/lib/node_modules/moltbot" "${HOME}/.local/lib/node_modules/clawdbot" 2>/dev/null || true
  # Clear bash's command cache so it finds the new binary after install
  hash -r 2>/dev/null || true
  
  log "Installing OpenClaw CLI (fresh install)..."
  # First ensure npm global directory exists and is configured
  mkdir -p "${HOME}/.npm-global/lib" "${HOME}/.npm-global/bin"
  npm config set prefix "${HOME}/.npm-global" 2>/dev/null || true
  
  # Use the official OpenClaw installer
  log "Running OpenClaw upstream installer..."
  curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-prompt || log "Installer exited with error (may be OK if binary was installed)"
  
  # Update PATH and clear hash
  export PATH="${HOME}/.npm-global/bin:${HOME}/.local/bin:${PATH}"
  hash -r 2>/dev/null || true
  
  # Find the openclaw binary
  OPENCLAW_BIN=""
  for binname in openclaw moltbot clawdbot; do
    for bindir in "${HOME}/.npm-global/bin" "${HOME}/.local/bin" "/usr/local/bin"; do
      if [[ -x "${bindir}/${binname}" ]]; then
        OPENCLAW_BIN="${bindir}/${binname}"
        break 2
      fi
    done
  done
  # Fallback to command -v
  if [[ -z "$OPENCLAW_BIN" ]]; then
    OPENCLAW_BIN="$(command -v openclaw 2>/dev/null || command -v moltbot 2>/dev/null || command -v clawdbot 2>/dev/null || true)"
  fi
  
  if [[ -z "$OPENCLAW_BIN" || ! -x "$OPENCLAW_BIN" ]]; then
    err "openclaw not found after install. PATH=${PATH}"
    err "Checked directories:"
    ls -la "${HOME}/.npm-global/bin/" 2>/dev/null || echo "  ~/.npm-global/bin/ - not found or empty"
    ls -la "${HOME}/.local/bin/" 2>/dev/null || echo "  ~/.local/bin/ - not found or empty"
    exit 1
  fi
  log "OpenClaw CLI installed: $OPENCLAW_BIN"
  log "Version: $("$OPENCLAW_BIN" --version 2>/dev/null || echo 'unknown')"

  # --- Directories ---
  mkdir -p "$OPENCLAW_DIR" "$CLAWD_DIR"
  chmod 700 "$OPENCLAW_DIR"
  
  # Remove any stale config so wizard runs fresh (old installs may have openclaw.json)
  rm -f "$OPENCLAW_DIR/openclaw.json" "$OPENCLAW_DIR/moltbot.json" "$OPENCLAW_DIR/clawdbot.json" 2>/dev/null || true

  CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$OPENCLAW_DIR/openclaw.json}"
  export OPENCLAW_CONFIG_PATH="$CONFIG_PATH"
  export OPENCLAW_STATE_DIR="$OPENCLAW_DIR"
  log "Config will be at: $CONFIG_PATH"

  # --- Full OpenClaw onboard (interactive wizard) ---
  echo
  log "=========================================="
  log "Running OpenClaw setup wizard (interactive)"
  log "You will choose:"
  log "  - AI provider (antigravity, Z.ai, Anthropic, OpenAI, etc.)"
  log "  - Channels (WhatsApp, Telegram, Discord, etc.)"
  log "=========================================="
  echo
  # Run onboard; if it fails, we continue anyway and let user run it manually later
  "$OPENCLAW_BIN" onboard --install-daemon || log "Onboard wizard exited with error (you can re-run later: openclaw onboard)"
  echo

  # --- VPS lock-down: ensure gateway is loopback-only and has auth ---
  if [[ -f "$CONFIG_PATH" ]] && command -v jq &>/dev/null; then
    log "Applying VPS lock-down to config (loopback bind, discovery off)..."
    TOKEN_EXISTING=$(jq -r '.gateway.auth.token // empty' "$CONFIG_PATH" 2>/dev/null || true)
    if [[ -z "$TOKEN_EXISTING" ]]; then
      GATEWAY_TOKEN=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p)
      echo "$GATEWAY_TOKEN" > "$OPENCLAW_DIR/gateway-token.txt"
      chmod 600 "$OPENCLAW_DIR/gateway-token.txt"
      log "Generated gateway token; saved to $OPENCLAW_DIR/gateway-token.txt"
      jq --arg t "$GATEWAY_TOKEN" '
        .gateway = ((.gateway // {}) + { mode: "local", bind: "loopback", port: 18789, auth: { mode: "token", token: $t } }) |
        .discovery = ((.discovery // {}) + { mdns: { mode: "off" } })
      ' "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
    else
      jq '
        .gateway = ((.gateway // {}) + { mode: "local", bind: "loopback", port: 18789 }) |
        .discovery = ((.discovery // {}) + { mdns: { mode: "off" } })
      ' "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
    fi
    chmod 600 "$CONFIG_PATH"
    log "Config patched: gateway bind=loopback, discovery.mdns=off"
  else
    log "Config not found or jq missing; skipping lock-down patch. Ensure gateway.bind=loopback and gateway.auth are set manually."
  fi

  # --- Patch User-Agent ---
  patch_openclaw_user_agent

  # --- Doctor ---
  export OPENCLAW_CONFIG_PATH="$CONFIG_PATH"
  export OPENCLAW_STATE_DIR="$OPENCLAW_DIR"
  if "$OPENCLAW_BIN" doctor --non-interactive 2>/dev/null; then
    log "openclaw doctor OK"
  else
    "$OPENCLAW_BIN" doctor 2>/dev/null || true
  fi

  # --- Fallback systemd unit if daemon not already installed by wizard ---
  if ! systemctl --user is-enabled openclaw-gateway &>/dev/null && ! systemctl --user is-active openclaw-gateway &>/dev/null 2>/dev/null; then
    SYSTEMD_USER="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    mkdir -p "$SYSTEMD_USER"
    cat > "$SYSTEMD_USER/openclaw-gateway.service" << EOF
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
Environment=OPENCLAW_CONFIG_PATH=$CONFIG_PATH
Environment=OPENCLAW_STATE_DIR=$OPENCLAW_DIR
ExecStart=$OPENCLAW_BIN gateway --port 18789 --bind loopback
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
    log "Systemd user unit written. Run: systemctl --user daemon-reload && systemctl --user enable --now openclaw-gateway"
  fi

  # --- Firewall (current user may need sudo) ---
  if [[ "$NO_FIREWALL" != true ]] && command -v ufw &>/dev/null; then
    log "Configuring firewall (ufw)..."
    sudo ufw allow 22/tcp 2>/dev/null || true
    sudo ufw default deny incoming 2>/dev/null || true
    sudo ufw --force enable 2>/dev/null || true
    log "Firewall enabled. Gateway is only reachable via SSH tunnel."
  elif [[ "$NO_FIREWALL" == true ]]; then
    log "Skipping firewall (--no-firewall)."
  fi

  # --- fail2ban ---
  if [[ "$NO_FAIL2BAN" != true ]] && [[ "$os" =~ ^(debian|ubuntu)$ ]]; then
    if command -v apt-get &>/dev/null && ! command -v fail2ban-client &>/dev/null; then
      log "Installing fail2ban (sshd jail)..."
      sudo apt-get install -y fail2ban 2>/dev/null || true
      if command -v fail2ban-client &>/dev/null; then
        sudo systemctl enable fail2ban 2>/dev/null || true
        sudo systemctl start fail2ban 2>/dev/null || true
        log "fail2ban enabled for SSH."
      fi
    fi
  elif [[ "$NO_FAIL2BAN" == true ]]; then
    log "Skipping fail2ban (--no-fail2ban)."
  fi

  # --- Next steps ---
  # Try to detect VPS public IP for copy-paste SSH command (run from your laptop)
  VPS_IP=""
  if command -v curl &>/dev/null; then
    VPS_IP=$(curl -s --connect-timeout 2 -4 https://ifconfig.me/ip 2>/dev/null || curl -s --connect-timeout 2 -4 https://api.ipify.org 2>/dev/null) || true
  fi
  [[ -z "$VPS_IP" ]] && VPS_IP=$(hostname -I 2>/dev/null | awk '{print $1}') || true
  [[ -z "$VPS_IP" || "$VPS_IP" =~ ^127\. ]] && VPS_IP="<YOUR_VPS_IP>"

  echo
  echo "=============================================="
  echo "  OpenClaw VPS install complete"
  echo "=============================================="
  echo
  echo "Gateway is bound to 127.0.0.1 on this VPS only. From your laptop, create an SSH tunnel:"
  echo "  ssh -N -L 18789:127.0.0.1:18789 $(whoami)@$VPS_IP"
  echo "Then on your laptop open http://127.0.0.1:18789/ and paste your gateway token."
  echo
  if [[ -f "$OPENCLAW_DIR/gateway-token.txt" ]]; then
    echo "Gateway token: $OPENCLAW_DIR/gateway-token.txt"
    echo "  cat $OPENCLAW_DIR/gateway-token.txt"
    echo
  fi
  # Get the command name (openclaw) for instructions
  OPENCLAW_CMD="$(basename "$OPENCLAW_BIN")"
  echo "Pairing is on by default; only approved users can talk to the bot."
  echo "Approve pending pairings: $OPENCLAW_CMD pairing list <channel>"
  echo "  $OPENCLAW_CMD pairing approve <channel> <CODE>"
  echo
  echo "Config: $CONFIG_PATH"
  echo "If doctor reported fixable issues: $OPENCLAW_CMD doctor --fix"
  echo
  echo "Docs: https://docs.openclaw.ai/"
  echo
  # --- Run gateway on boot (systemd) ---
  # Write systemd unit so root can install it (for curl | bash users who don't have always.sh)
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
Environment="OPENCLAW_STATE_DIR=$OPENCLAW_DIR"
ExecStart=$OPENCLAW_BIN gateway
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$GATEWAY_SERVICE"
  log "Systemd unit saved to $GATEWAY_SERVICE (install as root to run on boot)"
  echo
  echo "To run the gateway on boot (survives reboot):"
  echo "  As root run:  ./always.sh   (if you cloned the repo)"
  echo "  Or as root:   cp $GATEWAY_SERVICE /etc/systemd/system/ && systemctl daemon-reload && systemctl enable openclaw-gateway && systemctl start openclaw-gateway"
  echo
  # Remove temp script copy used for re-exec (so onboard had a TTY)
  [[ -n "${OPENCLAW_INSTALL_SCRIPT:-}" && -f "${OPENCLAW_INSTALL_SCRIPT}" ]] && rm -f "${OPENCLAW_INSTALL_SCRIPT}" 2>/dev/null || true
}

do_install "$@"
