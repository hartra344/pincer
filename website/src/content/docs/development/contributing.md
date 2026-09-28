---
title: Contributing
description: Where new checks, mock gateway handlers, demo data and documentation go.
---

Pincer is laid out so parallel branches rarely touch the same file. Add new work in a new file and register it in one small list. The same guidance is in [`CONTRIBUTING.md`](https://github.com/hartra344/pincer/blob/main/CONTRIBUTING.md).

## Checks

- Put a new check in `Sources/PincerChecks/<Domain>Checks.swift`.
- Add one section entry in `Sources/PincerChecks/Registry.swift` under the suite that should run it (`unit`, `demo-core`, `demo-extras`, `live-core`, `live-extras`, `live-no-usage`, `live-no-reply-to`, and so on).
- Don't edit `main.swift`. It only dispatches modes.

## Mock gateway

- Put a handler in `mock-gateway/<domain>.mjs`, exporting the handler and, if it seeds data, a seed function. Register the handler in the `REQUEST_HANDLERS` list in `server.mjs`; seeded data goes through `seed.mjs` (`createSeedState` calls each domain's seed function).
- Selftests go in `mock-gateway/selftest/<domain>.mjs`, exporting `run(ctx)`.
- Payloads follow upstream [OpenClaw](https://github.com/openclaw/openclaw). Never invent methods.

## Demo gateway

- Put demo handling in `Sources/PincerKit/DemoGateway+<Domain>.swift` with a `handle<Domain>` handler, registered in the handler chain in `DemoGateway.handle`.
- Showcase data goes in `DemoGateway+Showcase.swift`.

## Documentation

- Feature behaviour goes on a guide page under `website/src/content/docs`, with a sidebar entry in `website/astro.config.mjs`.
- The README only gets a line when a whole new feature area appears. No feature bullets there.

## Running checks

See [Self-checks](../building/#self-checks) for every mode and `scripts/run-checks.sh` for running them all side by side. Each mode runs only its own suite, and live modes need a fresh [mock gateway](../mock-gateway/).
