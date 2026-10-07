# Section 2 — Metrics with Prometheus (the pull model)

**Goal:** stand up Prometheus and have it collect metrics from every bankobs service —
**without OpenTelemetry**. Prometheus will reach into the app and *pull* `/metrics` on a
timer. The app pushes nothing.

**Run it:** `make metrics`  (or `make metrics DRY=1`)

---

## The one idea: Prometheus pulls

This is the opposite of how the OTel course does it. There, each service *pushes* metrics as
OTLP to a Collector. Here, **Prometheus pulls**: on a schedule (every 15s) it makes an HTTP
GET to each target's `/metrics` and stores whatever numbers come back. The app doesn't know
Prometheus exists. It just exposes a page of numbers and goes about its business.

For that to work Prometheus needs two things, which are the two files you'll apply:

1. **Who to ask** — a *scrape config* telling it how to find the targets.
2. **Permission to look** — RBAC, so it can ask the Kubernetes API "what pods exist?"

## The steps (what `make metrics` runs)

**1. A home for the backends**
```bash
kubectl apply -f metrics/namespace.yaml          # creates the `monitoring` namespace
```

**2. Let Prometheus discover pods** — it finds targets by asking the Kubernetes API, so it
needs read access (this is *service discovery*):
```bash
kubectl apply -f metrics/prometheus-rbac.yaml    # ServiceAccount + ClusterRole + binding
```

**3. The scrape config** — the heart of the pull model. Open
[`metrics/prometheus-config.yaml`](../metrics/prometheus-config.yaml) and read the
`bankobs-pods` job. In plain English its `relabel_configs` say:
- discover **every** pod in the cluster, then
- **keep** only those in the `bankobs` namespace, then
- **keep** only those with the annotation `prometheus.io/scrape: "true"`, then
- scrape them at the `prometheus.io/path` (`/metrics`) on the `prometheus.io/port`.
```bash
kubectl apply -f metrics/prometheus-config.yaml
```

**4. The Prometheus server itself:**
```bash
kubectl apply -f metrics/prometheus.yaml
kubectl -n monitoring rollout status deploy/prometheus --timeout=120s
```

**5. Configure the app to BE monitored.** This is the "configure the chart so the app is
scraped" step. The bankobs pods expose `/metrics` already; here we assert the opt-in
annotation on every service so Prometheus's rule (step 3) matches them:
```bash
kubectl -n bankobs get deploy -l domain -o name \
 | xargs -I{} kubectl -n bankobs patch {} --type=merge \
     -p '{"spec":{"template":{"metadata":{"annotations":{"prometheus.io/scrape":"true","prometheus.io/path":"/metrics"}}}}}'
```
> In a from-scratch Helm chart, this annotation block in the pod template *is* the one piece
> of config that opts a service into Prometheus. That's the whole integration — an annotation
> and a scrape rule. No SDK, no exporter in the app.

## See it work

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

## What you just proved

Metrics needed **zero** OpenTelemetry. The app exposed a `/metrics` page (a decades-old
convention), and a pull-based scraper collected it. Hold that thought — logs will be just as
OTel-free. Traces won't.

➡ Next: [03-logs-loki.md](03-logs-loki.md) — `make logs`
