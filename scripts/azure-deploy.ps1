#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation and contributors. All rights reserved.
# Licensed under the MIT License.
#
# Reference deploy script for Routerlicious + Redpanda on AKS. Mirrors azure/README.md.
#
# HONEST STATUS: this automates the VALIDATED phases (1-5). Phase 6 (the client token
# Azure Function) is an OPEN item and is intentionally NOT automated here — the script
# stops and points you at azure/README.md. This creates BILLABLE Azure resources.
#
# Usage:
#   ./scripts/azure-deploy.ps1 -ResourceGroup fluid-selfhost-rg -Location eastus `
#       -AksName fluid-selfhost-aks -KeyVault myfluidkv `
#       -FluidServerDir ../FluidFramework/server -MongoConnString '<COSMOS_MONGO_CONNSTRING>'

param(
    [Parameter(Mandatory)] [string]$ResourceGroup,
    [string]$Location = "eastus",
    [Parameter(Mandatory)] [string]$AksName,
    [Parameter(Mandatory)] [string]$KeyVault,
    [string]$FluidServerDir = "../FluidFramework/server",
    [Parameter(Mandatory)] [string]$MongoConnString,
    [string]$ReleaseName = "fluid"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot

function Require-Cmd($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "'$name' is required but not on PATH." }
}
function Phase($n, $desc) { Write-Host "`n==== Phase $n — $desc ====" -ForegroundColor Cyan }

# --- Preflight ---------------------------------------------------------------
Require-Cmd az; Require-Cmd kubectl; Require-Cmd helm
$chart = Join-Path $FluidServerDir "routerlicious/kubernetes/routerlicious"
if (-not (Test-Path (Join-Path $chart "Chart.yaml"))) {
    throw "routerlicious Helm chart not found at '$chart'. Set -FluidServerDir to your FluidFramework 'server' directory."
}
Write-Host "This will create BILLABLE Azure resources in resource group '$ResourceGroup'." -ForegroundColor Yellow
$ok = Read-Host "Type 'yes' to continue"
if ($ok -ne "yes") { Write-Host "Aborted."; exit 1 }

# --- Phase 1: RG + AKS [VALIDATED] -------------------------------------------
Phase 1 "Resource group + AKS"
az group create -n $ResourceGroup -l $Location | Out-Null
az aks create -g $ResourceGroup -n $AksName --node-count 2 --generate-ssh-keys --tier free | Out-Null
az aks get-credentials -g $ResourceGroup -n $AksName --overwrite-existing | Out-Null
kubectl get nodes
if ($LASTEXITCODE -ne 0) { throw "AKS credentials/nodes check failed." }

# --- Phase 3: in-cluster backends + broker [VALIDATED] -----------------------
# (Phase 2, managed Cosmos for MongoDB, is assumed already provisioned; pass its
#  connection string via -MongoConnString. See azure/README.md Phase 2.)
Phase 3 "In-cluster backends + Redpanda"
kubectl apply -f (Join-Path $repo "azure/redpanda.yaml")
kubectl apply -f (Join-Path $repo "azure/backends.yaml")

# --- Phase 4: Key Vault secrets [VALIDATED] ----------------------------------
Phase 4 "Key Vault secrets"
az keyvault create -g $ResourceGroup -n $KeyVault -l $Location 2>$null | Out-Null
$tenantKey = -join ((1..64) | ForEach-Object { "0123456789abcdef"[(Get-Random -Max 16)] })
az keyvault secret set --vault-name $KeyVault -n fluid-tenant-key --value $tenantKey | Out-Null
az keyvault secret set --vault-name $KeyVault -n mongo-connstring --value $MongoConnString | Out-Null
Write-Host "Stored fluid-tenant-key and mongo-connstring in Key Vault '$KeyVault'."

# --- Phase 5: Helm install routerlicious [VALIDATED] -------------------------
Phase 5 "Deploy Routerlicious (Helm)"
$key   = az keyvault secret show --vault-name $KeyVault -n fluid-tenant-key  --query value -o tsv
$mongo = az keyvault secret show --vault-name $KeyVault -n mongo-connstring --query value -o tsv
helm upgrade --install $ReleaseName $chart `
    -f (Join-Path $repo "azure/routerlicious-values.yaml") `
    --set-string "alfred.key=$key"  --set-string "nexus.key=$key" `
    --set-string "alfred.tenants[0].key=$key" --set-string "nexus.tenants[0].key=$key" `
    --set-string "riddler.tenants[0].key=$key" `
    --set-string "mongodb.operationsDbEndpoint=$mongo"
Write-Host "Waiting ~30s for pods to schedule..."; Start-Sleep -Seconds 30
kubectl get pods

# --- Phase 6: token Azure Function [OPEN] ------------------------------------
Phase 6 "Client token Azure Function [OPEN — not automated]"
Write-Warning @"
Phase 6 (the client token Azure Function) is an OPEN item and is not automated here.
Publishing/connecting the Function is the step still being worked out. Follow
azure/README.md -> Phase 6 manually, and treat it as the deployment engineering
review item. The rest of the stack (phases 1-5) should now be running.
"@

Write-Host "`nDone (phases 1-5). Next: expose ingress + TLS and complete Phase 6/7 per azure/README.md." -ForegroundColor Green
