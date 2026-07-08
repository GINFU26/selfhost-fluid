<!--
Copyright (c) Microsoft Corporation and contributors. All rights reserved.
Licensed under the MIT License.
-->

# Azure deployment — Routerlicious + Redpanda on AKS

Deploy the full-stack self-host Fluid service to Azure Kubernetes Service (AKS),
using the published MCR images, Redpanda as the broker, and managed Azure backends.

> **Honest status.** This is a **reference runbook, not a validated one-command
> deploy.** The pieces below are marked as **[VALIDATED]** (proven locally / on AKS),
> **[AFR-PROVEN]** (Microsoft's own AFR runs it, so compatible in principle but not yet
> re-validated on this stack), or **[OPEN]** (known to still need work). Treat it as the
> starting point an infra engineer and this repo's author harden together.

## Topology

| Component | Runs as | Backing service |
| --- | --- | --- |
| alfred / nexus / deli / scriptorium / scribe / riddler | Helm chart (routerlicious) | — |
| gitrest + historian + redis | `azure/backends.yaml` (in-cluster) | Blob / Azure Cache for Redis (production) |
| Redpanda (broker) | `azure/redpanda.yaml` | — |
| Ops DB | external | **Cosmos DB for MongoDB (vCore)** |
| Client token minting | Azure Function | Key Vault holds the tenant key |

## Prerequisites

- Azure CLI (`az`), `kubectl`, and `helm` installed and logged in (`az login`).
- An Azure subscription you can create resources in (this costs money).
- A local [FluidFramework](https://github.com/microsoft/FluidFramework) checkout — the
  routerlicious Helm chart lives at `<FLUID_SERVER_DIR>/routerlicious/kubernetes/routerlicious`.
- The local stack working first (`../README.md` → Quick start) so you know the shape.

Set once:

```bash
export FLUID_SERVER_DIR=../FluidFramework/server   # path to your FluidFramework 'server' dir
export RG=fluid-selfhost-rg
export LOC=eastus
export AKS=fluid-selfhost-aks
export KV=<YOUR_KEYVAULT>
```

---

## Phase 1 — Resource group + AKS  **[VALIDATED]**

```bash
az group create -n "$RG" -l "$LOC"
az aks create -g "$RG" -n "$AKS" --node-count 2 --generate-ssh-keys --tier free
az aks get-credentials -g "$RG" -n "$AKS"
```

**VERIFY:** `kubectl get nodes` shows `Ready` nodes.

## Phase 2 — Managed Ops DB (Cosmos for MongoDB, vCore)  **[AFR-PROVEN]**

AFR runs on Cosmos DB for MongoDB, so Routerlicious is compatible in principle; this
exact wiring is **not yet re-validated on this self-host stack** — validate here.

```bash
az cosmosdb mongocluster create -g "$RG" -n fluid-mongo \
  --location "$LOC" --administrator-login fluidadmin \
  --administrator-login-password '<STRONG_PASSWORD>' \
  --server-version 5.0 --shard-node-count 1 \
  --shard-node-tier M30 --shard-node-disk-size-gb 32
# Capture the connection string -> store in Key Vault (Phase 4).
```

**VERIFY:** the cluster provisions and you can obtain a connection string.

## Phase 3 — In-cluster backends + broker  **[VALIDATED]**

```bash
kubectl apply -f azure/redpanda.yaml
kubectl apply -f azure/backends.yaml
```

**VERIFY:** `kubectl get pods` shows `redpanda`, `redis`, `gitrest`, `historian` `Running`.

## Phase 4 — Secrets (Key Vault)  **[VALIDATED]**

```bash
az keyvault create -g "$RG" -n "$KV" -l "$LOC"
# A strong random tenant key (used by both the server and the token function):
az keyvault secret set --vault-name "$KV" -n fluid-tenant-key --value "$(openssl rand -hex 32)"
az keyvault secret set --vault-name "$KV" -n mongo-connstring  --value '<COSMOS_MONGO_CONNSTRING>'
```

> Never use the chart's placeholder tenant key in production. The token function and
> riddler must share the **same** `fluid-tenant-key`.

## Phase 5 — Deploy Routerlicious (Helm)  **[VALIDATED]**

Install with release name **`fluid`** (the `historian` backend resolves `fluid-riddler`
by that name):

```bash
key=$(az keyvault secret show --vault-name "$KV" -n fluid-tenant-key  --query value -o tsv)
mongo=$(az keyvault secret show --vault-name "$KV" -n mongo-connstring --query value -o tsv)

helm install fluid "$FLUID_SERVER_DIR/routerlicious/kubernetes/routerlicious" \
  -f azure/routerlicious-values.yaml \
  --set-string "alfred.key=$key"  --set-string "nexus.key=$key" \
  --set-string "alfred.tenants[0].key=$key" --set-string "nexus.tenants[0].key=$key" \
  --set-string "riddler.tenants[0].key=$key" \
  --set-string "mongodb.operationsDbEndpoint=$mongo"
```

**VERIFY:** `kubectl get pods` shows the alfred/nexus/deli/scriptorium/scribe/riddler
pods `Running`; `kubectl logs deploy/fluid-alfred` has no crash loop.

## Phase 6 — Client token function (Azure Function)  **[OPEN]**

The token-minting function is in [`../token-function`](../token-function). It signs
client JWTs with the Key Vault tenant key.

```bash
# from the token-function directory:
npm install
func azure functionapp publish <YOUR_FUNCTION_APP>   # requires an existing Function App
# App settings: FLUID_TENANT_KEY (from Key Vault), FLUID_TENANT_ID=fluid
```

> **[OPEN] Known issue:** connecting/publishing the Azure Function is the step still
> being worked out (Blob wiring succeeded; the Function connection did not). Do not
> assume this phase works end-to-end yet — this is the primary item for the deployment
> engineering review.

## Phase 7 — Ingress + smoke  **[PARTIAL]**

Expose the proxy/alfred/nexus via an Ingress or `Service type=LoadBalancer`, add TLS,
then smoke-test the public endpoint the same way as local (health endpoints, then the
Fluid client e2e suite pointed at the public URL).

---

## Status summary

| Phase | State |
| --- | --- |
| 1 RG + AKS | [VALIDATED] |
| 2 Cosmos for MongoDB | [AFR-PROVEN] — validate here |
| 3 in-cluster backends + Redpanda | [VALIDATED] |
| 4 Key Vault secrets | [VALIDATED] |
| 5 Helm routerlicious | [VALIDATED] |
| 6 token Azure Function | **[OPEN]** — needs engineering help |
| 7 ingress + TLS + public smoke | [PARTIAL] |

## Production hardening (beyond this runbook)

- Replace in-cluster redis with **Azure Cache for Redis**; gitrest storage with **Azure Blob** (via the gitrest `IFileSystemManager` seam) — both **[AFR-PROVEN]**, not yet wired here.
- Put an identity provider (Entra / Easy Auth) in front of the token function.
- Give Redpanda a PersistentVolumeClaim; size AKS nodes for peak memory.
- Consider **Event Hubs** (Kafka endpoint) instead of self-run Redpanda — **[AFR-PROVEN]**; needs SASL_SSL + pre-provisioned `deltas`/`rawdeltas` hubs.
