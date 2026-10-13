# 5. Grafana — one pane over your backends

So far each backend has its own door: Prometheus on `:9090`, Jaeger on `:16686`, Loki only
through its API. **Grafana** is a single UI you point at all three. In this section you install
Grafana and then **add the three datasources yourself, in the UI** — so you see exactly how
Grafana connects to a backend (it's just a name, a type, and a URL).

**Run it:** `make grafana`

---

## Install Grafana

One Helm command. [`grafana/values.yaml`](../grafana/values.yaml) installs a **plain** Grafana —
NodePort on `:3000`, anonymous admin (so it opens with no login), and **no datasources**
(that's your job, next).

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update grafana

helm upgrade --install grafana grafana/grafana \
  -n monitoring --create-namespace -f grafana/values.yaml

kubectl -n monitoring rollout status deploy/grafana
```

Open it (`make urls` → Grafana, `http://<box>:3000`). It drops you straight into Grafana as an
admin — no login. Right now it has nothing to show; let's connect it to your backends.

## Add the three datasources (by hand)

In Grafana, go to **Connections → Data sources → Add data source** (the ☰ menu on the left, or
the URL `/connections/datasources/new`). You'll do this three times. Each datasource is just:
pick the **type**, paste the in-cluster **URL**, click **Save & test**.

Grafana runs in the `monitoring` namespace, the same namespace as the backends, so you can
address each one by its plain Kubernetes service name:

| # | Type | URL to enter | What it is |
|---|------|--------------|------------|
| 1 | **Prometheus** | `http://prometheus-server` | the Prometheus Helm chart's server service (port 80) |
| 2 | **Loki** | `http://loki:3100` | the loki-stack Loki service |
| 3 | **Jaeger** | `http://jaeger:16686` | the Jaeger query UI service |

For each one:

1. Click **Add data source**, choose the type (e.g. **Prometheus**).
2. In **Connection → Prometheus server URL**, enter the URL from the table
   (e.g. `http://prometheus-server`). Leave everything else default.
3. Scroll down and click **Save & test**. You want a green **"Successfully queried the
   Prometheus API"** (Loki and Jaeger give their own success message).

If **Save & test** fails, it's almost always the URL — check the service name and port with
`kubectl -n monitoring get svc` (you should see `prometheus-server`, `loki`, `jaeger`).

## See it work

Go to **Explore** (compass icon), pick a datasource from the dropdown at the top, and query:

- **Prometheus** → `up{namespace="bankobs"}` (or any metric), run it, see a graph.
- **Loki** → `{namespace="bankobs"}`, run it, see log lines.
- **Jaeger** → **Search** → pick a service (e.g. `upi-service`) → **Run query** → traces.

(For metrics and traces to have data, a service must be opted into scraping
(`make enable-annotations-to-deploy`) and traces must be on (`make traces`), with some
`make traffic`.)

## What you just did — and the automatic version

A datasource is nothing magic: a **type + a URL** telling Grafana how to reach a backend. You
added three, and now one UI reads all three.

Two things to know:

- **These live in Grafana's database**, which in this lab is **not persisted** — restart the
  Grafana pod and your datasources are gone. In production you don't click them in each time;
  you **provision** them from a file so they come back automatically.
- Provisioning is also how you wire the **trace ↔ logs correlation** (click from a Jaeger span
  to its Loki logs, and from a log line's `trace_id` back to the trace) — fiddly to set up by
  hand, trivial as config.

That's exactly what the [`correlation/`](../correlation/README.md) module does: `make
correlation` installs the *same* Grafana but with all three datasources **and** the trace↔logs
links pre-provisioned (and an overview dashboard). Run it once you've seen the manual version —
it's the "now automate it" step.

## Dashboards empty? Checks, in order

A blank Golden Signals dashboard is almost always one of these — walk them top to bottom:

0. **Is the `Service` filter pinned to one quiet service?** The dashboard has a **Service**
   dropdown (top-left) that scopes every panel. It defaults to **All**, but a shared link can
   pin it to a single service — and the backend *adapters* (e.g. `aadhaar-adapter`, `pan-adapter`)
   get only a trickle of traffic, so scoped to one of them the graphs look empty. Set
   **Service → All** (or pick a busy one like `fraud-detection` / `kyc-service`) first.

1. **Is any traffic flowing?** The panels use `rate(...)`, so a flat counter draws nothing.
   Run `make traffic` (a 60s burst) or `make traffic-bg` (keeps load running in the
   background). Confirm the counter moves:
   ```
   # services with live request rate — should be > 0 after ~1 min of load
   curl -s 'http://localhost:9090/api/v1/query?query=count(sum%20by%20(app)(rate(http_requests_total%7Bnamespace%3D%22bankobs%22%7D%5B5m%5D))%3E0)'
   ```
   > **Use a 5m window, not 1m.** Prometheus scrapes every **60s** here, so `rate(...[1m])`
   > has too few samples and looks empty. Grafana's `$__rate_interval` widens it
   > automatically — this only bites you when you query the API by hand.

2. **Are services opted into scraping?** The charts ship with the scrape annotation
   commented out (you opt in by hand). If Prometheus has 0 targets, run
   `make enable-annotations-to-deploy && make app`, then check
   `make verify-metrics` (`bankobs targets up:` should be ~55+).

3. **Is the datasource bound?** `make golden-dashboard` auto-discovers the Prometheus
   datasource and binds it, so the panels read a real `uid` rather than an empty
   `${datasource}`. If you imported the JSON by hand instead, pick the Prometheus
   datasource in the dashboard's top-left dropdown.

> **If login itself fails (portal returns 500) there is no traffic to show.** The deposit
> service writes IDs longer than the schema's original `fd_id`/`rd_id` width; the init
> script (`infrastructure/databases/postgres/init-scripts/01-init.sql`) now creates those as
> `VARCHAR(40)`, so a **freshly provisioned** cluster is fine. On a cluster built before that
> fix, widen them once with `make -C bankobs wait` (runs the `seed-extras` `ALTER`).

➡ Next: [06-why-opentelemetry.md](06-why-opentelemetry.md)
