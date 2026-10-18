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

Open Grafana (`make urls` → Grafana, `http://<box>:3000`, log in **admin / admin**):
- **Dashboard "bankobs — services overview"** — p95 latency / request rate / services up.
- **Explore → Jaeger** — open a trace, expand a span, and the **"Related logs"** button opens Loki at
  that span's **time window**. Jaeger can't tell Loki *which* service (see below), so you finish the
  hop by hand — narrow it to `{app="<service>"}` (e.g. `{app="account-service"}`).

## What's wired (in `values-grafana.yaml`)

| Datasource | Correlation |
|---|---|
| Prometheus (`prometheus-server`) | — |
| Loki | — (queried directly, or reached from a Jaeger span) |
| Jaeger | `tracesToLogsV2` (custom query `{namespace="bankobs"}`): from a span, open Loki at that span's time window — you narrow to the service by hand |

> **Why a time-window jump, and not a one-click by-service or by-trace-id jump.** You might expect the
> button to land on the *exact* log lines of that request, or at least that one service's logs. Neither
> is reachable here, and that's the lesson:
> - **Not by trace id** — that needs the **same trace id** in the span and the log line, and bankobs
>   doesn't give us that: the Go/journey tier logs an app `trace_id` that doesn't match Beyla's span
>   ids, and the Java core-banking tier logs only a `correlation_id`. A trace-id log search returns nothing.
> - **Not automatically by service either** — the classic **Jaeger** datasource keeps a span's service
>   in `process.serviceName`, *not* as a span tag. Grafana's trace→logs can't read it: a `service.name`
>   tag mapping resolves to nothing (so no button renders at all), and the custom query exposes
>   `${__span.spanId|name|tags…}` but **no** service-name variable. So the button can only hand Loki a
>   **time window**; you type the service yourself: `{app="<service>"}`.
>
> This gap — no shared trace id, no service name crossing the wire — is exactly *why* you reach for a
> unified, OTel-based stack (collector + a trace-aware store) that stamps one id everywhere and makes
> this a single click. That contrast is the whole point of wiring it by hand first.

> This is the *payoff* module — it deliberately contrasts with the by-hand lab, where the three
> tools stand alone. Seeing them correlate is the lead-in to "why you reach for a unified stack."
