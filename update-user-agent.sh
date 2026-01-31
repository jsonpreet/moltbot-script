#!/usr/bin/env bash
# update-user-agent.sh — Patch openclaw src with 'antigravity/1.15.8' User-Agent and restart gateway
# Usage: sudo ./update-user-agent.sh

set -e

# Detect user (default to openclaw if running as root/someone else)
OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
CURRENT_USER="$(whoami)"

echo "[update-user-agent] Starting patch for User-Agent..."

# 1. Determine where openclaw is installed.
# We check the global install for the 'openclaw' user first, then system-wide.
OPENCLAW_PATH=""

# Check if we can find the home dir of the openclaw user
if id "$OPENCLAW_USER" &>/dev/null; then
    OPENCLAW_HOME="$(eval echo ~$OPENCLAW_USER)"
    USER_INSTALL_PATH="$OPENCLAW_HOME/.npm-global/lib/node_modules/openclaw"
    if [[ -d "$USER_INSTALL_PATH" ]]; then
        OPENCLAW_PATH="$USER_INSTALL_PATH"
        echo "[update-user-agent] Found OpenClaw in user global: $OPENCLAW_PATH"
    fi
fi

# Fallback to system-wide if not found
if [[ -z "$OPENCLAW_PATH" ]]; then
    if [[ -d "/usr/lib/node_modules/openclaw" ]]; then
        OPENCLAW_PATH="/usr/lib/node_modules/openclaw"
        echo "[update-user-agent] Found OpenClaw in system global: $OPENCLAW_PATH"
    fi
fi

if [[ -z "$OPENCLAW_PATH" ]]; then
    echo "[update-user-agent] ERROR: Could not find 'openclaw' directory."
    echo "  Checked: ~${OPENCLAW_USER}/.npm-global/lib/node_modules/openclaw"
    echo "  Checked: /usr/lib/node_modules/openclaw"
    exit 1
fi

# 2. Apply patches using sed
# We use sudo if we notice we aren't the owner, or just assume we have permissions if ran with sudo.

echo "[update-user-agent] Patching files in $OPENCLAW_PATH ..."

# Use find + sed to replace the generic User-Agent with the antigravity one
# This command finds all .js files in the OpenClaw dir and replaces strict matches
find "$OPENCLAW_PATH" -type f -name "*.js" -exec sed -i 's/"User-Agent": "antigravity"/"User-Agent": "antigravity\/1.15.8 linux\/amd64"/g' {} +

# This command replaces the google-api-nodejs-client string
find "$OPENCLAW_PATH" -type f -name "*.js" -exec sed -i 's/"User-Agent": "google-api-nodejs-client\/[^"]*"/"User-Agent": "antigravity\/1.15.8 linux\/amd64"/g' {} +

echo "[update-user-agent] Patches applied successfully."

# 3. Restart the service
# We need to determine if it's a system service or a user service.

SERVICE_NAME="openclaw-gateway"
SYSTEM_SERVICE="/etc/systemd/system/${SERVICE_NAME}.service"

if [[ -f "$SYSTEM_SERVICE" ]]; then
    echo "[update-user-agent] Restarting system service: $SERVICE_NAME"
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl restart "$SERVICE_NAME"
        echo "[update-user-agent] Service restarted."
    else
         echo "[update-user-agent] Service was not running, starting it..."
         systemctl start "$SERVICE_NAME"
         echo "[update-user-agent] Service started."
    fi
else
    # Check for user service
    echo "[update-user-agent] System service not found at $SYSTEM_SERVICE."
    echo "[update-user-agent] Checking for user service for user: $OPENCLAW_USER"
    
    # We can try to restart the user service using runuser or su
    # This assumes we are root
    if [[ "$CURRENT_USER" == "root" ]]; then
        if id "$OPENCLAW_USER" &>/dev/null; then
             runuser -l "$OPENCLAW_USER" -c "systemctl --user restart openclaw-gateway" && echo "[update-user-agent] User service restarted." || echo "[update-user-agent] Failed to restart user service (maybe it's not running or env issues)."
        else
            echo "[update-user-agent] User $OPENCLAW_USER does not exist."
        fi
    else
        # If we are the user, just try
        systemctl --user restart openclaw-gateway && echo "[update-user-agent] User service restarted." || true
    fi
fi

echo "[update-user-agent] Done."
