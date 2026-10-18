# correlation — the trace↔logs payoff (Grafana over all three backends)

After the by-hand lab (metrics, logs, traces as three separate tools), this module puts **one
pane** over them with Grafana and wires the signals together — the "single-pane, one click
from a trace to its logs and back" experience.

Install it (Grafana via Helm, after `make metrics`/`logs`/`traces` are up):

```bash
make correlation        # from the repo root
# or directly:
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update grafana
helm upgrade --install grafana grafana/grafana -n monitoring -f correlation/values-grafana.yaml
```

Open Grafana (`make urls` → Grafana, `http://<box>:3000`, anonymous admin — no login):
- **Dashboard "bankobs — services overview"** — p95 latency / request rate / services up.
- **Explore → Jaeger** — open a trace, then **"Logs for this span"** jumps to that **service's**
  logs in Loki for the same time window (**trace → logs, by service**).

## What's wired (in `values-grafana.yaml`)

| Datasource | Correlation |
|---|---|
| Prometheus (`prometheus-server`) | — |
| Loki | — (queried directly, or reached from a Jaeger span) |
| Jaeger | `tracesToLogsV2`: from a span, open that service's Loki logs — maps the span's `service.name` onto Loki's `app` label |

> **Why by service, not by trace id.** You might expect a one-click jump from a span to the *exact*
> log lines of that request. That needs the **same trace id** in both the span and the log line —
> and bankobs doesn't give us that: the Go/journey tier logs an app `trace_id` that doesn't match
> Beyla's span ids, and the Java core-banking tier logs only a `correlation_id`. So a trace-id log
> search returns nothing. The honest, reliable pivot is **by service**: from a span you open that
> service's logs for the window. (This gap — no shared trace id across logs and traces — is itself
> a lead-in to *why* you reach for a unified, OTel-based stack that stamps one trace id everywhere.)

> This is the *payoff* module — it deliberately contrasts with the by-hand lab, where the three
> tools stand alone. Seeing them correlate is the lead-in to "why you reach for a unified stack."
