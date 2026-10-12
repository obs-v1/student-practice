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
exist?" and scrapes only the ones that opt in with the `prometheus.io/scrape: "true"`
annotation. The rules for that live in a **scrape config**.

Here's the deliberate part: **the bankobs services ship WITHOUT that annotation.** Deploy
Prometheus and it scrapes *nothing* from bankobs — because no service has opted in yet.
Bringing a service under monitoring is *your* job, and that's the whole exercise.

## 1. Install Prometheus

One Helm command instead of hand-writing the namespace, RBAC, config and Deployment. The chart
brings its own ServiceAccount + RBAC (for pod discovery) and the server;
[`metrics/values.yaml`](../metrics/values.yaml) keeps it lean (server only) and supplies the
scrape config.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community

helm upgrade --install prometheus prometheus-community/prometheus \
  -n monitoring --create-namespace -f metrics/values.yaml

kubectl -n monitoring rollout status deploy/prometheus-server
```

Open [`metrics/values.yaml`](../metrics/values.yaml) and read the `bankobs-pods` scrape job —
the pull model in config form: discover every pod, **keep** only those in `bankobs` with
`prometheus.io/scrape: "true"`, scrape them at their `prometheus.io/path` on their
`prometheus.io/port`. Right now that keeps **zero** pods, because none are annotated.

## 2. Opt a service into monitoring (your part)

Each bankobs service is its own small chart under
[`bankobs/helm/bankobserve360/charts/`](../bankobs/helm/bankobserve360/charts/). Open one —
say `charts/upi-service/templates/deployment.yaml` — and you'll find the annotation block
already written, **commented out**, waiting for you:

```yaml
      # ─── opt this service INTO monitoring: uncomment these three lines ───
      # annotations:
      #   prometheus.io/scrape: "true"
      #   prometheus.io/path:   "/metrics"
      #   prometheus.io/port:   "8011"
```

Uncomment it, then redeploy the app so the change lands:

```bash
make app          # helm upgrade — rolls upi-service with the annotation
```

(For a quick one-off without editing the chart, you can annotate the running deployment
instead: `kubectl -n bankobs patch deploy upi-service --type=merge -p
'{"spec":{"template":{"metadata":{"annotations":{"prometheus.io/scrape":"true","prometheus.io/path":"/metrics","prometheus.io/port":"8011"}}}}}'`.)

Do it for a few services, or all of them — each one you opt in shows up in Prometheus. To
opt in **every** service at once (uncomments the annotation in all the charts), there's a
shortcut: `make enable-annotations-to-deploy` then `make app` (and `make disable-annotations-to-deploy` reverses it).

## Check Prometheus

```bash
make verify-metrics          # prints how many bankobs targets are UP
```
Open the UI (`make urls` → Prometheus, default `http://<box>:9090`):
- **Status → Targets** — the `bankobs-pods` job, one target per service you opted in, `UP`.
- **Graph** — try `up{namespace="bankobs"}` (1 = scraped OK), or an app metric like
  `http_request_duration_seconds_count`.

Nothing showing? That's expected until you annotate a service (step 2). If a target is `DOWN`,
the pod isn't exposing `/metrics` on the annotated port — check the port you set.

## Recap

Metrics needed **zero** OpenTelemetry. The app exposed a `/metrics` page (a decades-old
convention), and a pull-based scraper collected it. Hold that thought — logs will be just as
OTel-free. Traces won't.

➡ Next: [03-logs-loki.md](03-logs-loki.md) — `make logs`
