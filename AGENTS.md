<!--
Copyright (c) Microsoft Corporation and contributors. All rights reserved.
Licensed under the MIT License.
-->

# AGENTS.md — deployment runbook

This file lets an **AI agent or a person** stand up the self-host Fluid stack
deterministically. Execute phases **in order**. After each phase, run its **VERIFY**
step and do **not** proceed until it passes. If VERIFY fails, consult **Troubleshooting**
before retrying — do not loop blindly.

## Assumptions

- Docker and git are installed and the Docker daemon is running.
- The working directory is the repository root (the folder containing `docker-compose.redpanda.yml`).
- Both stacks BUILD the Fluid images from source (the published MCR images lag upstream
  `main` and don't match this compose). Run the script matching the host arch.

---

## Phase 1 — Local stack (built from source)

**Goal:** full Routerlicious + Redpanda running locally, images built from FluidFramework source.

**Steps** (the helper fetches FluidFramework `main` into `./.fluidframework` and builds):

1. **amd64 host:** `./scripts/run-local.ps1` (PowerShell) or `./scripts/run-local.sh` (bash).
2. **arm64 host:** `./scripts/run-local-arm64.ps1` / `.sh` (patches the Dockerfiles for arm64).

To reuse an existing checkout instead of cloning, set `FLUID_REPO_DIR` to its repo root.

**VERIFY** (all must hold):

- `docker compose -f docker-compose.redpanda.yml ps` shows `alfred`, `nexus`, `historian` as `healthy`.
- `curl -fsS http://localhost:3003/healthz/startup` returns HTTP 200 (alfred via proxy).
- `curl -fsS http://localhost:3001/healthz/startup` returns HTTP 200 (historian via proxy).
- Or simply run the smoke test and expect `SMOKE PASS`:
  - bash: `./scripts/smoke-test.sh`
  - PowerShell: `./scripts/smoke-test.ps1`

**On failure:** `docker compose -f docker-compose.redpanda.yml logs --tail=100`. See Troubleshooting.

**Why build from source:** the published MCR images lag upstream `main` (older `latest`
predates the `nexus` service split and lacks the `/healthz/startup` route), so a
main-derived compose does not match them. Building keeps images and compose in lockstep.

---

## Phase 2 — Azure (AKS)

**Goal:** the same stack on Azure with managed Cosmos for MongoDB, a Redpanda broker,
and a token-minting Azure Function.

**Runbook:** follow [azure/README.md](./azure/README.md) phase by phase, or run
`./scripts/azure-deploy.ps1` (automates the validated phases 1–5). Each phase there has
its own VERIFY step.

**Status markers (do not overstate):** phases 1 (AKS), 3 (in-cluster backends + Redpanda),
4 (Key Vault), 5 (Helm routerlicious) are **[VALIDATED]**. Phase 2 (Cosmos for MongoDB)
is **[AFR-PROVEN]** but not re-validated here. Phase 6 (**token Azure Function**) is
**[OPEN]** — the known blocker; do not present it as working. Phase 7 (ingress/TLS) is partial.

---

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `git clone` fails | `git` must reach github.com. Or set `FLUID_REPO_DIR` to a local FluidFramework checkout to skip cloning. |
| First build very slow | Expected — the first build compiles native deps (node-rdkafka); later builds reuse the Docker cache. Run the script matching the host arch. |
| Port already in use | Free ports `3001`, `3002`, `3003`, `5000`, `9092`, `9644`, `3022` on the host. |
| `alfred`/`nexus` not healthy | Give it up to ~1 min (healthcheck `start_period` 20s + retries). Then check `logs`. |
| Storage errors on op-heavy load | Confirm `gitrest` and `historian` are up; the `git` and `mongodata` volumes exist. |
| Redpanda / topic errors | Redpanda is aliased `kafka`; `--mode=dev-container` auto-creates topics. Restart redpanda if it lost the alias after a partial `up`. |
| Smoke or e2e client hangs on `localhost` | Windows Docker Desktop IPv6 `localhost` forwarding can be broken (`localhost:3003` hangs, `127.0.0.1:3003` works). The scripts already use `127.0.0.1`; for the e2e run set `NODE_OPTIONS=--dns-result-order=ipv4first`. |

---

## Endpoints & defaults

| Service | Host port | Notes |
| --- | --- | --- |
| REST + websocket (alfred/nexus via proxy) | 3003 | primary client endpoint |
| nexus (delta stream) | 3002 | |
| historian (storage) | 3001 | |
| riddler (tenant manager) | 5000 | |
| redpanda | 9092 / 9644 | Kafka API / admin |
| git (ssh) | 3022 | snapshot git remote |

- Default tenant id: `fluid`.
- Data persists in the `git` and `mongodata` Docker volumes until `down -v`.

---

## Teardown

- Stop, keep data: `docker compose -f docker-compose.redpanda.yml down`
- Stop, delete data: `docker compose -f docker-compose.redpanda.yml down -v`
