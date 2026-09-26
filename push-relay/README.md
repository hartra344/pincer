# Pincer push relay

Pincer on iOS needs this relay to show notifications while it's suspended or closed. It's a small Node server with no dependencies and nothing to store. The easiest place to run it is on the same machine as your OpenClaw Gateway.

## Why it's needed

iOS gives a suspended app no CPU or network, so Pincer can't keep a connection open. Only Apple's push service (APNs) can wake it, and pushes must be sent by a server holding the app team's APNs key. The Gateway sends operator notifications as standard Web Push rather than APNs. The relay turns one into the other:

```
Gateway ──Web Push (encrypted)──▶ relay ──APNs (same bytes)──▶ iPhone ─▶ Pincer decrypts on the device
```

The relay never sees what a notification says. The Gateway encrypts each push to a key that exists only on your phone.

## Setup (about 10 minutes)

You need:
- the machine that runs your Gateway, with Node.js 20 or newer (`node -v`);
- Tailscale on that machine, for HTTPS;
- access to the Apple Developer account that signs Pincer.

### 1. Create an APNs key (once)

At [developer.apple.com → Keys](https://developer.apple.com/account/resources/authkeys/list), click **+**:

| Field | Value |
| --- | --- |
| Key Name | `Pincer Push Relay` |
| Apple Push Notifications service (APNs) | ✅ → **Configure** |
| ↳ Environment | **Sandbox & Production** (debug builds use sandbox, TestFlight and App Store use production) |
| ↳ Key restriction | **Team Scoped (All Topics)**, or Topic Specific with `chat.pincer.ios` |

Click **Continue**, then **Register**, then **Download**. You can download `AuthKey_XXXXXXXXXX.p8` **only once**, so keep a copy somewhere safe. Also note the:
- **Key ID**: the `XXXXXXXXXX` in the file name, also shown on the key's page;
- **Team ID**: shown at the top right of the portal and under Membership.

### 2. Configure and start the relay

On the Gateway machine, from a checkout of this repo:

```sh
cd push-relay
cp ~/Downloads/AuthKey_XXXXXXXXXX.p8 AuthKey.p8
./install-service.sh
```

The first run creates `.env`, fills in a random `RELAY_SECRET`, and lists what's missing. Open `.env` and set:

```sh
APNS_KEY_ID=XXXXXXXXXX
APNS_TEAM_ID=YYYYYYYYYY
```

Then run `./install-service.sh` again. It installs a service that starts at login (macOS launchd) or boot (Linux systemd `--user`) and restarts if the relay crashes. It then checks that the relay answers on `http://127.0.0.1:8787`.

`.env` and `*.p8` are gitignored. The script sets `.env` to mode 600.

### 3. Publish it over HTTPS

The Gateway only accepts `https://` push endpoints. `tailscale serve` provides HTTPS with a real certificate, on your tailnet only:

```sh
./install-service.sh --serve
# or by hand:
tailscale serve --bg --https=8443 http://127.0.0.1:8787
```

The script prints the URL, which looks like `https://gateway-host.your-tailnet.ts.net:8443`. If `tailscale serve` complains about HTTPS, enable **MagicDNS** and **HTTPS Certificates** in the Tailscale admin console under DNS. On macOS with the App Store Tailscale app, the CLI is `/Applications/Tailscale.app/Contents/MacOS/Tailscale`; the script finds it on its own.

The relay has to be reachable from **both** your iPhone (which registers with it once) and the Gateway (which sends the pushes). If both are already on your tailnet, which they are when Pincer connects to the Gateway over Tailscale, there's nothing more to do.

### 4. Turn it on in Pincer

On the iPhone, open Pincer and go to **Settings → Notifications**:
1. Make sure notifications are on, and allow them when iOS asks.
2. Enter the URL from step 3 under **Push relay**, then tap return.
3. Each gateway row should switch to **Push on** within a few seconds.

To test it, send a message in a chat, then close Pincer from the app switcher before the reply finishes. You should get an "OpenClaw agent finished" notification that opens that chat.

## Troubleshooting

The status next to each gateway in Settings → Notifications:

| Status | Meaning |
| --- | --- |
| Push on | Subscribed. The Gateway will push through the relay. |
| Waiting for APNs | iOS hasn't returned a device token yet. Check that notifications are allowed for Pincer in iOS Settings, and that the build is signed with Push Notifications (all TestFlight builds are). |
| Relay must be https:// | The URL isn't `https://` (plain `http://` only works for `localhost`). |
| Gateway has no Web Push | This Gateway doesn't implement `push.web.subscribe`. Update OpenClaw. |
| Not connected / Push off | Pincer subscribes each time it connects. Open the gateway, or check that notifications are on. |
| Push relay refused registration (unknown app) | `APNS_TOPICS` doesn't include the app's bundle id (`chat.pincer.ios`). |
| Another error | Usually the phone can't reach the relay. Open `https://…:8443/healthz` in Safari on the phone; it should show `{"ok":true}`. |

Logs: `~/Library/Logs/pincer-push-relay.log` on macOS, or `journalctl --user -u pincer-push-relay` on Linux. The relay logs one line per push (`push 201`, or the APNs error reason):

- `InvalidProviderToken` / `403`: the Key ID, Team ID or `.p8` don't match, or the key doesn't allow this environment or topic.
- `BadDeviceToken`: the build and environment don't match. The relay already retries the other environment, so if you see this, the token is simply stale; reopen Pincer.
- `DeviceTokenNotForTopic`: the key is Topic Specific for a different bundle id.
- No `push` lines at all: the Gateway isn't reaching the relay. Test with `curl` from the Gateway machine.

Managing the service:

```sh
./install-service.sh --print        # show the launchd/systemd definition
./install-service.sh                # reinstall after editing .env, or after upgrading Node
./install-service.sh --uninstall
```

On Linux, run `sudo loginctl enable-linger $USER` so the relay keeps running while you're logged out. The service records the absolute path to `node`, so rerun the script if that path changes, for example after an `nvm` upgrade.

## Running it some other way

`npm start` runs the relay in the foreground and reads `.env` from this folder. Real environment variables override `.env`, and `RELAY_ENV_FILE` can point to a different file.

| Variable | Meaning |
| --- | --- |
| `RELAY_SECRET` | At least 32 characters. Changing it invalidates every registration, and devices re-register on their next connect. |
| `APNS_KEY_ID`, `APNS_TEAM_ID` | Identify the APNs key. |
| `APNS_KEY_FILE` / `APNS_KEY` | The `.p8`, as a path (relative to this folder) or inline PEM. |
| `APNS_TOPICS` | Allowed bundle ids, comma-separated. The default is `chat.pincer.ios`. |
| `HOST`, `PORT` | Listen address. The default is `127.0.0.1:8787`. |
| `APNS_PRODUCTION_ORIGIN`, `APNS_SANDBOX_ORIGIN` | Override the APNs hosts (for tests). |

Any HTTPS front end works instead of Tailscale, for example Caddy (`reverse_proxy 127.0.0.1:8787`) or a Cloudflare Tunnel, as long as the phone and the Gateway can both reach it.

## How it works

- **No state.** `POST /v1/register` seals `{APNs token, environment, bundle id}` into an opaque id using AES-256-GCM under `RELAY_SECRET`. Pincer subscribes with `<relay>/v1/push/<id>/<gateway-uuid>`, so the Gateway never sees the device token.
- **Content stays encrypted.** The Web Push body is end-to-end encrypted to the device's per-gateway P-256 key and auth secret (RFC 8291). The relay base64url-encodes it into the APNs payload under `pincer.p`, with a generic "New notification" alert as a fallback. Pincer's notification service extension decrypts it. Even decrypted, the Gateway sends only a generic title such as "OpenClaw agent finished" plus which chat or approval it's about, never message content.
- **Headers are mapped.** `TTL` becomes `apns-expiration`. `Urgency: low`/`very-low` becomes priority 5, and anything else is 10. `Topic` becomes `apns-collapse-id`, so "approval updated" replaces "approval requested".
- **Cleanup.** APNs `410`/`BadDeviceToken` returns `410`, so the Gateway drops the subscription. Pushes are rate-limited per id (120/min).
- Anyone who can reach the relay can register a token for the configured bundle ids, but a sealed id only reaches the device that registered it.

Endpoints: `GET /healthz`, `POST /v1/register` `{token, environment, topic}` → `{id}`, `POST /v1/push/:id/:gateway`.

## Tests

```sh
npm test
```

The tests run the relay against a fake HTTP/2 APNs server, including an end-to-end case that uses the mock Gateway's Web Push encryption.
