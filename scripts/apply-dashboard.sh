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

# Discover the Prometheus datasource (prefer the default one) so we can BIND the dashboard's
# $datasource variable to a real uid — otherwise it imports empty and every panel reads
# "datasource not found".
DSJSON="$(curl -s -u "admin:$PW" http://localhost:3000/api/datasources || echo '[]')"
read -r DSUID DSNAME <<EOF
$(printf '%s' "$DSJSON" | python3 -c "
import sys,json
ds=[d for d in json.load(sys.stdin) if d.get('type')=='prometheus']
if not ds: print(''); sys.exit()
d=next((x for x in ds if x.get('isDefault')), ds[0])
print(d['uid'], d.get('name','Prometheus'))
")
EOF
[ -n "$DSUID" ] && echo "  binding dashboards to Prometheus datasource: $DSNAME ($DSUID)" \
                || echo "  ⚠ no Prometheus datasource found — add one in Grafana (docs/05) or run 'make correlation'"

# Public Jaeger UI host for the Errors-dashboard "Error traces for <service>" link (JAEGER_HOST
# placeholder). Grafana Explore can't reliably carry the Jaeger service in its URL, so the link
# opens the Jaeger UI search directly — which needs an absolute, browser-reachable host:port.
JHOST="$(curl -s -m2 -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null \
         | { read -r t; [ -n "$t" ] && curl -s -m2 -H "X-aws-ec2-metadata-token: $t" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null; })"
[ -z "$JHOST" ] && JHOST="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)"
[ -z "$JHOST" ] && JHOST="localhost"
JHOST="$JHOST:16686"
echo "  Errors 'Error traces' drill-down links -> Jaeger UI at http://$JHOST"

for FILE in "$@"; do
  # wrap as the API expects: {dashboard: {...}, overwrite: true}; inject the real DS uid into
  # the $datasource variable's "current" so the panels bind on load.
  BODY="$(DSUID="$DSUID" DSNAME="$DSNAME" JHOST="$JHOST" python3 -c "
import json,os,sys
d=json.load(open('$FILE'))
uid=os.environ.get('DSUID'); name=os.environ.get('DSNAME') or 'Prometheus'
if uid:
    for v in d.get('templating',{}).get('list',[]):
        if v.get('name')=='datasource' and v.get('type')=='datasource':
            v['current']={'selected':True,'text':name,'value':uid}
body=json.dumps({'dashboard':d,'overwrite':True,'folderId':0})
jh=os.environ.get('JHOST')
if jh: body=body.replace('JAEGER_HOST', jh)   # point the Errors drill-down link at this box's Jaeger UI
print(body)
")"
  RESP="$(curl -s -u "admin:$PW" -H 'Content-Type: application/json' \
    -X POST http://localhost:3000/api/dashboards/db -d "$BODY")"
  echo "$RESP" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(('✓ applied: '+str(d.get('url'))) if d.get('status')=='success' else ('✗ failed: '+json.dumps(d)))
import sys as _s; _s.exit(0 if d.get('status')=='success' else 1)
"
done
