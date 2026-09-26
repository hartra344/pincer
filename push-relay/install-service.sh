#!/usr/bin/env bash
# Installs the Pincer push relay as a background service that starts at login (macOS launchd) or
# boot (Linux systemd --user), then checks that it answers.
#
#   ./install-service.sh              set up .env if needed, install and start
#   ./install-service.sh --serve      …and publish it over HTTPS with `tailscale serve`
#   ./install-service.sh --print      show the service definition without installing it
#   ./install-service.sh --uninstall  stop and remove the service
set -euo pipefail

cd "$(dirname "$0")"
DIR="$(pwd)"
LABEL=chat.pincer.push-relay
SERVE_PORT="${SERVE_PORT:-8443}"
MODE=install
SERVE=0
for arg in "$@"; do
  case "$arg" in
    --print) MODE=print ;;
    --uninstall) MODE=uninstall ;;
    --serve) SERVE=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 64 ;;
  esac
done

case "$(uname -s)" in
  Darwin)
    PLATFORM=macos
    SERVICE_FILE="$HOME/Library/LaunchAgents/$LABEL.plist"
    LOG="$HOME/Library/Logs/pincer-push-relay.log" ;;
  Linux)
    PLATFORM=linux
    SERVICE_FILE="$HOME/.config/systemd/user/pincer-push-relay.service"
    LOG="journalctl --user -u pincer-push-relay" ;;
  *) echo "Unsupported OS; run 'npm start' under your own process manager." >&2; exit 1 ;;
esac

if [[ "$MODE" == uninstall ]]; then
  if [[ "$PLATFORM" == macos ]]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  else
    systemctl --user disable --now pincer-push-relay 2>/dev/null || true
  fi
  rm -f "$SERVICE_FILE"
  echo "Removed $SERVICE_FILE"
  exit 0
fi

NODE="$(command -v node || true)"
if [[ -z "$NODE" ]] || ! "$NODE" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)'; then
  echo "Node.js 20 or newer is required (https://nodejs.org, or 'brew install node')." >&2
  exit 1
fi

# .env: create it, generate the secret, and check the APNs settings.
if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 600 .env
  echo "Created $DIR/.env"
fi
"$NODE" --input-type=module -e '
  import fs from "node:fs";
  import crypto from "node:crypto";
  const text = fs.readFileSync(".env", "utf8");
  if (/^RELAY_SECRET=[ \t]*$/m.test(text)) {
    fs.writeFileSync(".env", text.replace(/^RELAY_SECRET=[ \t]*$/m, `RELAY_SECRET=${crypto.randomBytes(36).toString("base64url")}`));
    console.log("Generated RELAY_SECRET");
  }
'
read_env() {
  "$NODE" --input-type=module -e "import { loadEnvFile } from './relay.mjs'; process.stdout.write(loadEnvFile('.env')['$1'] ?? '')"
}
MISSING=()
[[ -n "$(read_env APNS_KEY_ID)" ]] || MISSING+=("APNS_KEY_ID: the Key ID of your APNs key")
[[ -n "$(read_env APNS_TEAM_ID)" ]] || MISSING+=("APNS_TEAM_ID: your Apple Developer Team ID")
KEY_FILE="$(read_env APNS_KEY_FILE)"
if [[ -z "$(read_env APNS_KEY)" ]]; then
  if [[ -z "$KEY_FILE" ]]; then
    MISSING+=("APNS_KEY_FILE: path to the downloaded AuthKey_XXXXXXXXXX.p8")
  elif [[ "$KEY_FILE" == /* && ! -f "$KEY_FILE" ]] || [[ "$KEY_FILE" != /* && ! -f "$DIR/$KEY_FILE" ]]; then
    MISSING+=("the .p8 key: $KEY_FILE doesn't exist (copy your AuthKey_XXXXXXXXXX.p8 there, or fix APNS_KEY_FILE)")
  fi
fi
if [[ ${#MISSING[@]} -gt 0 && "$MODE" == install ]]; then
  echo
  echo "Fill in $DIR/.env, then run this again. Missing:"
  printf '  • %s\n' "${MISSING[@]}"
  exit 1
fi
PORT="$(read_env PORT)"
PORT="${PORT:-8787}"

if [[ "$PLATFORM" == macos ]]; then
  DEFINITION="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>$NODE</string><string>$DIR/server.mjs</string></array>
	<key>WorkingDirectory</key><string>$DIR</string>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>StandardOutPath</key><string>$LOG</string>
	<key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>"
else
  DEFINITION="[Unit]
Description=Pincer push relay
After=network-online.target

[Service]
ExecStart=$NODE $DIR/server.mjs
WorkingDirectory=$DIR
Restart=always
RestartSec=5

[Install]
WantedBy=default.target"
fi

if [[ "$MODE" == print ]]; then
  echo "# $SERVICE_FILE"
  echo "$DEFINITION"
  exit 0
fi

mkdir -p "$(dirname "$SERVICE_FILE")"
[[ "$PLATFORM" == macos ]] && mkdir -p "$(dirname "$LOG")"
echo "$DEFINITION" > "$SERVICE_FILE"
if [[ "$PLATFORM" == macos ]]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$SERVICE_FILE"
else
  systemctl --user daemon-reload
  systemctl --user enable pincer-push-relay
  systemctl --user restart pincer-push-relay
fi
echo "Installed $SERVICE_FILE"

OK=0
for _ in $(seq 1 25); do
  if curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then OK=1; break; fi
  sleep 0.2
done
if [[ "$OK" != 1 ]]; then
  echo "The relay didn't answer on http://127.0.0.1:$PORT/healthz. Check the log: $LOG" >&2
  exit 1
fi
echo "Relay is running on http://127.0.0.1:$PORT (log: $LOG)"
if [[ "$PLATFORM" == linux ]]; then
  echo "To keep it running while you're logged out: sudo loginctl enable-linger $USER"
fi

# HTTPS: the Gateway only accepts https:// push endpoints.
TAILSCALE="$(command -v tailscale || true)"
if [[ -z "$TAILSCALE" && -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
  TAILSCALE=/Applications/Tailscale.app/Contents/MacOS/Tailscale
fi
echo
if [[ -z "$TAILSCALE" ]]; then
  echo "Next: put HTTPS in front of http://127.0.0.1:$PORT (see README.md), then enter that URL in Pincer."
  exit 0
fi
if [[ "$SERVE" == 1 ]]; then
  "$TAILSCALE" serve --bg --https="$SERVE_PORT" "http://127.0.0.1:$PORT"
else
  echo "Next: publish it over HTTPS on your tailnet (or run this script again with --serve):"
  echo "  \"$TAILSCALE\" serve --bg --https=$SERVE_PORT http://127.0.0.1:$PORT"
  echo
fi
TS_NAME="$("$TAILSCALE" status --json 2>/dev/null | "$NODE" -e '
  let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
    try { process.stdout.write(JSON.parse(s).Self.DNSName.replace(/\.$/, "")); } catch {}
  })' || true)"
if [[ -n "$TS_NAME" ]]; then
  echo "Then, in Pincer on iOS, go to Settings → Notifications → Push relay and enter:"
  echo "  https://$TS_NAME:$SERVE_PORT"
fi
