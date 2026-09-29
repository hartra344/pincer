# Contributing

Pincer is laid out so parallel branches rarely touch the same file. Add new work in a new file and register it in one small list.

## Checks (`Sources/PincerChecks`)

- Put a new check in a per-domain file, `Sources/PincerChecks/<Domain>Checks.swift`.
- Add one section entry for it in `Sources/PincerChecks/Registry.swift`, under the suite that should run it: `unit`, `demoCore`, `demoExtras`, `liveCore`, `liveExtras`, `liveNoUsage`, `liveNoReplyTo`, and so on (run by `--demo-core`, `--live-core`, …).
- Don't edit `main.swift`; it only dispatches modes.

## Mock gateway (`mock-gateway/`)

- A handler lives in a domain module, `mock-gateway/<domain>.mjs`. It exports its handler and, if it seeds data, a seed function (`seed<Domain>` / `seed(state)`).
- Register the handler in the `REQUEST_HANDLERS` list in `server.mjs`. Seeded data is set up through `seed.mjs` (`createSeedState` calls each domain's seed function).
- Selftests go in `mock-gateway/selftest/<domain>.mjs`, exporting `run(ctx)`.
- Payloads follow upstream OpenClaw ([openclaw/openclaw](https://github.com/openclaw/openclaw)). Never invent methods or fields.

## Demo gateway (`Sources/PincerKit`)

- Put demo handling in `Sources/PincerKit/DemoGateway+<Domain>.swift` with a `handle<Domain>` handler, and register it in the handler chain in `DemoGateway.handle`.
- Showcase data goes in `DemoGateway+Showcase.swift`.

## Documentation

- Feature behaviour is documented in `website/src/content/docs`: add or edit a guide page and give a new page a sidebar entry in `website/astro.config.mjs`.
- `README.md` only gets a line when a whole new feature area appears. No feature bullets there.

## macOS window toolbar

Switching chats must not remove or re-add a window toolbar item. When one is rebuilt, macOS redraws every toolbar button and the sidebar's Organize and New Chat buttons flash (#84, #262).

- A per-chat `.id` never goes on a full-size detail view or on the root view of a `ToolbarItem`. Put it inside a stable container (a `ZStack` with a fixed or full-size frame), as `GatewayDetail` in `RootView.swift` and `ChatHeaderAvatar` do.
- The chat's title, subtitle and toolbar items live in `ChatChrome`, outside the per-chat `.id`.
- CI runs `PincerMacDev --toolbar-stability-check`, which fails if a chat switch rebuilds a toolbar item. Run it locally with `PINCER_DEV_NAMESPACE=toolbar-check PINCER_KEYCHAIN=memory swift run PincerMacDev --toolbar-stability-check` (it opens a window for a few seconds).

## Running checks

`scripts/run-checks.sh` runs the unit tests and every `PincerChecks` mode side by side, each live mode against its own fresh mock. To run one by hand, each mode runs only its own suite:

```sh
swift run PincerChecks                                   # unit (offline) suite
swift run PincerChecks --demo                            # --demo-core + --demo-extras
swift run PincerChecks --demo-core                       # or --demo-extras
cd mock-gateway && PORT=18930 node server.mjs            # a FRESH mock, in another terminal
swift run PincerChecks --live-core ws://127.0.0.1:18930 dev-token   # or --live-extras
swift run PincerChecks --live-no-usage ws://127.0.0.1:18931 dev-token       # mock: MOCK_NO_USAGE=1
swift run PincerChecks --live-no-reply-to ws://127.0.0.1:18932 dev-token    # mock: MOCK_NO_REPLY_TO=1
cd mock-gateway && npm ci && npm run selftest            # the mock's own selftest
swift test                                               # PincerKit unit tests
```

Live modes need a fresh mock each, because they change its state. Modes and environment variables are described in [Building](website/src/content/docs/development/building.md#self-checks).
