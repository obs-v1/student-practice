#!/usr/bin/env bash
# Register the three lab datasources (Prometheus, Loki, Jaeger) in the running Grafana via its
# HTTP API — the one-shot version of the "add them by hand in the UI" step in docs/05. Uses the
# Grafana chart's admin password from the k8s secret + a port-forward, so it works regardless of
# the anonymous-auth settings.
#
#   scripts/add-datasources.sh
#
# Besides the three datasources it also wires the trace->logs CORRELATION so you can click
# straight across in Explore:
#   - Jaeger "Trace to logs" (tracesToLogsV2) -> Loki: the "Related logs" button opens Loki at the
#     span's time window; you narrow to the service by hand with {app="<service>"}.
# Why a time-window jump and not an automatic by-service/by-trace-id one (this IS the by-hand lesson):
#   - NOT by trace id: bankobs logs do not carry Jaeger's trace id (the Go/journey tier logs an app
#     trace_id that does not match Beyla's span ids; the Java core-banking tier logs only a
#     correlation_id), so a trace-id log search finds nothing.
#   - NOT automatically by service: the classic Jaeger datasource keeps a span's service in
#     process.serviceName, not as a span tag, and Grafana's trace->logs cannot read it (a service.name
#     tag map resolves to nothing, and the custom query has no serviceName variable). So the button can
#     only hand Loki a time window — you finish the hop yourself. (The OTEL module's collector makes
#     this one click; that contrast is why we do it by hand here.)
#
# Idempotent AND uid-stable: an existing datasource is UPDATED in place (uid preserved), so a
# re-run never breaks a dashboard already bound to it. Only a missing datasource is created.
#
# In-cluster URLs (monitoring namespace):
#   prometheus -> http://prometheus-server   (default datasource)
#   loki       -> http://loki:3100
#   jaeger     -> http://jaeger:16686
set -euo pipefail

NS="${OBS_NS:-monitoring}"

command -v kubectl >/dev/null || { echo "✗ kubectl not found"; exit 1; }
kubectl -n "$NS" get deploy grafana >/dev/null 2>&1 || { echo "✗ Grafana not found in '$NS' — run 'make grafana' first"; exit 1; }

PW="$(kubectl -n "$NS" get secret grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)"
[ -n "$PW" ] || { echo "✗ could not read Grafana admin password (secret/grafana)"; exit 1; }

kubectl -n "$NS" port-forward svc/grafana 3000:80 >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
sleep 5

GRAFANA_PW="$PW" python3 - <<'PY'
import json, os, base64, urllib.request, urllib.error, sys

BASE = "http://localhost:3000"
auth = "Basic " + base64.b64encode(b"admin:" + os.environ["GRAFANA_PW"].encode()).decode()

def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method,
                                 headers={"Authorization": auth, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, json.loads(r.read() or "{}")
    except urllib.error.HTTPError as e:
        try: return e.code, json.loads(e.read() or "{}")
        except Exception: return e.code, {}
    except Exception as e:
        return 0, {"message": str(e)}

# base datasources (names/urls kept in sync with docs/05 + golden-dashboard)
WANT = [
    {"name": "prometheus", "type": "prometheus", "access": "proxy", "url": "http://prometheus-server", "isDefault": True},
    {"name": "loki",       "type": "loki",       "access": "proxy", "url": "http://loki:3100"},
    {"name": "jaeger",     "type": "jaeger",      "access": "proxy", "url": "http://jaeger:16686"},
]

def upsert(ds, existing):
    cur = existing.get(ds["name"])
    if cur:
        body = {**ds, "id": cur["id"], "uid": cur["uid"]}
        st, resp = call("PUT", f"/api/datasources/uid/{cur['uid']}", body)
        return (st == 200), cur["uid"], resp
    st, resp = call("POST", "/api/datasources", ds)
    uid = (resp.get("datasource") or {}).get("uid")
    return (st in (200, 201) and bool(uid)), uid, resp

# pass 1 — create/update the three base datasources
_, existing = call("GET", "/api/datasources")
by_name = {d["name"]: d for d in (existing if isinstance(existing, list) else [])}
uids, rc = {}, 0
for ds in WANT:
    ok, uid, resp = upsert(ds, by_name)
    uids[ds["name"]] = uid
    print(f"  {'✓' if ok else '✗'} {ds['name']:11} -> {ds['url']}  ({'uid '+str(uid) if ok else resp.get('message', resp)})")
    rc = rc or (0 if ok else 1)

# pass 2 — wire trace->logs correlation now that the uids are known.
# The "Related logs" button opens Loki at the span's time window ({namespace="bankobs"}); you narrow
# to the service by hand with {app="<service>"}. We use a custom query, not a service.name->app tag
# map: the classic Jaeger datasource keeps the service in process.serviceName (not a span tag), so the
# tag map resolves to nothing and no link renders. filterByTraceID stays off — logs carry no trace id.
if uids.get("jaeger") and uids.get("loki") and uids.get("prometheus"):
    jbody = {**WANT[2], "uid": uids["jaeger"],
             "jsonData": {
                 "tracesToLogsV2": {
                     "datasourceUid": uids["loki"],
                     "spanStartTimeShift": "-5m", "spanEndTimeShift": "5m",
                     "filterByTraceID": False, "filterBySpanID": False,
                     "customQuery": True, "query": '{namespace="bankobs"}',
                 }}}
    st, _ = call("PUT", f"/api/datasources/uid/{uids['jaeger']}", jbody)
    print(f"  {'✓' if st==200 else '✗'} jaeger  Trace-to-logs -> loki  (opens Loki at the span window)  ({'ok' if st==200 else st})")
    rc = rc or (0 if st==200 else 1)

print("  all datasources registered + trace->logs wired (prometheus is the default)." if rc == 0
      else "  ⚠ something failed — see above.")
sys.exit(rc)
PY
