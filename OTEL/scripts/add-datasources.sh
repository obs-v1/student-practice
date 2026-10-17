#!/usr/bin/env bash
# Register the three lab datasources (Prometheus, Loki, Jaeger) in the running Grafana via its
# HTTP API, and wire trace<->logs correlation — the OTEL-module variant of the parent
# ../scripts/add-datasources.sh.
#
#   OBS_NS=monitoring bash OTEL/scripts/add-datasources.sh
#
# WHY A SEPARATE SCRIPT (correlation differs from the by-hand lab):
#   In this module logs are collected by the Collector's filelog receiver and land in Loki with
#   k8s_* stream labels (k8s_container_name = the service name). The app's JSON logs carry a
#   `correlation_id`, NOT an OTel `trace_id`, so we CANNOT join a trace to its logs by trace id.
#   Instead we correlate by SERVICE + TIME WINDOW: clicking a span opens Loki filtered to that
#   service's logs ({k8s_container_name="<service>"}) around the span's time. That is the honest,
#   working correlation for an app whose logs predate trace-id injection.
#
# In-cluster URLs (monitoring namespace): prometheus -> http://prometheus-server (default),
# loki -> http://loki:3100, jaeger -> http://jaeger:16686.
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

_, existing = call("GET", "/api/datasources")
by_name = {d["name"]: d for d in (existing if isinstance(existing, list) else [])}
uids, rc = {}, 0
for ds in WANT:
    ok, uid, resp = upsert(ds, by_name)
    uids[ds["name"]] = uid
    print(f"  {'✓' if ok else '✗'} {ds['name']:11} -> {ds['url']}  ({'uid '+str(uid) if ok else resp.get('message', resp)})")
    rc = rc or (0 if ok else 1)

# Correlation: Jaeger "Trace to logs" -> Loki, BY SERVICE (not trace id). Grafana maps the span's
# service.name to the Loki stream label k8s_container_name and opens the logs for that service in
# the span's time window.
if uids.get("jaeger") and uids.get("loki"):
    jbody = {**WANT[2], "uid": uids["jaeger"],
             "jsonData": {
                 "tracesToLogsV2": {
                     "datasourceUid": uids["loki"],
                     "spanStartTimeShift": "-2m", "spanEndTimeShift": "2m",
                     "filterByTraceID": False, "filterBySpanID": False,
                     "tags": [{"key": "service.name", "value": "k8s_container_name"}],
                 }}}
    st, _ = call("PUT", f"/api/datasources/uid/{uids['jaeger']}", jbody)
    print(f"  {'✓' if st==200 else '✗'} jaeger  Trace-to-logs -> loki (by service: k8s_container_name)  ({'ok' if st==200 else st})")
    rc = rc or (0 if st==200 else 1)

    # Loki -> Jaeger derived field: surface correlation_id (the app's request id) as a clickable
    # field. It is NOT a trace id, so it does not deep-link into a trace, but it lets you pivot
    # from a log line to every other line of the same request.
    lbody = {**WANT[1], "uid": uids["loki"],
             "jsonData": {
                 "derivedFields": [{
                     "name": "correlation_id",
                     "matcherRegex": r'"correlation_id":"([^"]+)"',
                     "url": "",
                 }]}}
    st, _ = call("PUT", f"/api/datasources/uid/{uids['loki']}", lbody)
    print(f"  {'✓' if st==200 else '✗'} loki    Derived-field correlation_id  ({'ok' if st==200 else st})")
    rc = rc or (0 if st==200 else 1)

print("  datasources registered + trace->logs wired by service (prometheus is the default)." if rc == 0
      else "  ⚠ something failed — see above.")
sys.exit(rc)
PY
