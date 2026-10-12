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

➡ Next: [06-why-opentelemetry.md](06-why-opentelemetry.md)
