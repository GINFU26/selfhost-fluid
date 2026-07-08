#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation and contributors. All rights reserved.
# Licensed under the MIT License.
#
# Smoke test: verify the stack is up and the ingress responds through the proxy.

param([string]$ComposeFile)

$root = Split-Path -Parent $PSScriptRoot
if (-not $ComposeFile) { $ComposeFile = Join-Path $root "docker-compose.redpanda.yml" }
$compose = $ComposeFile
$fail = 0

Write-Host "== Container status ==" -ForegroundColor Cyan
docker compose -f $compose ps

Write-Host "`n== Ingress checks ==" -ForegroundColor Cyan
$checks = @(
    @{ Name = "alfred REST   (3003)"; Url = "http://127.0.0.1:3003/healthz/startup" },
    @{ Name = "historian     (3001)"; Url = "http://127.0.0.1:3001/healthz/startup" }
)
foreach ($c in $checks) {
    try {
        $r = Invoke-WebRequest -Uri $c.Url -TimeoutSec 5 -UseBasicParsing
        if ($r.StatusCode -eq 200) { Write-Host ("PASS  {0} -> 200" -f $c.Name) -ForegroundColor Green }
        else { Write-Host ("FAIL  {0} -> {1}" -f $c.Name, $r.StatusCode) -ForegroundColor Red; $fail++ }
    } catch {
        Write-Host ("FAIL  {0} -> {1}" -f $c.Name, $_.Exception.Message) -ForegroundColor Red; $fail++
    }
}

Write-Host ""
if ($fail -eq 0) {
    Write-Host "SMOKE PASS - stack is up." -ForegroundColor Green
    Write-Host "  REST + websocket     : http://localhost:3003"
    Write-Host "  Storage (historian)  : http://localhost:3001"
    Write-Host "  Tenant mgr (riddler) : http://localhost:5000"
    Write-Host ""
    Write-Host "For a full functional check, run the Fluid client e2e suite against this"
    Write-Host "stack with the r11s 'docker' driver (see README -> Validation)."
    exit 0
} else {
    Write-Host "SMOKE FAIL - $fail check(s) failed. Inspect logs:" -ForegroundColor Red
    Write-Host "  docker compose -f docker-compose.redpanda.yml logs --tail=100"
    exit 1
}
