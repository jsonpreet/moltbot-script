#!/usr/bin/env bash
# always-openclaw.sh — Enable OpenClaw gateway as a systemd service (runs on boot, survives reboot)
# Run as root after reinstall.sh has completed (e.g. sudo ./always-openclaw.sh)
# OpenClaw: https://github.com/openclaw/openclaw

set -e

OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
OPENCLAW_HOME="$(eval echo ~$OPENCLAW_USER)"
CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$OPENCLAW_HOME/.openclaw/openclaw.json}"
OPENCLAW_BIN="$OPENCLAW_HOME/.npm-global/bin/openclaw"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

if [[ ! -x "$OPENCLAW_BIN" ]]; then
  echo "OpenClaw binary not found at $OPENCLAW_BIN. Run reinstall.sh first as root."
  exit 1
fi

echo "[always-openclaw] Installing systemd service for OpenClaw gateway (user: $OPENCLAW_USER)"
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
ExecStart=$OPENCLAW_BIN gateway --port 18789
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable openclaw-gateway
systemctl start openclaw-gateway

echo "[always-openclaw] OpenClaw gateway is enabled and started."
echo "  status: systemctl status openclaw-gateway"
echo "  logs:   journalctl -u openclaw-gateway -f"
echo "  stop:   systemctl stop openclaw-gateway"
echo "  start:  systemctl start openclaw-gateway"
