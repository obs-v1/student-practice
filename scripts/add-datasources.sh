#!/usr/bin/env bash
# Register the three lab datasources (Prometheus, Loki, Jaeger) in the running Grafana via its
# HTTP API — the one-shot version of the "add them by hand in the UI" step in docs/05. Uses the
# Grafana chart's admin password from the k8s secret + a port-forward, so it works regardless of
# the anonymous-auth settings.
#
#   scripts/add-datasources.sh
#
# Idempotent AND uid-stable: if a datasource with the same name already exists it is UPDATED in
# place (its uid is preserved), so re-running does not break a Golden Signals dashboard that is
# already bound to that uid. Only a missing datasource is created fresh.
#
# The URLs are the in-cluster service names the backends install under (monitoring namespace):
#   prometheus -> http://prometheus-server   (set as the default datasource)
#   loki       -> http://loki:3100
#   jaeger     -> http://jaeger:16686
# These match docs/05 and what `make golden-dashboard` expects (it binds to the default
# Prometheus datasource). For the trace<->logs correlation links on top of these, use
# `make correlation`.
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
import json, os, sys, urllib.request, base64

BASE = "http://localhost:3000"
auth = "Basic " + base64.b64encode(b"admin:" + os.environ["GRAFANA_PW"].encode()).decode()

# desired datasources — keep names/urls in sync with docs/05 and golden-dashboard
WANT = [
    {"name": "prometheus", "type": "prometheus", "access": "proxy", "url": "http://prometheus-server", "isDefault": True},
    {"name": "loki",       "type": "loki",       "access": "proxy", "url": "http://loki:3100"},
    {"name": "jaeger",     "type": "jaeger",      "access": "proxy", "url": "http://jaeger:16686"},
]

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

# map existing datasources by name
_, existing = call("GET", "/api/datasources")
by_name = {d["name"]: d for d in (existing if isinstance(existing, list) else [])}

rc = 0
for ds in WANT:
    cur = by_name.get(ds["name"])
    if cur:  # UPDATE in place — preserve id + uid so bound dashboards keep working
        body = {**ds, "id": cur["id"], "uid": cur["uid"]}
        st, resp = call("PUT", f"/api/datasources/uid/{cur['uid']}", body)
        ok = st == 200
        print(f"  {'✓' if ok else '✗'} {ds['name']:11} -> {ds['url']}  (updated, uid {cur['uid']})"
              if ok else f"  ✗ {ds['name']}: {resp.get('message', resp)}")
    else:    # CREATE
        st, resp = call("POST", "/api/datasources", ds)
        ok = st in (200, 201) and (resp.get("datasource") or resp.get("id"))
        uid = (resp.get("datasource") or {}).get("uid", "?")
        print(f"  {'✓' if ok else '✗'} {ds['name']:11} -> {ds['url']}  (created, uid {uid})"
              if ok else f"  ✗ {ds['name']}: {resp.get('message', resp)}")
    rc = rc or (0 if ok else 1)

print("  all datasources registered (prometheus is the default)." if rc == 0
      else "  ⚠ one or more datasources failed — see above.")
sys.exit(rc)
PY
