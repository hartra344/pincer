# Pincer push relay

The OpenClaw Gateway sends operator notifications as standard Web Push (RFC 8030/8291/8292): it POSTs an encrypted `aes128gcm` body to whatever HTTPS endpoint a device subscribed with `push.web.subscribe`. iOS apps can only be woken by APNs, so this relay sits in between. It's a small Node server with no dependencies. It receives the Web Push and forwards it to APNs **still encrypted**. Pincer's notification service extension then decrypts it on the device with keys that never leave the device.

```
Gateway ──Web Push (encrypted)──▶ relay ──APNs (same bytes)──▶ iPhone ─▶ Notification Service Extension decrypts
```

## What the relay knows

- **It stores nothing.** `POST /v1/register` seals `{APNs token, environment, bundle id}` into an opaque id using AES-256-GCM under `RELAY_SECRET`. The app builds its endpoint as `<relay>/v1/push/<id>/<gateway-uuid>`. The Gateway only ever sees the sealed id, not the device token.
- **It can't read notifications.** The body is end-to-end encrypted to the device's per-gateway P-256 key and auth secret (RFC 8291). The relay base64url-encodes it into the APNs payload under `pincer.p`, with a generic "New notification" alert as a fallback. Even decrypted, the Gateway sends only a generic title such as "OpenClaw agent finished" plus the chat or approval path, never message content.
- **It maps headers.** `TTL` becomes `apns-expiration`. `Urgency: low`/`very-low` becomes priority 5, and anything else is 10. `Topic` becomes `apns-collapse-id`, so an "approval updated" push replaces the "approval requested" one.
- **It cleans up.** APNs `410` or `BadDeviceToken` returns `410` to the Gateway, which then drops the subscription. Pushes are rate-limited per id, 120 a minute by default.

Anyone who can reach the relay can register a token for the configured bundle ids, but a sealed id only reaches the device that registered it.

## Running

You need an APNs auth key (`.p8`) from the Apple Developer account that signs the Pincer build. The key has to belong to the same team as the app.

```sh
RELAY_SECRET=$(openssl rand -base64 48) \
APNS_KEY_ID=ABC123DEFG APNS_TEAM_ID=TEAM123456 APNS_KEY_FILE=AuthKey_ABC123DEFG.p8 \
npm start          # http://127.0.0.1:8787
```

| Variable | Meaning |
| --- | --- |
| `RELAY_SECRET` | At least 32 characters. Changing it invalidates every registration, and devices re-register on their next connect. |
| `APNS_KEY_ID`, `APNS_TEAM_ID` | Identify the APNs auth key. |
| `APNS_KEY` / `APNS_KEY_FILE` | The `.p8` PEM, inline or as a path. |
| `APNS_TOPICS` | Allowed bundle ids, comma-separated. The default is `chat.pincer.ios`. |
| `PORT`, `HOST` | Listen address. The default is `127.0.0.1:8787`. |
| `APNS_PRODUCTION_ORIGIN`, `APNS_SANDBOX_ORIGIN` | Override the APNs hosts (for tests). |

Development builds register with the `sandbox` environment and TestFlight/App Store builds with `production`. If APNs says a token is bad, the relay retries it against the other environment.

The Gateway only accepts `https://` endpoints, so put the relay behind TLS: Tailscale Funnel (`tailscale funnel 8787`), Caddy, a Cloudflare Tunnel, and so on. It has to be reachable **from the Gateway**, not from the phone. Then enter its URL in Pincer under Settings → Notifications → Push relay. Each gateway row shows whether push is active, or whether that Gateway doesn't support Web Push.

Endpoints: `GET /healthz`, `POST /v1/register` `{token, environment, topic}` → `{id}`, `POST /v1/push/:id/:gateway`.

## Tests

```sh
npm test
```

The tests run the relay against a fake HTTP/2 APNs server. They include an end-to-end case that uses the mock Gateway's Web Push encryption.
