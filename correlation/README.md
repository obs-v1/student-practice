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
- **Explore → Jaeger** — open a trace, then **"Logs for this span"** jumps to the Loki logs for
  that trace (**trace → logs**).
- **Explore → Loki** — a log line's extracted **TraceID** links straight to the trace in Jaeger
  (**logs → trace**).

## What's wired (in `values-grafana.yaml`)

| Datasource | Correlation |
|---|---|
| Prometheus (`prometheus-server`) | — |
| Loki | `derivedFields`: regex pulls `"trace_id":"…"` from the JSON log line → link to Jaeger |
| Jaeger | `tracesToLogsV2`: from a span, query Loki `{namespace="bankobs"} |= "<traceId>"` |

Both directions work because bankobs services log structured JSON containing `trace_id`.

> This is the *payoff* module — it deliberately contrasts with the by-hand lab, where the three
> tools stand alone. Seeing them correlate is the lead-in to "why you reach for a unified stack."
