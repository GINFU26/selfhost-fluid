<!--
Copyright (c) Microsoft Corporation and contributors. All rights reserved.
Licensed under the MIT License.
-->

# skill.md — `gin-test-001` resource group (AKS + ACR) deploy capture

Captured live from Azure on **2026-07-13**. This documents **every resource, every
deployment step, and the exported ARM template deploy files** for the `gin-test-001`
resource group **and** its AKS-managed node resource group
`MC_gin-test-001_gen-test-aks-001_eastus2`.

> The `MC_...` group is **auto-provisioned and owned by AKS** — you do **not** deploy it
> directly. It is created for you when the managed cluster is created, and is documented
> here for completeness (as requested). Deploying it by hand will fight the AKS control
> plane. Recreate it only by recreating the cluster in `gin-test-001`.

## Scope / identity

| Fact | Value |
| --- | --- |
| Subscription | `<your-subscription-name>` — `<your-subscription-id>` |
| Primary resource group | `gin-test-001` (RG metadata location **eastus**) |
| AKS node resource group | `MC_gin-test-001_gen-test-aks-001_eastus2` (**eastus2**) |
| ACR | `gentestfrs001` → `gentestfrs001.azurecr.io` (Standard, admin enabled, **eastus**) |
| AKS cluster | `gen-test-aks-001` (Kubernetes **1.35**, **eastus2**) |

## Deploy files (ARM templates)

The templates live in [azure/arm/](../arm) (a sibling of this folder, so multiple
differently-named deployments can share them). Resource names, locations, versions, and
sizes are **parameters** — change a name by editing the matching `*.parameters.json`; no
template edits required.

| File | What it is |
| --- | --- |
| [azure/arm/main.template.json](../arm/main.template.json) | Parameterized ARM template — ACR + AKS + system node pool + ACR scope maps. **Deployable** (validated server-side; provide your own `sshPublicKey`). |
| [azure/arm/main.parameters.json](../arm/main.parameters.json) | Parameter values for `main.template.json` (defaults = the live `gin-test-001` config). |
| [azure/arm/mc-group.template.json](../arm/mc-group.template.json) | Parameterized ARM template for the `MC_...` node group (VMSS, VNet, NSG, LB, public IPs, identities, storage, disks). **Reference only** — AKS owns this group. |
| [azure/arm/mc-group.parameters.json](../arm/mc-group.parameters.json) | Parameter values for `mc-group.template.json`. |

### Parameters (`main.template.json`)

| Parameter | Default | Purpose |
| --- | --- | --- |
| `acrName` | `gentestfrs001` | Registry name (globally unique) |
| `acrLocation` | `eastus` | Registry region |
| `aksClusterName` | `gen-test-aks-001` | AKS cluster name |
| `aksLocation` | `eastus2` | AKS + `MC_` node group region |
| `kubernetesVersion` | `1.35` | Control-plane version |
| `nodeVmSize` | `Standard_D4as_v4` | System node pool VM size |
| `nodeCount` | `3` | System node pool node count |
| `dnsPrefix` | `aks-cluster` | API server DNS prefix |
| `sshPublicKey` | *(required — no default; provide your own)* | Linux node SSH public key |

`nodeResourceGroup` is **computed** — `MC_<resourceGroup().name>_<aksClusterName>_<aksLocation>`
— so the `MC_...` name tracks the parameters automatically.

### How these were built

Each group was exported, then the hardcoded names/locations were lifted into parameters:

```bash
az group export --resource-group gin-test-001 \
  --skip-resource-name-params --skip-all-params > main.template.json
az group export --resource-group MC_gin-test-001_gen-test-aks-001_eastus2 \
  --skip-resource-name-params --skip-all-params > mc-group.template.json
# then: names/locations/versions/sizes extracted into *.parameters.json and referenced
# via [parameters('...')]; runtime-only bits (the 3 agentPool `machines` instances and
# the pinned kubelet `identityProfile`) were removed from main so a fresh,
# differently-named cluster deploys cleanly.
```

Expected export warnings (not errors you need to fix):

- `gin-test-001`: `managedClusters/jwtAuthenticators` and `managedClusters/privateEndpointConnections`
  are not exportable.
- `MC_...`: `storageAccounts/advancedPlatformMetrics` and the AKS VM extensions
  (`AKSLinuxBilling`, `AKSNode`, `AzureMonitorLinuxAgent`) are not supported for template export.

---

## Resource inventory

### `gin-test-001` (11 resources in the live RG)

| # | Type | Name |
| --- | --- | --- |
| 1 | `Microsoft.ContainerRegistry/registries` | `gentestfrs001` |
| 2 | `Microsoft.ContainerService/managedClusters` | `gen-test-aks-001` |
| 3 | `Microsoft.ContainerService/managedClusters/agentPools` | `gen-test-aks-001/nodepool1` |
| 4 | `Microsoft.ContainerService/managedClusters/agentPools/machines` | `.../nodepool1/aks-nodepool1-21682923-vmss000003` |
| 5 | `Microsoft.ContainerService/managedClusters/agentPools/machines` | `.../nodepool1/...vmss000004` |
| 6 | `Microsoft.ContainerService/managedClusters/agentPools/machines` | `.../nodepool1/...vmss000005` |
| 7–11 | `Microsoft.ContainerRegistry/registries/scopeMaps` | `_repositories_admin`, `_repositories_pull`, `_repositories_pull_metadata_read`, `_repositories_push`, `_repositories_push_metadata_write` (built-in) |

> The deployable [main.template.json](../arm/main.template.json) keeps **8** of these — the
> three `agentPools/machines` (rows 4–6) are live VM instances AKS recreates, so they are
> excluded from the template.

### `MC_gin-test-001_gen-test-aks-001_eastus2` (52 resources exported)

| Type | Count | Names / notes |
| --- | --- | --- |
| `Microsoft.Compute/virtualMachineScaleSets` | 1 | `aks-nodepool1-21682923-vmss` — Standard_D4as_v4, capacity 3 |
| `Microsoft.Compute/virtualMachineScaleSets/virtualMachines` | 3 | instances `3`, `4`, `5` |
| `...virtualMachineScaleSets/extensions` (+ per-VM) | 16 | `AKSLinuxExtension`, `...AKSLinuxBilling`, `AzureMonitorLinuxAgent`, `vmssCSE` |
| `Microsoft.Network/virtualNetworks` | 1 | `aks-vnet-71981266` — `10.224.0.0/12` |
| `Microsoft.Network/virtualNetworks/subnets` | 3 | `aks-subnet` `10.224.0.0/16`, `aks-appgateway` `10.238.0.0/24`, `aks-virtualkubelet` `10.239.0.0/16` |
| `Microsoft.Network/networkSecurityGroups` | 1 | `aks-agentpool-71981266-nsg` |
| `Microsoft.Network/networkSecurityGroups/securityRules` | 9 | `k8s-azure-lb_allow_IPv4_...` + `NRMS-Rule-101,103,104,105,106,107,108,109` |
| `Microsoft.Network/loadBalancers` | 1 | `kubernetes` (Standard/Regional) |
| `Microsoft.Network/loadBalancers/backendAddressPools` | 2 | `aksOutboundBackendPool`, `kubernetes` |
| `Microsoft.Network/publicIPAddresses` | 4 | `284c3e5b-...` (outbound) + 3 `kubernetes-...` |
| `Microsoft.ManagedIdentity/userAssignedIdentities` | 3 | `gen-test-aks-001-agentpool` (kubelet), `azurepolicy-gen-test-aks-001`, `ext-2c26b415...-gen-test-aks-001` |
| `Microsoft.Storage/storageAccounts` (+ blob/file/queue/table services) | 1 (+4) | `fcb91418cd2264d62a1f842` — StorageV2, Standard_LRS |
| `Microsoft.Storage/storageAccounts/fileServices/shares` | 1 | `pvc-895ac0ee-...` — 16 GiB, TransactionOptimized (**Azure Files PV**) |
| `Microsoft.Compute/disks` | 1 | `pvc-87043df2-...` — StandardSSD_LRS, 16 GiB (**managed-disk PV**) |
| `Microsoft.KubernetesConfiguration/privateLinkScopes` | 1 | `extension-pls` (cluster extension manager) |

---

## Deployment steps (reproduce `gin-test-001` from scratch)

These `az` commands recreate the **exact observed configuration**. The `MC_...` group is
created automatically by Step 3 — you never author it.

### Step 0 — Variables & context

```bash
SUB=<your-subscription-id>   # your subscription
RG=gin-test-001
ACR=gentestfrs001
AKS=gen-test-aks-001
ACR_LOC=eastus         # ACR + RG metadata
AKS_LOC=eastus2        # AKS cluster + its MC_ node group

az account set --subscription "$SUB"
```

### Step 1 — Resource group  `[Microsoft.Resources/resourceGroups]`

```bash
az group create -n "$RG" -l "$ACR_LOC"
```

**VERIFY:** `az group show -n "$RG" --query properties.provisioningState -o tsv` → `Succeeded`.

### Step 2 — Azure Container Registry  `[Microsoft.ContainerRegistry/registries]`

Standard SKU, admin user enabled, public network access enabled.

```bash
az acr create -g "$RG" -n "$ACR" -l "$ACR_LOC" --sku Standard --admin-enabled true
```

**VERIFY:** `az acr show -n "$ACR" --query "{login:loginServer,sku:sku.name,admin:adminUserEnabled}"`
→ `gentestfrs001.azurecr.io`, `Standard`, `true`.

### Step 3 — AKS managed cluster  `[Microsoft.ContainerService/managedClusters]`

Kubernetes 1.35, 3× `Standard_D4as_v4` system nodes (128 GB managed OS disk, maxPods 250),
**Azure CNI overlay** dataplane, standard load balancer with 1 managed outbound IP, OIDC
issuer, and the **azure-policy** addon. System-assigned identity; RBAC enabled. This call
also creates `MC_gin-test-001_gen-test-aks-001_eastus2`.

```bash
az aks create -g "$RG" -n "$AKS" -l "$AKS_LOC" \
  --kubernetes-version 1.35 \
  --node-count 3 \
  --node-vm-size Standard_D4as_v4 \
  --node-osdisk-size 128 \
  --node-osdisk-type Managed \
  --os-sku Ubuntu \
  --max-pods 250 \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --network-dataplane azure \
  --network-policy none \
  --pod-cidr 10.244.0.0/16 \
  --service-cidr 10.0.0.0/16 \
  --dns-service-ip 10.0.0.10 \
  --load-balancer-sku standard \
  --outbound-type loadBalancer \
  --enable-oidc-issuer \
  --enable-addons azure-policy \
  --node-os-upgrade-channel NodeImage \
  --tier free \
  --generate-ssh-keys
```

**VERIFY:**

```bash
az aks show -g "$RG" -n "$AKS" --query \
  "{k8s:kubernetesVersion,state:provisioningState,nodeRG:nodeResourceGroup}" -o json
# expect: 1.35 / Succeeded / MC_gin-test-001_gen-test-aks-001_eastus2
```

### Step 4 — Cluster credentials

```bash
az aks get-credentials -g "$RG" -n "$AKS"
kubectl get nodes            # 3 nodes Ready
kubectl get storageclass     # azurefile-csi, managed-csi present
```

### Step 5 — (Observed extras created on demand)

The following in the `MC_...` group are created **lazily by the cluster**, not by the steps
above — recreate them only by running the corresponding workload:

- **Azure Files share** `pvc-895ac0ee-...` (16 GiB) — bound when a PVC uses
  `azurefile-csi` (the gitrest snapshot PV in this project).
- **Managed disk** `pvc-87043df2-...` (16 GiB, StandardSSD_LRS) — bound when a PVC uses
  `managed-csi` (e.g. the Mongo PV).
- Extra `kubernetes-*` public IPs / LB rules — created when a `Service type=LoadBalancer`
  is exposed.

---

## Deploy the parameterized ARM template (`main.template.json`)

Recreate the primary group from the captured template instead of the `az aks create` path
above. **Same names** (the defaults) — just point at the parameters file:

```bash
az group create -n gin-test-001 -l eastus
az deployment group create \
  --resource-group gin-test-001 \
  --template-file azure/arm/main.template.json \
  --parameters @azure/arm/main.parameters.json
```

**Different names** — override any parameter inline (no file edits):

```bash
az group create -n my-rg -l eastus
az deployment group create \
  --resource-group my-rg \
  --template-file azure/arm/main.template.json \
  --parameters @azure/arm/main.parameters.json \
      acrName=mycompanyacr001 \
      aksClusterName=my-aks \
      aksLocation=westus2
# nodeResourceGroup becomes MC_my-rg_my-aks_westus2 automatically.
```

> Do **not** `az deployment group create` the `mc-group.template.json` into a fresh group —
> AKS must own the node group. It (and its parameters file) is a **read-only record** of
> what the cluster provisioned; it is parameterized only so the captured names read cleanly.

---

## Teardown

Deleting the cluster (or the whole `gin-test-001` group) also deletes the `MC_...` group
automatically.

```bash
# Cluster only (also removes MC_ group):
az aks delete -g gin-test-001 -n gen-test-aks-001 --yes --no-wait

# Everything:
az group delete -n gin-test-001 --yes --no-wait
```
