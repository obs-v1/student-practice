# 3. Logs with Loki and Promtail

**Goal:** collect every bankobs service's logs into Loki — **without OpenTelemetry** and
**without touching the app**. The app already writes to stdout; we just go and read it.

**Run it:** `make logs`  (or `make logs DRY=1`)

---

## The logs are already on disk

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

## Setting it up

Loki and Promtail both come from one Helm chart — **`grafana/loki-stack`** installs the store
(Loki) *and* the agent (Promtail) together, so this is a single command. Promtail is a
DaemonSet (one pod per node, mounting `/var/log`); Loki is a StatefulSet. Our
[`logs/values.yaml`](../logs/values.yaml) keeps it lab-sized (filesystem storage, no PVC),
turns off the Grafana/Prometheus sub-charts the chart bundles (this lab has its own), and
exposes Loki's API as a **NodePort** (`3100` → `30310`, mapped to the host by
`cluster/kind-config.yaml`).

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update grafana

helm upgrade --install loki grafana/loki-stack \
  -n monitoring --create-namespace -f logs/values.yaml

kubectl -n monitoring rollout status statefulset/loki
```

That's it — **no "configure the app" step** like metrics had. Promtail finds every pod on the
node, tails its container log file, attaches labels (`namespace`, `app`, `pod`, `container`,
…), and pushes to Loki. The app never knew.

## Check Loki

Generate some traffic first so there are fresh logs, then query Loki:

```bash
make traffic            # ~60s of portal journeys
make verify-logs        # prints which app services are landing in Loki
```

Loki has no UI of its own — reach its HTTP API on the NodePort (`make urls` → Loki API,
`http://<box>:3100`) or via a port-forward:
```bash
# which services are reporting?
curl -s 'http://<box>:3100/loki/api/v1/label/app/values' | jq

# last few lines of one service:
curl -s --get 'http://<box>:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={namespace="bankobs", app="upi-service"}' \
  | jq '.data.result[].values[][1]' | head
```

To actually *view* logs you'd point Grafana at Loki — the optional
[`correlation/`](../correlation/README.md) module (`make correlation`) does exactly that, and
links each log line's `trace_id` straight to the trace in Jaeger.

## Two pillars down, still no OTel

Two pillars down, **zero** OpenTelemetry. Metrics: the app exposed `/metrics`, Prometheus
pulled. Logs: the app wrote stdout, Promtail tailed. In both cases the collector lives outside
the app and reaches in. Now comes the pillar where that is **impossible**.

➡ Next: [04-traces-jaeger.md](04-traces-jaeger.md) — `make traces`
