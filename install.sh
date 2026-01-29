#!/usr/bin/env bash
# install.sh — Single-script VPS install for Moltbot (https://docs.molt.bot/)
# Runs full moltbot onboard wizard; then locks down gateway to loopback + optional firewall/fail2ban.
# Directories per Moltbot docs: ~/.clawdbot (config/state), ~/clawd (workspace). Default run user: moltbot.
# Requires: run as root (root access required for user creation, apt, Node install).
# Usage: curl -fsSL https://raw.githubusercontent.com/.../install.sh | sudo bash
#        sudo bash install.sh [--no-fail2ban] [--no-firewall]

set -e

# --- Options ---
NO_FAIL2BAN=false
NO_FIREWALL=false
RUN_USER=""
# Default run user (Moltbot docs use ~/.clawdbot and CLAWDBOT_* env; user name is our choice)
MOLTBOT_USER="${MOLTBOT_USER:-${CLAWDBOT_USER:-moltbot}}"

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

# Require root so we can create user, install packages, and Node without sudo prompts when re-execing as moltbot user
if [[ "$(id -u)" -ne 0 ]] && [[ -z "${CLAWDBOT_ALREADY_DROPPED:-}" ]]; then
  err "This script must be run as root (e.g. sudo $0). Root is required for user creation, apt, and Node install."
  exit 1
fi

# --- Helpers ---
log() { echo "[moltbot-install] $*"; }
err() { echo "[moltbot-install] ERROR: $*" >&2; }

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
    if ! id -u "$MOLTBOT_USER" &>/dev/null; then
      log "Creating dedicated user: $MOLTBOT_USER"
      useradd --system --create-home --shell /bin/bash "$MOLTBOT_USER" 2>/dev/null || true
      if ! id -u "$MOLTBOT_USER" &>/dev/null; then
        err "Could not create user $MOLTBOT_USER; continuing as root (not recommended)."
        RUN_USER=""
        return
      fi
    fi
    ensure_moltbot_sudoers
    RUN_USER="$MOLTBOT_USER"
    export CLAWDBOT_RUN_AS_USER="$RUN_USER"
  else
    RUN_USER=""
  fi
}

# Allow moltbot user to run apt-get, ufw, systemctl (for install script when re-exec'd as that user)
ensure_moltbot_sudoers() {
  local sudoers_file="/etc/sudoers.d/99-moltbot-install"
  [[ -f "$sudoers_file" ]] && return 0
  log "Allowing $MOLTBOT_USER to run apt-get, ufw, systemctl (for install)"
  # NOPASSWD only for the commands the install script needs
  printf '%s ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/sbin/apt-get, /usr/sbin/ufw, /usr/bin/systemctl\n' "$MOLTBOT_USER" > "$sudoers_file"
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
run_as_moltbot() {
  if [[ -n "$RUN_USER" ]]; then
    su - "$RUN_USER" -c "HOME=~$RUN_USER $*"
  else
    eval "$*"
  fi
}

# Get home directory for the user we're running the gateway as
get_moltbot_home() {
  if [[ -n "$RUN_USER" ]]; then
    eval "echo ~$RUN_USER"
  else
    echo "$HOME"
  fi
}

# --- Main (when not re-execing as moltbot user) ---
do_install() {
  local os id_node
  os=$(detect_os)

  log "Detected OS: $os"

  # When running as root, install system deps and Node as root (avoids sudo/TTY issues), then re-exec as moltbot user
  if [[ "$(id -u)" -eq 0 ]] && [[ -z "${CLAWDBOT_ALREADY_DROPPED:-}" ]]; then
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
      export CLAWDBOT_ALREADY_DROPPED=1
      log "Re-running install as user: $RUN_USER"
      exec su - "$RUN_USER" -c "CLAWDBOT_ALREADY_DROPPED=1 bash -s -- $(printf '%q ' "$@")" < "$0"
      exit 0
    fi
  fi

  # Per Moltbot docs: config/state in ~/.clawdbot, workspace in ~/clawd (https://docs.molt.bot/)
  CLAWDBOT_HOME="$(get_moltbot_home)"
  CLAWDBOT_DIR="${CLAWDBOT_HOME}/.clawdbot"
  CLAWD_DIR="${CLAWDBOT_HOME}/clawd"

  # --- Required packages (when not root or re-exec'd; already done above when run as root) ---
  ensure_required_packages "$os"

  # --- Node 22+ (already installed when we were root; here just verify when running as moltbot user) ---
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

  # --- Moltbot CLI ---
  # Ensure PATH includes user npm global bin (molt.bot/install.sh installs to ~/.npm-global/bin)
  export PATH="${HOME}/.npm-global/bin:${HOME}/.local/bin:${PATH}"
  if ! command -v moltbot &>/dev/null; then
    log "Installing Moltbot CLI..."
    # Upstream installer may run doctor at the end; it can fail until config exists — we run onboard next
    ( curl -fsSL https://molt.bot/install.sh | bash -s -- --no-prompt --install-method npm 2>/dev/null ) || \
    ( curl -fsSL https://molt.bot/install.sh | bash -s -- 2>/dev/null ) || true
    export PATH="${HOME}/.npm-global/bin:${HOME}/.local/bin:${PATH}"
    if ! command -v moltbot &>/dev/null; then
      npm install -g moltbot@latest 2>/dev/null || pnpm add -g moltbot@latest 2>/dev/null || {
        err "Could not install moltbot. Try: npm install -g moltbot@latest"
        exit 1
      }
    fi
  fi
  MOLTBOT_BIN="$(command -v moltbot)"
  if [[ -z "$MOLTBOT_BIN" ]]; then
    err "moltbot not found on PATH. Add ~/.npm-global/bin to PATH and re-run."
    exit 1
  fi
  log "Moltbot CLI: $("$MOLTBOT_BIN" --version 2>/dev/null || echo 'installed')"

  # --- Directories ---
  mkdir -p "$CLAWDBOT_DIR" "$CLAWD_DIR"
  chmod 700 "$CLAWDBOT_DIR"

  CONFIG_PATH="${CLAWDBOT_CONFIG_PATH:-$CLAWDBOT_DIR/moltbot.json}"
  export CLAWDBOT_CONFIG_PATH="$CONFIG_PATH"
  export CLAWDBOT_STATE_DIR="$CLAWDBOT_DIR"

  # --- Full Moltbot onboard (interactive wizard) ---
  echo
  log "Running full Moltbot setup. You will choose auth (Z.ai, Anthropic, OpenAI, etc.) and channels (WhatsApp, Telegram, Discord, etc.)."
  echo
  "$MOLTBOT_BIN" onboard --install-daemon
  echo

  # --- VPS lock-down: ensure gateway is loopback-only and has auth ---
  if [[ -f "$CONFIG_PATH" ]] && command -v jq &>/dev/null; then
    log "Applying VPS lock-down to config (loopback bind, discovery off)..."
    TOKEN_EXISTING=$(jq -r '.gateway.auth.token // empty' "$CONFIG_PATH" 2>/dev/null || true)
    if [[ -z "$TOKEN_EXISTING" ]]; then
      GATEWAY_TOKEN=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p)
      echo "$GATEWAY_TOKEN" > "$CLAWDBOT_DIR/gateway-token.txt"
      chmod 600 "$CLAWDBOT_DIR/gateway-token.txt"
      log "Generated gateway token; saved to $CLAWDBOT_DIR/gateway-token.txt"
      jq --arg t "$GATEWAY_TOKEN" '
        .gateway = ((.gateway // {}) + { mode: "local", bind: "loopback", port: 18789, auth: { mode: "token", token: $t } });
        .discovery = ((.discovery // {}) + { mdns: { mode: "off" } })
      ' "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
    else
      jq '
        .gateway = ((.gateway // {}) + { mode: "local", bind: "loopback", port: 18789 });
        .discovery = ((.discovery // {}) + { mdns: { mode: "off" } })
      ' "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
    fi
    chmod 600 "$CONFIG_PATH"
    log "Config patched: gateway bind=loopback, discovery.mdns=off"
  else
    log "Config not found or jq missing; skipping lock-down patch. Ensure gateway.bind=loopback and gateway.auth are set manually."
  fi

  # --- Doctor ---
  export CLAWDBOT_CONFIG_PATH="$CONFIG_PATH"
  export CLAWDBOT_STATE_DIR="$CLAWDBOT_DIR"
  if "$MOLTBOT_BIN" doctor --non-interactive 2>/dev/null; then
    log "moltbot doctor OK"
  else
    "$MOLTBOT_BIN" doctor 2>/dev/null || true
  fi

  # --- Fallback systemd unit if daemon not already installed by wizard ---
  if ! systemctl --user is-enabled moltbot-gateway &>/dev/null && ! systemctl --user is-active moltbot-gateway &>/dev/null 2>/dev/null; then
    SYSTEMD_USER="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    mkdir -p "$SYSTEMD_USER"
    cat > "$SYSTEMD_USER/moltbot-gateway.service" << EOF
[Unit]
Description=Moltbot Gateway
After=network.target

[Service]
Type=simple
Environment=CLAWDBOT_CONFIG_PATH=$CONFIG_PATH
Environment=CLAWDBOT_STATE_DIR=$CLAWDBOT_DIR
ExecStart=$MOLTBOT_BIN gateway --port 18789 --bind loopback
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
    log "Systemd user unit written. Run: systemctl --user daemon-reload && systemctl --user enable --now moltbot-gateway"
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
  echo
  echo "=============================================="
  echo "  Moltbot VPS install complete"
  echo "=============================================="
  echo
  echo "Gateway is bound to 127.0.0.1 only. To use the dashboard from your laptop:"
  echo "  ssh -N -L 18789:127.0.0.1:18789 $(whoami)@<YOUR_VPS_IP>"
  echo "Then open http://127.0.0.1:18789/ and paste your gateway token."
  echo
  if [[ -f "$CLAWDBOT_DIR/gateway-token.txt" ]]; then
    echo "Gateway token: $CLAWDBOT_DIR/gateway-token.txt"
    echo "  cat $CLAWDBOT_DIR/gateway-token.txt"
    echo
  fi
  echo "Pairing is on by default; only approved users can talk to the bot."
  echo "Approve pending pairings: moltbot pairing list <channel>"
  echo "  moltbot pairing approve <channel> <CODE>"
  echo
  echo "Config: $CONFIG_PATH"
  echo "If doctor reported fixable issues: moltbot doctor --fix"
  echo
  echo "Docs: https://docs.molt.bot/"
  echo
}

do_install "$@"
