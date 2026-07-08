#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation and contributors. All rights reserved.
# Licensed under the MIT License.
#
# Smoke test: verify the stack is up and the ingress responds through the proxy.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${1:-$ROOT/docker-compose.redpanda.yml}"
fail=0

echo "== Container status =="
docker compose -f "$COMPOSE" ps

echo ""
echo "== Ingress checks =="
check() {
  local name="$1" url="$2" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" || echo 000)"
  if [ "$code" = "200" ]; then
    echo "PASS  $name -> 200"
  else
    echo "FAIL  $name -> $code"
    fail=$((fail+1))
  fi
}
check "alfred REST   (3003)" "http://127.0.0.1:3003/healthz/startup"
check "historian     (3001)" "http://127.0.0.1:3001/healthz/startup"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "SMOKE PASS - stack is up."
  echo "  REST + websocket     : http://localhost:3003"
  echo "  Storage (historian)  : http://localhost:3001"
  echo "  Tenant mgr (riddler) : http://localhost:5000"
  echo ""
  echo "For a full functional check, run the Fluid client e2e suite against this"
  echo "stack with the r11s 'docker' driver (see README -> Validation)."
  exit 0
else
  echo "SMOKE FAIL - $fail check(s) failed. Inspect logs:"
  echo "  docker compose -f docker-compose.redpanda.yml logs --tail=100"
  exit 1
fi
