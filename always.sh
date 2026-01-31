#!/usr/bin/env bash
# always.sh — Enable OpenClaw gateway as a systemd service (runs on boot, survives reboot)
# Run as root after install.sh has completed (e.g. sudo ./always.sh)

set -e

OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
OPENCLAW_HOME="$(eval echo ~$OPENCLAW_USER)"
CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$OPENCLAW_HOME/.openclaw/openclaw.json}"
STATE_DIR="${OPENCLAW_STATE_DIR:-$OPENCLAW_HOME/.openclaw}"
# Prefer openclaw binary
OPENCLAW_BIN=""
for bin in openclaw moltbot clawdbot; do
  if [[ -x "$OPENCLAW_HOME/.npm-global/bin/$bin" ]]; then
    OPENCLAW_BIN="$OPENCLAW_HOME/.npm-global/bin/$bin"
    break
  fi
done
[[ -z "$OPENCLAW_BIN" ]] && OPENCLAW_BIN="$OPENCLAW_HOME/.npm-global/bin/openclaw"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

if [[ ! -x "$OPENCLAW_BIN" ]]; then
  echo "OpenClaw binary not found at $OPENCLAW_BIN. Run install.sh first as root."
  exit 1
fi

echo "[always] Installing systemd service for OpenClaw gateway (user: $OPENCLAW_USER)"
cat > /etc/systemd/system/openclaw-gateway.service << EOF
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
User=$OPENCLAW_USER
Group=$OPENCLAW_USER
Environment="PATH=$OPENCLAW_HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
Environment="OPENCLAW_CONFIG_PATH=$CONFIG_PATH"
Environment="OPENCLAW_STATE_DIR=$STATE_DIR"
ExecStart=$OPENCLAW_BIN gateway
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable openclaw-gateway
systemctl start openclaw-gateway

echo "[always] OpenClaw gateway is enabled and started."
echo "  status: systemctl status openclaw-gateway"
echo "  logs:   journalctl -u openclaw-gateway -f"
echo "  stop:   systemctl stop openclaw-gateway"
echo "  start:  systemctl start openclaw-gateway"
