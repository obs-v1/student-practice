# Section 3 — Logs with Loki + Promtail

**Goal:** collect every bankobs service's logs into Loki — **without OpenTelemetry** and
**without touching the app**. The app already writes to stdout; we just go and read it.

**Run it:** `make logs`  (or `make logs DRY=1`)

---

## The one idea: the logs are already on disk

When a container writes to stdout, Kubernetes captures it into a file on the node
(`/var/log/pods/...`). So the logs already exist as plain files — we don't need the app to
*send* anything. We just need an agent on each node that:

1. **tails** those files,
2. attaches **labels** (which namespace / app / pod this line came from), and
3. **pushes** the lines to a store.

That agent is **Promtail**. The store is **Loki**. Loki is "Prometheus for logs": it indexes
only the labels (cheap) and keeps the raw line compressed — so you query by label
(`{app="upi-service"}`) and then grep within.

```
 app → stdout → /var/log/pods/*.log  →  Promtail (tails, labels)  →  Loki (stores)
```

Nothing here is OpenTelemetry, and the app is a bystander.

## The steps (what `make logs` runs)

**1. Let Promtail discover pods** (same service-discovery idea as Prometheus, so it can label
each log line with its pod):
```bash
kubectl apply -f logs/promtail-rbac.yaml
```

**2. Loki — the store:**
```bash
kubectl apply -f logs/loki.yaml
kubectl -n monitoring rollout status deploy/loki --timeout=120s
```

**3. Promtail's config** — the log equivalent of a scrape config. Open
[`logs/promtail-config.yaml`](../logs/promtail-config.yaml): it keeps only the `bankobs`
namespace, attaches `namespace` / `app` / `domain` / `pod` / `log_format` labels, and points
`clients.url` at Loki's push endpoint.
```bash
kubectl apply -f logs/promtail-config.yaml
```

**4. Promtail — one pod per node** (a DaemonSet, because log files live on the node's disk;
it mounts `/var/log` read-only):
```bash
kubectl apply -f logs/promtail.yaml
kubectl -n monitoring rollout status daemonset/promtail --timeout=120s
```

Notice step 2–4 touched **only** the backends. There was no "configure the app" step like
metrics had — because logs require nothing from the app at all.

## See it work

Generate some traffic first so there are fresh logs, then query Loki:

```bash
make traffic            # ~60s of portal journeys
make verify-logs        # prints which app services are landing in Loki
```

Loki has no UI of its own. Two ways to read it:
- **API** (what `verify-logs` uses):
  ```bash
  kubectl -n monitoring port-forward svc/loki 3100:3100 &
  # which services are reporting?
  curl -s 'http://localhost:3100/loki/api/v1/label/app/values' | jq
  # last 5 min of one service's logs:
  curl -s --get 'http://localhost:3100/loki/api/v1/query_range' \
    --data-urlencode 'query={app="upi-service"}' | jq '.data.result[].values[][1]' | head
  ```
- **Grafana Explore**, if you add a Grafana with Loki as a datasource — the usual way you'd
  *view* logs in production. Out of scope for this "core" lab, but that's where this leads.

The `log_format` label (`json` or `raw`) is carried through from the chart, so you can see
which services emit structured JSON vs plain text — useful when you later parse them.

## What you just proved

Two pillars down, **zero** OpenTelemetry. Metrics: the app exposed `/metrics`, Prometheus
pulled. Logs: the app wrote stdout, Promtail tailed. In both cases the collector lives outside
the app and reaches in. Now comes the pillar where that is **impossible**.

➡ Next: [04-traces-jaeger.md](04-traces-jaeger.md) — `make traces`
