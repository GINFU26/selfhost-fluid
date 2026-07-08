# Self-host Fluid Framework — Routerlicious + Redpanda

Run your own [Fluid Framework](https://fluidframework.com) real-time collaboration
backend — the same **Routerlicious** ordering service behind Azure Fluid Relay (AFR) —
self-hosted, with the Kafka + ZooKeeper broker replaced by a single **Redpanda** container
(zero application-code change — Redpanda speaks the Kafka wire protocol).

> **Honesty up front.** The **local** stack is validated end-to-end. The **Azure** path is a
> work in progress that needs deployment-engineering help, and a couple of pieces don't work
> yet (Blob storage, the token Azure Function) — [§4](#4-open-items-honest-status) says so.

---

## What you get

Self-hosting means you run the **whole** Fluid backend and **own its data**:

- **Fluid ordering service** — full Routerlicious (alfred, nexus, deli, scriptorium, scribe, riddler).
- **Broker** — one **Redpanda** container instead of Kafka + ZooKeeper.
- **Your storage** — MongoDB (ops/metadata) + git-based snapshots (gitrest/historian) on a filesystem volume. **No Azure Blob dependency** ([§4](#4-open-items-honest-status)).
- **Your identity** — per-tenant signing keys + JWT tokens; the signing key stays server-side.

> Component-by-component **design and diagrams** — the full-stack shape **and** the slim
> alternative — live in **[ARCHITECTURE.md](./ARCHITECTURE.md)**. This README stays
> high-level and focuses on the **choice** and the **deployment**.

---

## 1. Four service shapes, measured

The **same** full Fluid client e2e suite (`--compatKind=None`, 227 suites / 1132 cases) run
against four backend shapes on one machine — **identical functional result everywhere**
(**634 pass / 6 fail / 492 skip**; the 6 are old-version compat tests, unrelated). The
difference is **cost and operability**:

| Shape | Broker | Containers | e2e | Broker / runtime footprint | Fit |
| --- | --- | :--: | --- | --- | --- |
| **Kafka + ZooKeeper** (stock) | Kafka 1.1.1 + ZK (2 svc) | 15 | 634 ✓ (328 s) | broker avg CPU **62%**, peak **333%**, mem **~634 MiB** | production, heavy broker |
| **Redpanda** (this repo) | Redpanda (1 svc) | 14 | 634 ✓ (346 s) | broker avg CPU **4.9%**, peak **10%**, mem **~289 MiB** | **production — recommended** |
| **slim** (single process) | in-process | 8 | 634 ✓ (189 s) | slim proc 61% CPU / 339 MiB | dev / prototype |
| **tinylicious** | in-memory | 1 | 658 ✓ (149 s) | 1 proc, ~421 MiB avg | dev only |

**Redpanda vs Kafka + ZooKeeper** (same test outcome): **~13× less avg CPU, ~33× less peak
CPU, ~2.2× less memory**, one fewer container. `tinylicious` / `slim` are single-node with
no broker failover (dev/prototype); `Kafka + ZooKeeper` is production but the JVM broker is
heavy.

---

## 2. Recommended: full Routerlicious + Redpanda

The only shape that is **production-grade** (broker durability + horizontal scale), **cheap**
(a fraction of the Kafka+ZK broker cost), and **on the mainline code path** (no fork to
maintain). This repo deploys exactly this.

**How it works (brief):** a client's op goes to **alfred** (REST) or **nexus** (websocket),
which *produce* it to Redpanda **`rawdeltas`** → **deli** assigns sequence numbers →
**`deltas`** → **scriptorium** (ops to Mongo) / **scribe** (snapshots via historian/gitrest)
/ broadcaster → **Redis** fan-out → back to clients over nexus. One Redpanda container
replaces Kafka + ZooKeeper, connects unchanged (Kafka wire protocol), and auto-creates topics
in `--mode=dev-container`. **Full diagram + notes: [ARCHITECTURE.md §1](./ARCHITECTURE.md).**

---

## 3. Deploy

> A deterministic, step-by-step runbook for a **person or an AI agent** (local **and** Azure,
> with VERIFY gates) is in [AGENTS.md](./AGENTS.md); the Azure phase detail is in
> [azure/README.md](./azure/README.md).

### Local — one command (validated)

```powershell
./scripts/run-local.ps1          # amd64   (PowerShell)
./scripts/run-local-arm64.ps1    # arm64   (Apple Silicon / Windows-on-ARM)
```

```bash
./scripts/run-local.sh           # amd64   (bash)
./scripts/run-local-arm64.sh     # arm64
```

The helper shallow-clones FluidFramework `main` into `./.fluidframework`, builds the images
**from source**, starts the stack, waits for health, and runs the smoke test (prints
**`SMOKE PASS`**). Endpoints: REST+ws `:3003`, historian `:3001`, riddler `:5000`; dev tenant
`fluid`. Set `FLUID_REPO_DIR` to reuse a checkout. Stop with
`docker compose -f docker-compose.redpanda.yml down [-v]`.

> **Why build from source?** The published MCR images lag `main` (they predate the nexus
> split and the `/healthz/startup` route), so they don't match this compose.

**Functional validation** — point the client e2e suite at the running stack (how the
634-pass number was produced): from a FluidFramework checkout, compile the e2e package once,
then from `packages/test/test-end-to-end-tests`:

```bash
pnpm exec mocha --driver=r11s --r11sEndpointName=docker --timeout=30s --compatKind=None
# quick subset: add  --grep "SharedDirectory"   (44 tests through the full pipeline)
```

(`--compatKind=None` is required. Windows: if `localhost:3003` hangs but `127.0.0.1:3003`
works, add `NODE_OPTIONS=--dns-result-order=ipv4first`.)

### Azure (AKS) — in progress

Cluster + in-cluster backends (Redpanda + topics, Redis, Mongo, gitrest, historian) come up,
the Routerlicious services install via Helm, and **durable snapshot storage on an Azure Files
PV** works. **Not done:** a single scripted end-to-end deploy and the token layer. Treat
**[azure/README.md](./azure/README.md)** as a **runbook to harden, not a product** — this is
where deployment-engineering help is needed.

Images build from source and push to ACR with buildx (the server Dockerfiles need a named
`root` build context that `az acr build` can't supply):

```bash
docker buildx build --build-context root=. --target runner --platform linux/amd64 \
  -f server/<svc>/Dockerfile -t <ACR>.azurecr.io/<svc>:v1 --push server/<svc>
# <svc> = routerlicious | historian | gitrest ; run from a FluidFramework checkout root
```

---

## 4. Open items (honest status)

- **Azure Blob for snapshots — not supported.** gitrest has no Blob backend in OSS (only
  local-fs / in-memory / redis); we use an **Azure Files / managed-disk PV** instead. Blob
  (AFR's model) would need a **new adapter** — not written.
- **Token Azure Function — did not connect.** Token issuance works via `InsecureTokenProvider`
  (dev) or a small **customer backend endpoint** (prod, signs with the tenant key); the
  standalone serverless Function is unfinished (a CORS / auth-level / Key-Vault-env item).
- **Migration from AFR — read-only "freeze" window (tested).** Freeze the source doc with
  read-only (`[DocRead]`) tokens (nexus rejects writes server-side) → copy its state via the
  Fluid client → recreate on the self-host → cut over. Tested end-to-end AFR → self-host.
  Caveat: **latest state only** (no op history), same-document-ID preservation is a separate
  mechanism, tested with self-signed tokens.
- **Maintenance — strategy only (no tooling).** Upgrades = rebuild images from a newer
  FluidFramework ref + rolling restart (shared storage schema, no data migration);
  backup = snapshot the git-snapshot PV + Mongo; monitoring / autoscaling = to be designed.

---

## Repository map

| Path | Purpose |
| --- | --- |
| [docker-compose.redpanda.yml](./docker-compose.redpanda.yml) · [.arm64.yml](./docker-compose.redpanda.arm64.yml) | Full stack (amd64 / arm64), built from source. |
| [scripts/](./scripts) | `run-local` + `smoke-test` (PowerShell and bash). |
| [nginx.conf](./nginx.conf) | Reverse proxy: REST/ws 3003, nexus 3002, historian 3001. |
| [azure/](./azure) | AKS manifests, Helm values, and the (in-progress) deployment runbook. |
| [token-function/](./token-function) | Token-minting Azure Function (open item — §4). |
| [ARCHITECTURE.md](./ARCHITECTURE.md) | Full-stack and slim architecture + diagrams. |
| [AGENTS.md](./AGENTS.md) | Deterministic runbook for an AI agent or a person. |

---

## License

[MIT](./LICENSE). Fluid Framework and Routerlicious are © Microsoft Corporation.
