<!--
Copyright (c) Microsoft Corporation and contributors. All rights reserved.
Licensed under the MIT License.
-->

# Self-host Fluid Framework — Routerlicious + Redpanda

Run your own [Fluid Framework](https://fluidframework.com) real-time collaboration
backend — the same **Routerlicious** ordering service that powers Azure Fluid Relay —
self-hosted, with the Kafka + ZooKeeper broker replaced by a single lightweight
**Redpanda** container.

- **You own** the storage (MongoDB/Cosmos + Git snapshots) and the identity/token layer.
- **Zero application-code changes** vs stock Routerlicious — Redpanda speaks the Kafka
  wire protocol, so the ordering service connects to it unchanged.
- **One broker container** (Redpanda) instead of two (Kafka + ZooKeeper).

> **Which shape?** This repo deploys **full-stack Routerlicious with Redpanda** — the
> recommended production shape (broker-grade durability, horizontal scale, and it stays
> on the mainline Routerlicious code so it inherits upstream patches). A lighter
> single-process **slim** shape exists for dev/prototype use; see [ARCHITECTURE.md](./ARCHITECTURE.md).

---

## What's in this repo

| Path | Purpose |
| --- | --- |
| [docker-compose.redpanda.yml](./docker-compose.redpanda.yml) | The full stack for **amd64**, built from source (stock upstream Dockerfile). |
| [docker-compose.redpanda.arm64.yml](./docker-compose.redpanda.arm64.yml) | The full stack for **arm64**, built from source (Dockerfiles patched from upstream). |
| [nginx.conf](./nginx.conf) | Reverse proxy exposing REST/ws (3003), nexus (3002), historian (3001). |
| [.env.example](./.env.example) | Optional overrides (reuse a checkout via `FLUID_REPO_DIR`, pin `FLUID_REF`). |
| [scripts/](./scripts) | `run-local` (one-command bring-up) and `smoke-test`, in PowerShell and bash. |
| [azure/](./azure) | AKS manifests (Redpanda, in-cluster backends), Helm values, and the deployment runbook. |
| [token-function/](./token-function) | Token-minting Azure Function (client JWT signing). |
| [ARCHITECTURE.md](./ARCHITECTURE.md) | How the pieces fit together (full-stack + slim). |
| [AGENTS.md](./AGENTS.md) | Deterministic deployment runbook for an AI agent or a person. |

---

## Status (honest)

| Target | State |
| --- | --- |
| **Local (amd64)** | One command; builds from source (fetches FluidFramework `main`). Config verified; not runtime-tested here (no amd64 host). |
| **Local (arm64)** | One command; builds from source (Dockerfiles patched from upstream). **Validated** end-to-end (full e2e: 634 pass / 6 unrelated). |
| **Azure (AKS)** | Manifests + Helm values + a scripted runbook exist ([azure/](./azure)); phases 1–5 validated, the token Azure Function (phase 6) is an open item. |

This is a self-host reference, not a managed service. "It runs on my machine" is not
"a customer can run it" — the Azure path is still being made reliably repeatable.

---

## Prerequisites

- **Docker Desktop** (or Docker Engine + Compose v2).
- **git** — the helper shallow-clones FluidFramework `main` as the build source (unless
  you point `FLUID_REPO_DIR` at an existing checkout).
- **~4 GB** free RAM for the full stack. The first build compiles native deps
  (node-rdkafka) and can take several minutes.
- Run the script matching your host arch: **`run-local`** on amd64, **`run-local-arm64`**
  on arm64 (Apple Silicon, Windows-on-ARM).

> Why build from source? The published MCR images lag upstream `main` (older `latest`
> predates the `nexus` service split and lacks the `/healthz/startup` route), so a
> main-derived compose does not match them. Building from source keeps images and
> compose in lockstep.

---

## Quick start (local, one command)

**Windows / PowerShell**

```powershell
./scripts/run-local.ps1
```

**macOS / Linux**

```bash
./scripts/run-local.sh
```

On **amd64**, this fetches the FluidFramework source (a shallow clone into
`./.fluidframework`), builds the images, starts the stack, waits for health, and runs the
smoke test. On **arm64**, use `run-local-arm64` instead (below).

**Manual equivalent (amd64)** — needs a FluidFramework checkout, or run the script which
clones one:

```bash
FLUID_REPO_DIR=/path/to/FluidFramework \
  docker compose -f docker-compose.redpanda.yml up -d --build
```

### Native arm64 (Apple Silicon / Windows-on-ARM)

For native arm64 (Apple Silicon, Windows-on-ARM), the helper fetches the FluidFramework
source from GitHub (a shallow clone into `./.fluidframework`), generates the arm64
Dockerfiles by patching upstream's (so nothing arm64-specific is vendored), and builds:

```powershell
./scripts/run-local-arm64.ps1          # PowerShell
```

```bash
./scripts/run-local-arm64.sh           # macOS / Linux
```

To reuse an existing FluidFramework checkout instead of cloning, set `FLUID_REPO_DIR`
to its repo root first. The first build compiles node-rdkafka natively and can take
several minutes.

### What success looks like

- The smoke test prints **`SMOKE PASS`**.
- Endpoints:
  - REST + websocket: `http://localhost:3003`
  - Storage (historian): `http://localhost:3001`
  - Tenant manager (riddler): `http://localhost:5000`
- Default dev tenant id: `fluid`.

---

## Connect a Fluid client

Point a Fluid client at the local endpoints using tenant `fluid`. For local testing
the stock Routerlicious dev tenant key is used; for any real deployment, set your own
tenant key and put a token provider in front (a sample token-minting Azure Function is
included with the Azure path — see [AGENTS.md](./AGENTS.md)). Never ship a signing key
in client code.

---

## Validation

- **Functional:** this stack passes the full Fluid client end-to-end suite —
  **634 pass / 6 fail / 492 skip** (the 6 failures are old-version compatibility tests
  that need old Fluid versions installed; they are unrelated to the stack). To reproduce
  against the running stack, from a
  [FluidFramework](https://github.com/microsoft/FluidFramework) checkout:

  ```bash
  # one-time: build the e2e test package (and its deps)
  node node_modules/@fluidframework/build-tools/dist/fluidBuild/fluidBuild.js \
    --root . --task compile packages/test/test-end-to-end-tests

  # run the suite (from packages/test/test-end-to-end-tests)
  pnpm exec mocha --driver=r11s --r11sEndpointName=docker --timeout=30s --compatKind=None
  # quick subset: add  --grep "SharedDirectory"   (44 tests through the full pipeline)
  ```

  > **Windows note:** the r11s `docker` driver targets `localhost`. If Docker Desktop's
  > IPv6 `localhost` forwarding is broken (connections to `localhost:3003` hang while
  > `127.0.0.1:3003` works), run with `NODE_OPTIONS=--dns-result-order=ipv4first` so Node
  > resolves `localhost` to IPv4.

- **Resource cost (broker):** Redpanda vs the stock Kafka + ZooKeeper — **~13× less
  average CPU, ~33× less peak CPU, ~2.2× less memory**, and one fewer container, for
  an identical test outcome.

---

## Stop / clean up

```bash
docker compose -f docker-compose.redpanda.yml down       # stop (keep data)
docker compose -f docker-compose.redpanda.yml down -v    # stop and delete data volumes
```

---

## Configuration

- **`.env`** — optional. `FLUID_REPO_DIR` reuses an existing FluidFramework checkout
  instead of cloning; `FLUID_REF` pins the git ref to clone (default `main`).
- **Ports** — `3003` (REST/ws), `3002` (nexus), `3001` (historian), `5000` (riddler),
  `9092`/`9644` (redpanda). They must be free on the host.
- **Storage** — snapshots persist in the `git` volume; ops/metadata in the `mongodata`
  volume. For Azure, these map to Blob (via gitrest) and Cosmos for MongoDB.

---

## Azure deployment

Deploy to AKS with managed backends (Cosmos for MongoDB, Redpanda broker, Blob/Redis).
The step-by-step runbook is in [azure/README.md](./azure/README.md); a scripted version
of the validated phases is [scripts/azure-deploy.ps1](./scripts/azure-deploy.ps1).

**Honest status:** phases 1–5 (AKS, in-cluster backends + Redpanda, Key Vault, Helm
install) are validated; the client **token Azure Function (phase 6) is still an open
item** and is the main thing needing deployment-engineering help. Managed Cosmos / Redis /
Blob are what AFR itself runs (compatible in principle) but are not yet re-validated on
this stack.

---

## License

[MIT](./LICENSE). Fluid Framework and Routerlicious are © Microsoft Corporation.
