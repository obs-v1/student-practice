# 2. Metrics with Prometheus

**Goal:** stand up Prometheus and have it collect metrics from every bankobs service —
**without OpenTelemetry**. Prometheus will reach into the app and *pull* `/metrics` on a
timer. The app pushes nothing.

**Run it:** `make metrics`  (or `make metrics DRY=1`)

---

## Prometheus pulls, the app doesn't push

This is the opposite of how the OTel course does it. There, each service *pushes* metrics as
OTLP to a Collector. Here, **Prometheus pulls**: on a schedule (every 15s) it makes an HTTP
GET to each target's `/metrics` and stores whatever numbers come back. The app doesn't know
Prometheus exists. It just exposes a page of numbers and goes about its business.

Prometheus finds its targets by *service discovery* — it asks the Kubernetes API "what pods
exist?" and scrapes the ones that opt in with the `prometheus.io/scrape: "true"` annotation
(bankobs pods already carry it). The rules for that live in a **scrape config**.

## Setting it up

We install Prometheus with its Helm chart — one command instead of hand-writing the
namespace, RBAC, config and Deployment. The chart brings its own ServiceAccount + RBAC (for
pod discovery) and the server; our [`metrics/values.yaml`](../metrics/values.yaml) keeps it
lean (server only) and supplies the scrape config.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community

helm upgrade --install prometheus prometheus-community/prometheus \
  -n monitoring --create-namespace -f metrics/values.yaml

kubectl -n monitoring rollout status deploy/prometheus-server
```

Open [`metrics/values.yaml`](../metrics/values.yaml) and read the `bankobs-pods` scrape job —
that's the pull model in config form. In plain English its `relabel_configs` say: discover
every pod, **keep** only those in the `bankobs` namespace with `prometheus.io/scrape: "true"`,
and scrape them at their `prometheus.io/path` on their `prometheus.io/port`. No SDK, no
exporter in the app — just a scraper reaching in.

## Check Prometheus

```bash
make verify-metrics          # prints how many bankobs targets are UP
```
Open the UI (`make urls` → Prometheus, default `http://<node>:30909`):
- **Status → Targets** — the `bankobs-pods` job, one target per service, `UP`.
- **Graph** — try `up{namespace="bankobs"}` (1 = scraped OK), or a real app metric like
  `http_server_requests_seconds_count`.

If targets are `DOWN`, the usual causes: the pod isn't exposing `/metrics` on the annotated
port, or the annotation/port don't match. Check one pod:
`kubectl -n bankobs get pod <name> -o jsonpath='{.metadata.annotations}'`.

## Recap

Metrics needed **zero** OpenTelemetry. The app exposed a `/metrics` page (a decades-old
convention), and a pull-based scraper collected it. Hold that thought — logs will be just as
OTel-free. Traces won't.

➡ Next: [03-logs-loki.md](03-logs-loki.md) — `make logs`
