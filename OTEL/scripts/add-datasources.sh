#!/usr/bin/env bash
# Register the three lab datasources (Prometheus, Loki, Jaeger) in the running Grafana via its
# HTTP API, and wire trace<->logs correlation — the OTEL-module variant of the parent
# ../scripts/add-datasources.sh.
#
#   OBS_NS=monitoring bash OTEL/scripts/add-datasources.sh
#
# WHY A SEPARATE SCRIPT (two OTEL-specific differences from the by-hand ../scripts/add-datasources.sh):
#   (1) Loki stream labels here are k8s_* (the Collector's loki exporter), so the namespace label is
#       k8s_namespace_name and the service label is k8s_container_name (not `namespace`/`app`).
#   (2) The Collector wraps each log line as {"body":"<escaped JSON>"}, so a trace id appears as
#       \"trace_id\":\"<hex>\" — the derived-field regex must match THROUGH the escaping.
# Correlation is BY TRACE ID, both directions (same as the by-hand lab): a span's "Related logs"
# button queries Loki for the span's trace id, and a log line's trace_id links back to its Jaeger
# trace. COVERAGE: every bankobs tier is OTel-instrumented in code and stamps the span's trace id into
# its own logs, so the exact-request jump resolves across the board — the journey tier (loan-origination,
# ...), the Java/Python tiers, AND the Go payment tier (gateway-service/payment-gateway/upi-service via
# the shared Go SDK, once OBSERVABILITY_MODE=full — set by `make enable-annotations-to-deploy`; verified
# a gateway-service trace id -> its Loki logs). The only EMPTY case is per-request — a trace whose
# service didn't write a log line for it — where you drop the `|= "<id>"` and narrow by
# {k8s_container_name="<service>"}. KEY lesson: the Collector FORWARDS the app's logs — the trace id in
# them comes from the app's own instrumentation, not the Collector.
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

# Correlation BY TRACE ID, both directions (see header for the coverage caveat).
if uids.get("jaeger") and uids.get("loki"):
    # Jaeger -> Loki (trace -> logs): query Loki for the span's trace id. `|=` substring-matches the
    # hex inside the Collector's {"body":"..."} envelope; namespace label here is k8s_namespace_name.
    jbody = {**WANT[2], "uid": uids["jaeger"],
             "jsonData": {
                 "tracesToLogsV2": {
                     "datasourceUid": uids["loki"],
                     "spanStartTimeShift": "-5m", "spanEndTimeShift": "5m",
                     "filterByTraceID": False, "filterBySpanID": False,
                     "customQuery": True,
                     "query": '{k8s_namespace_name="bankobs"} |= "${__trace.traceId}"',
                 }}}
    st, _ = call("PUT", f"/api/datasources/uid/{uids['jaeger']}", jbody)
    print(f"  {'✓' if st==200 else '✗'} jaeger  Trace-to-logs -> loki  (query Loki for the trace id)  ({'ok' if st==200 else st})")
    rc = rc or (0 if st==200 else 1)

    # Loki -> Jaeger (logs -> trace): the body is wrapped+escaped, so trace_id reads \"trace_id\":\"<hex>\".
    # `trace_id\W+(\w+)` matches the id through the \":\" separators (the by-hand '"trace_id":"..."' does not).
    lbody = {**WANT[1], "uid": uids["loki"],
             "jsonData": {
                 "derivedFields": [{
                     "name": "TraceID",
                     "matcherRegex": r'trace_id\W+(\w+)',
                     "url": "${__value.raw}",
                     "datasourceUid": uids["jaeger"],
                 }]}}
    st, _ = call("PUT", f"/api/datasources/uid/{uids['loki']}", lbody)
    print(f"  {'✓' if st==200 else '✗'} loki    Derived-field trace_id -> jaeger  ({'ok' if st==200 else st})")
    rc = rc or (0 if st==200 else 1)

print("  datasources registered + trace<->logs wired by trace id (prometheus is the default)." if rc == 0
      else "  ⚠ something failed — see above.")
sys.exit(rc)
PY
