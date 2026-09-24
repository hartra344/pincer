# Mock OpenClaw Gateway

Standalone Node.js mock WebSocket gateway for integration-testing an OpenClaw Gateway v4 operator client.

```bash
npm install
npm start
```

Defaults: `HOST=127.0.0.1`, `PORT=18789`, `MOCK_TOKEN=dev-token`, `MOCK_PAIRING=auto`.

Pairing modes:

- `auto`: first unknown device receives `PAIRING_REQUIRED`, then is approved after about 3 seconds.
- `off`: unknown devices are accepted.
- `manual`: approve by typing the printed `requestId` on stdin.

Run the full in-process self-test:

```bash
npm test --if-present
npm run selftest
```
