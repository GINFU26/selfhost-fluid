# Azure deployment — Routerlicious + Redpanda on AKS

Deploy the full-stack self-host Fluid service to Azure Kubernetes Service (AKS), with images
**built from source and pushed to ACR** (the published MCR images are stale/unusable),
Redpanda as the broker, and in-cluster backends. Durable snapshot storage is an **Azure Files
PV**; Mongo and Redis run in-cluster (managed alternatives noted under hardening).

> **Honest status.** A **reference runbook being hardened, not a one-command product.** The
> markers reflect what was actually run: **[VALIDATED]** (done + observed working),
> **[PREPARED]** (manifests/values ready, not yet run end-to-end), **[OPEN]** (still needs
> work). The Helm install, public expose, and the token Function are the open items an infra
> engineer and the author finish together.

## Topology

| Component | Runs as | Storage |
| --- | --- | --- |
| alfred / nexus / deli / scriptorium / scribe / riddler | Helm chart (routerlicious) | — |
| Redpanda (broker) | `redpanda.yaml` | emptyDir (add a PVC for production) |
| gitrest + historian + redis + mongo | `backends.yaml` (in-cluster) | gitrest → **Azure Files PV**; mongo → managed-disk PV |
| Client token minting | Azure Function (open) or a customer backend | tenant key |

## Prerequisites

- `az`, `kubectl`, `helm`, and **Docker with buildx** installed; `az login` done.
- An Azure subscription you can create resources in (this costs money).
- A local [FluidFramework](https://github.com/microsoft/FluidFramework) checkout — the Helm
  chart is at `<FLUID>/server/routerlicious/kubernetes/routerlicious`, and images build from
  its `server/*` Dockerfiles.
- The local stack working first (`../README.md`).

Set once (examples):

```bash
RG=<your-rg>; LOC=westus2; ACR=<youracr>; AKS=<your-aks>
```

## Phase 0 — Build images to ACR (Route B)  **[VALIDATED]**

The server Dockerfiles need BuildKit with a named `root` context (the repo root), which
`az acr build` cannot supply — build with buildx and push:

```bash
az acr login -n "$ACR"
docker buildx create --use --driver docker-container
for svc in routerlicious historian gitrest; do
  docker buildx build --build-context root=. --target runner --platform linux/amd64 \
    -f server/$svc/Dockerfile -t "$ACR.azurecr.io/$svc:v1" --push server/$svc
done   # run from the FluidFramework checkout root
```

**VERIFY:** `az acr repository list -n "$ACR"` shows `routerlicious`, `historian`, `gitrest`.

## Phase 1 — Resource group + ACR + AKS  **[VALIDATED]**

```bash
az group create -n "$RG" -l "$LOC"
az acr create -g "$RG" -n "$ACR" --sku Standard --admin-enabled true
az aks create -g "$RG" -n "$AKS" -l "$LOC" --node-count 2 --node-vm-size Standard_D4s_v3 \
  --tier free --generate-ssh-keys
az aks get-credentials -g "$RG" -n "$AKS"
```

**VERIFY:** `kubectl get nodes` shows `Ready`; `kubectl get storageclass` lists
`azurefile-csi` and `managed-csi`.

## Phase 2 — Image-pull secret  **[VALIDATED]**

With Contributor-only rights you cannot `--attach-acr`; use a docker-registry secret:

```bash
U=$(az acr credential show -n "$ACR" --query username -o tsv)
P=$(az acr credential show -n "$ACR" --query 'passwords[0].value' -o tsv)
kubectl create secret docker-registry regsecret \
  --docker-server="$ACR.azurecr.io" --docker-username="$U" --docker-password="$P"
kubectl patch serviceaccount default -p '{"imagePullSecrets":[{"name":"regsecret"}]}'
```

## Phase 3 — Redpanda + topics  **[VALIDATED]**

```bash
kubectl apply -f azure/redpanda.yaml
kubectl wait --for=condition=available deploy/redpanda --timeout=120s
kubectl exec deploy/redpanda -- rpk topic create rawdeltas deltas -p 8 -r 1
```

**VERIFY:** the create prints `rawdeltas OK` / `deltas OK` (rdkafka does not auto-create them).

## Phase 4 — In-cluster backends (gitrest on Azure Files PV)  **[VALIDATED]**

Edit `azure/backends.yaml` — replace `<ACR>` with your registry — then:

```bash
kubectl apply -f azure/backends.yaml
kubectl wait --for=condition=available deploy/redis deploy/mongo deploy/gitrest deploy/historian --timeout=300s
```

**VERIFY:** `kubectl get pods` shows redis/mongo/gitrest/historian `Running`, and
`kubectl get pvc gitrest-data` is **`Bound`** (RWX, `azurefile-gitrest`). gitrest snapshots
live on **Azure Files** — there is no Blob backend (see hardening).

## Phase 5 — Deploy Routerlicious (Helm)  **[PREPARED — not yet run end-to-end]**

Edit `azure/routerlicious-values.yaml` — replace `<ACR>` — then install with release name
**`fluid`** (the historian backend resolves `fluid-riddler`):

```bash
key=$(openssl rand -hex 32)   # strong tenant key; reuse it for the token endpoint
helm install fluid "<FLUID>/server/routerlicious/kubernetes/routerlicious" \
  -f azure/routerlicious-values.yaml \
  --set-string "alfred.key=$key"  --set-string "nexus.key=$key" \
  --set-string "alfred.tenants[0].key=$key" --set-string "nexus.tenants[0].key=$key" \
  --set-string "riddler.tenants[0].key=$key"
```

**VERIFY:** the alfred/nexus/deli/scriptorium/scribe/riddler pods reach `Running` with no
crash loop. *(Phases 0–4 were validated end-to-end; this Helm install was prepared with
matching values but not yet run through to `Running` — the next hardening step.)*

## Phase 6 — Expose + smoke  **[OPEN]**

The full-stack endpoints are **separate**: REST = alfred, websocket = nexus, storage =
historian. LB-expose each, e.g.
`kubectl expose deploy/fluid-alfred --type LoadBalancer --port 80 --target-port 3000`, then
smoke the public IPs (`/healthz/startup`) and run the client e2e suite against them.

## Phase 7 — Client token function (Azure Function)  **[OPEN]**

`../token-function` signs client JWTs with the tenant key. Connecting/publishing it is the
step that **did not work** (a CORS / auth-level / Key-Vault-env / Function-storage-account
issue). Token issuance works without it via `InsecureTokenProvider` (dev) or a small customer
backend endpoint (prod, signs with the same key). This is the primary engineering item.

---

## Status summary

| Phase | State |
| --- | --- |
| 0 Build images → ACR (Route B) | [VALIDATED] |
| 1 RG + ACR + AKS | [VALIDATED] |
| 2 Image-pull secret | [VALIDATED] |
| 3 Redpanda + topics | [VALIDATED] |
| 4 In-cluster backends (gitrest on Azure Files PV) | [VALIDATED] |
| 5 Helm routerlicious | [PREPARED] — not yet run end-to-end |
| 6 Expose + smoke | [OPEN] |
| 7 Token Azure Function | [OPEN] — needs engineering help |

## Production hardening (beyond this runbook)

- **Snapshots on Azure Blob:** gitrest has **no Blob backend in OSS** (only local-fs / mem /
  redis). Azure Files (this runbook) is the zero-code managed option; Blob (AFR's model)
  requires **writing a new `IFileSystemManager` adapter**.
- **Managed Mongo:** swap in-cluster mongo for **Cosmos DB for MongoDB (vCore)** — set
  `mongodb.operationsDbEndpoint` to the connection string and `directConnection: false`.
- **Managed Redis:** **Azure Cache for Redis** (needs the gitrest chart to gain tls/password
  fields, which is why in-cluster no-auth is used here).
- Put an identity provider (Entra / Easy Auth) in front of the token function; give Redpanda a
  PVC; size nodes for peak memory. Event Hubs (Kafka endpoint) is an alternative broker.
