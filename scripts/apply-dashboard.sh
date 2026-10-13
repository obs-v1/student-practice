#!/usr/bin/env bash
# Apply one or more dashboard JSON files to the running Grafana via its HTTP API
# (POST /api/dashboards/db). Uses the Grafana chart's admin password from the k8s secret + a
# port-forward, so it works regardless of anonymous settings.
#
#   scripts/apply-dashboard.sh grafana/golden-signals.json grafana/errors.json
set -euo pipefail

NS="${OBS_NS:-monitoring}"
[ "$#" -ge 1 ] || { echo "usage: apply-dashboard.sh <dashboard.json> [more.json ...]"; exit 2; }
for f in "$@"; do [ -f "$f" ] || { echo "✗ not found: $f"; exit 1; }; done

command -v kubectl >/dev/null || { echo "✗ kubectl not found"; exit 1; }
kubectl -n "$NS" get deploy grafana >/dev/null 2>&1 || { echo "✗ Grafana not found in '$NS' — run 'make grafana' first"; exit 1; }

PW="$(kubectl -n "$NS" get secret grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)"
[ -n "$PW" ] || { echo "✗ could not read Grafana admin password (secret/grafana)"; exit 1; }

kubectl -n "$NS" port-forward svc/grafana 3000:80 >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
sleep 5

for FILE in "$@"; do
  # wrap the dashboard model as the API expects: {dashboard: {...}, overwrite: true}
  BODY="$(python3 -c "import json;print(json.dumps({'dashboard':json.load(open('$FILE')),'overwrite':True,'folderId':0}))")"
  RESP="$(curl -s -u "admin:$PW" -H 'Content-Type: application/json' \
    -X POST http://localhost:3000/api/dashboards/db -d "$BODY")"
  echo "$RESP" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(('✓ applied: '+str(d.get('url'))) if d.get('status')=='success' else ('✗ failed: '+json.dumps(d)))
import sys as _s; _s.exit(0 if d.get('status')=='success' else 1)
"
done
