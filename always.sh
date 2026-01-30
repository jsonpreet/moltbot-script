#!/usr/bin/env bash
# always.sh — Enable Clawdbot gateway as a systemd service (runs on boot, survives reboot)
# Run as root after install.sh has completed (e.g. sudo ./always.sh)

set -e

MOLTBOT_USER="${MOLTBOT_USER:-moltbot}"
CLAWDBOT_HOME="$(eval echo ~$MOLTBOT_USER)"
CONFIG_PATH="${CLAWDBOT_CONFIG_PATH:-$CLAWDBOT_HOME/.clawdbot/moltbot.json}"
STATE_DIR="${CLAWDBOT_STATE_DIR:-$CLAWDBOT_HOME/.clawdbot}"
# Prefer clawdbot binary (upstream name), fallback to moltbot
CLAWDBOT_BIN=""
for bin in clawdbot moltbot; do
  if [[ -x "$CLAWDBOT_HOME/.npm-global/bin/$bin" ]]; then
    CLAWDBOT_BIN="$CLAWDBOT_HOME/.npm-global/bin/$bin"
    break
  fi
done
[[ -z "$CLAWDBOT_BIN" ]] && CLAWDBOT_BIN="$CLAWDBOT_HOME/.npm-global/bin/clawdbot"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

if [[ ! -x "$CLAWDBOT_BIN" ]]; then
  echo "Clawdbot binary not found at $CLAWDBOT_BIN. Run install.sh first as root."
  exit 1
fi

echo "[always] Installing systemd service for Clawdbot gateway (user: $MOLTBOT_USER)"
cat > /etc/systemd/system/clawdbot-gateway.service << EOF
[Unit]
Description=Clawdbot Gateway
After=network.target

[Service]
Type=simple
User=$MOLTBOT_USER
Group=$MOLTBOT_USER
Environment="PATH=$CLAWDBOT_HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
Environment="CLAWDBOT_CONFIG_PATH=$CONFIG_PATH"
Environment="CLAWDBOT_STATE_DIR=$STATE_DIR"
ExecStart=$CLAWDBOT_BIN gateway
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable clawdbot-gateway
systemctl start clawdbot-gateway

echo "[always] Clawdbot gateway is enabled and started."
echo "  status: systemctl status clawdbot-gateway"
echo "  logs:   journalctl -u clawdbot-gateway -f"
echo "  stop:   systemctl stop clawdbot-gateway"
echo "  start:  systemctl start clawdbot-gateway"
