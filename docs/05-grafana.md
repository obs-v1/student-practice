# 5. Grafana — one pane over your backends

So far each backend has its own door: Prometheus on `:9090`, Jaeger on `:16686`, Loki only
through its API. **Grafana** is a single UI you point at all three. In this section you install
Grafana and then **add the three datasources yourself, in the UI** — so you see exactly how
Grafana connects to a backend (it's just a name, a type, and a URL).

**Run it:** `make grafana`

---

## Install Grafana

One Helm command. [`grafana/values.yaml`](../grafana/values.yaml) installs a **plain** Grafana —
NodePort on `:3000`, login as **`admin` / `admin`**, and **no datasources**
(that's your job, next). The values pin the image to **Grafana 13** (`13.2.4`, the latest 13.x);
the `grafana/grafana` chart's own appVersion still tracks 12.x, so we override `image.tag` — the
chart runs whatever image we hand it.

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update grafana

helm upgrade --install grafana grafana/grafana \
  -n monitoring --create-namespace -f grafana/values.yaml

kubectl -n monitoring rollout status deploy/grafana
```

Open it (`make urls` → Grafana, `http://<box>:3000`). Sign in at the login page with
**`admin` / `admin`**. Right now it has nothing to show; let's connect it to your backends.

## Add the three datasources (by hand)

> **In a hurry?** `make datasources` registers all three at once via the Grafana API
> (`prometheus` set as the default, `loki`, `jaeger`) **and** wires the trace↔logs correlation —
> Jaeger's "Trace to logs" → Loki (`{namespace="bankobs"} |= "${__trace.traceId}"`) and Loki's
> derived-field `trace_id` → Jaeger. Do it by hand once (below) to understand what a datasource
> is, then use the target thereafter. (`make correlation` is the fully-provisioned variant with
> an overview dashboard baked in.)

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

## Follow an error to its root cause (metrics → traces → logs)

This is the payoff of having all three pillars. A single error is four questions, and each
pillar answers one:

| Question | Pillar | Tells you |
|---|---|---|
| Is something wrong? | **Metrics** — Golden Signals | *that* errors are happening, and the rate |
| **Which** service / endpoint? | **Metrics** — Errors dashboard | the culprit: `app · handler · status` |
| **Where** in the call chain? | **Traces** — Jaeger | which hop in the request actually broke |
| **Why** did it break? | **Logs** — Loki | the real exception / error message |

```
Golden Signals ──▶ Errors dashboard ──▶ Jaeger trace ──▶ Loki logs
  "errors!"          "upi-service /pay    "the debit span    "ERR_DEBIT:
                      is 502"              is red here"        Oracle timeout"
   (metrics)          (metrics)            (traces)            (logs)
```

### Prerequisite — turn tracing on

Metrics and logs are always on, but **traces are off until you ask for them** (that is the
whole point of section 4 / the "why OTel" story). Check and enable:

```
# is the app emitting spans? jaeger-all-in-one alone = nothing from the app
make traces        # OTEL_SDK_DISABLED=false + MANAGEMENT_TRACING_ENABLED=true, spans → jaeger
make traffic       # drive some requests so there are failing traces to find
```

If you skip this, Jaeger will be empty and you can still do **metrics → logs** (steps 1–2 and
4 below), just not the "where in the call chain" hop.

### Walk it

1. **Which service?** On **Golden Signals**, the **Errors** panel has a link
   *"▸ Which service? Open Errors by service"* → opens **bankobs — Errors by service**. The
   *Top failing endpoints* table gives you the culprit, e.g. `upi-service · /pay · 502`.

2. **Where in the call chain?** Open the **jaeger** datasource (Explore, or the Jaeger UI) →
   **Search** → `service = upi-service`, add tag **`error=true`**, set the time range to the
   spike → **Run**. Open a failing trace: the **red / errored span** is the exact hop that
   broke (e.g. `upi-service → account-service → Oracle`). Note its **`trace_id`**.

3. **Why?** Pivot to the **loki** datasource and pull every log line for that one request:

   ```
   {namespace="bankobs"} |= "<trace_id>"
   ```

   Those lines carry the real cause — the exception, the failing dependency, the SQL error
   (e.g. `ERR_DEBIT`, `HikariPool timeout`, `relation ... does not exist`). That is your
   **why**.

> **Remember the label is `app`, not `service`.** To scope logs to one service use
> `{app="upi-service"}` (the `service` value lives *inside* the JSON line, reachable with
> `| json | service="upi-service"`, but it is not a stream label).

### Two ways to make the trace↔logs hop

- **By hand (what you have now):** copy the `trace_id` from the Jaeger span and paste it into
  the Loki query above. Works, but it is copy-paste.
- **One click (`make correlation`):** this provisions the datasources with the links, so a
  Jaeger span grows a **"Logs for this span"** button (jumps straight to the Loki logs for that
  trace) and a Loki line's **`trace_id`** becomes a link back into Jaeger. It is the same
  journey, without the copy-paste — the `derivedFields` (Loki→Jaeger) and `tracesToLogsV2`
  (Jaeger→Loki) that a hand-added datasource does not have.

### No traces? Metrics → logs still gets you most of the way

If you have not run `make traces`, you can still answer *what* and *why* — just skip the Jaeger
hop: from the Errors dashboard you know the service, so query its errors directly:

```
{app="upi-service"} | json | level="ERROR"
```

The only thing you lose is *where in the call chain* — which the trace would have shown you.

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
