# moltbot-script

Single-script VPS install for [Moltbot](https://docs.molt.bot/). Runs the **full Moltbot onboard wizard** (auth + channels + daemon), then locks the gateway to loopback-only and optionally enables firewall and fail2ban. Directories follow [Moltbot docs](https://docs.molt.bot/): `~/.clawdbot` (config/state), `~/clawd` (workspace). Default run user: `moltbot`.

## Requirements

- **Linux** — Debian or Ubuntu recommended (Node/jq/ufw/fail2ban auto-install). Other distros: install Node 22+ and jq yourself, then run the script.
- **Node.js 22+** — Installed by the script on Debian/Ubuntu if missing.
- **Root required** — The script must be run as root (e.g. `sudo ./install.sh`). Root is needed to create user `moltbot`, install packages, and install Node; the script then re-runs as `moltbot` for the rest.
- **Interactive terminal** — The script runs `moltbot onboard --install-daemon`; you’ll choose auth (Z.ai, Anthropic, OpenAI, etc.) and channels (WhatsApp, Telegram, Discord, etc.) in the wizard.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_ORG/moltbot-script/main/install.sh | sudo bash
```

Or clone and run (must be root):

```bash
git clone https://github.com/YOUR_ORG/moltbot-script.git
cd moltbot-script
sudo ./install.sh
```

**Full reinstall with OpenClaw** (uses [OpenClaw](https://github.com/openclaw/openclaw) instead of Moltbot):

```bash
sudo ./reinstall.sh
```

Creates user `openclaw`, installs `openclaw@latest` from npm, runs onboard wizard, then run gateway on boot with `./always-openclaw.sh` as root.

## Options

| Flag | Description |
|------|-------------|
| `--no-firewall` | Skip ufw setup (SSH allowed, default deny incoming) |
| `--no-fail2ban` | Skip fail2ban (SSH jail) |
| `--help`, `-h` | Show usage |

**Environment (optional):**

- `MOLTBOT_USER` — User to create and run as when script is run as root (default: `moltbot`). Backward compat: `CLAWDBOT_USER` is also respected.
- `CLAWDBOT_CONFIG_PATH` — Override config path (default: `~/.clawdbot/moltbot.json`). Per [Moltbot docs](https://docs.molt.bot/). Honored during install and in the systemd unit.

## What the script does

1. **User** — If run as root, creates user `moltbot` (or `$MOLTBOT_USER`), adds minimal sudoers so that user can run `apt-get`, `ufw`, and `systemctl` during install, then re-execs the script as that user so the gateway does not run as root.
2. **Required packages** — On Debian/Ubuntu, installs **curl**, **ca-certificates**, **jq**, and **gnupg** first if any are missing (so NodeSource and Moltbot install can run). On other OSes, the script requires curl and jq to be present and exits with instructions if not.
3. **Node 22+** — Installs via NodeSource on Debian/Ubuntu if missing; otherwise checks version and exits if &lt; 22.
4. **jq** — Already installed in step 2 on Debian/Ubuntu; otherwise the script requires it and exits.
5. **Moltbot CLI** — Installs via [molt.bot/install.sh](https://molt.bot/install.sh) or `npm install -g moltbot@latest`.
6. **Directories** — Creates `~/.clawdbot` (mode `700`) and `~/clawd` (per [Moltbot docs](https://docs.molt.bot/)), under the run user’s home.
7. **Onboard wizard** — Runs `moltbot onboard --install-daemon` so you can:
   - Choose local vs remote gateway
   - Set auth (OAuth or API keys: Z.ai, Anthropic, OpenAI, etc.)
   - Configure channels (WhatsApp, Telegram, Discord, etc.)
   - Install the gateway service (launchd/systemd as appropriate)
8. **VPS lock-down** — Patches the generated config with `jq`:
   - `gateway.mode`: `"local"`
   - `gateway.bind`: `"loopback"` (listen only on 127.0.0.1)
   - `gateway.port`: `18789`
   - `gateway.auth.mode`: `"token"` and a token (generated if the wizard didn’t set one; saved to `~/.clawdbot/gateway-token.txt`, mode `600`)
   - `discovery.mdns.mode`: `"off"`
   Config file is then `chmod 600`.
9. **Doctor** — Runs `moltbot doctor` (with `CLAWDBOT_CONFIG_PATH` and `CLAWDBOT_STATE_DIR` set) to validate config.
10. **Systemd fallback** — If the wizard didn’t enable/start a gateway service, writes a user unit at `~/.config/systemd/user/moltbot-gateway.service` (or `$XDG_CONFIG_HOME/systemd/user`) and tells you to `daemon-reload` and `enable --now`.
11. **Firewall** — If ufw is available and `--no-firewall` wasn’t used: allow SSH, default deny incoming, enable ufw.
12. **fail2ban** — On Debian/Ubuntu, if fail2ban isn’t installed and `--no-fail2ban` wasn’t used: install and enable fail2ban (sshd jail).

## Security (VPS lock-down)

- **Gateway** listens only on `127.0.0.1:18789`. No external access to the gateway port.
- **Access** is via SSH tunnel from your machine (see After install).
- **Token auth** is set so the Control UI and API require the gateway token.
- **mDNS discovery** is turned off so the gateway isn’t advertised on the LAN.
- **Pairing** is the default for DMs; only approved users can talk to the bot.
- **Permissions** — `~/.clawdbot` is `700`; config and `gateway-token.txt` are `600`.

## After install

- **Dashboard** — From your laptop, create an SSH tunnel, then open the Control UI:
  ```bash
  ssh -N -L 18789:127.0.0.1:18789 user@YOUR_VPS_IP
  ```
  Open http://127.0.0.1:18789/ and paste your gateway token (from the wizard or `~/.clawdbot/gateway-token.txt` if the script generated it).

- **Config** — `~/.clawdbot/moltbot.json` (or `$CLAWDBOT_CONFIG_PATH`). Edit as needed; see [Moltbot configuration](https://docs.molt.bot/gateway/configuration).

- **Validation** — If `moltbot doctor` reported fixable issues: `moltbot doctor --fix`.

- **Pairing** — Approve pending DMs:
  ```bash
  moltbot pairing list <channel>
  moltbot pairing approve <channel> <CODE>
  ```

- **Gateway on boot (recommended)** — As **root** run from the repo: `./always.sh`. Or: `sudo cp /home/moltbot/.clawdbot/clawdbot-gateway.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable clawdbot-gateway && sudo systemctl start clawdbot-gateway`
- **Gateway service (user unit)** — If you’re using the script’s systemd user unit:
  ```bash
  systemctl --user daemon-reload
  systemctl --user enable --now moltbot-gateway
  ```

## File locations

| Path | Description |
|------|-------------|
| `~/.clawdbot/moltbot.json` | Gateway config (or `$CLAWDBOT_CONFIG_PATH`) |
| `~/.clawdbot/gateway-token.txt` | Gateway token, if generated by script |
| `~/.clawdbot/` | State, credentials, sessions (mode `700`) |
| `~/clawd/` | Default agent workspace |
| `~/.config/systemd/user/moltbot-gateway.service` | User unit, if written by script |

When the script is run as root, all of the above are under the run user’s home (e.g. `/home/moltbot`).

## Docs

- [Moltbot](https://docs.molt.bot/)
- [Getting started](https://docs.molt.bot/start/getting-started)
- [Gateway configuration](https://docs.molt.bot/gateway/configuration)
- [Gateway security](https://docs.molt.bot/gateway/security)
