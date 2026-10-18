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
- **Explore → Jaeger** — open a trace, expand a span, and hit **"Related logs"**: it queries Loki for
  that span's **trace id** (`{namespace="bankobs"} |= "<traceId>"`). For a **journey-tier** service
  (e.g. `loan-origination`) you land on that exact request's log lines; for others it comes back empty
  (see coverage below) — drop the `|= "<id>"` and narrow by `{app="<service>"}` instead.
- **Explore → Loki** — the reverse: any JSON log line with a `trace_id` field shows a **TraceID** link
  that opens that trace in Jaeger (logs → trace).

## What's wired (in `values-grafana.yaml`)

| Datasource | Correlation |
|---|---|
| Prometheus (`prometheus-server`) | — |
| Loki | `derivedFields`: each line's `trace_id` → a link to its Jaeger trace (**logs → trace**) |
| Jaeger | `tracesToLogsV2` (custom query `{namespace="bankobs"} |= "$${__trace.traceId}"`): a span → Loki filtered to that trace id (**trace → logs**) |

> **The trace-id jump correlates a span to its *exact* log lines** — it needs the **same trace id**
> stamped into both, and every bankobs tier does that, through in-app OpenTelemetry:
> - ✅ **Journey tier** (`loan-origination`, `notification-orchestrator`, `remittance-service`, …) —
>   OTel SDK; the span's trace id is the one in its logs.
> - ✅ **Go payment tier** (`gateway-service`, `payment-gateway`, `upi-service`) — the shared Go OTel
>   SDK; it exports real spans and stamps the same `trace_id` into its logs (once `OBSERVABILITY_MODE=full`,
>   set by `make enable-annotations-to-deploy`).
> - ✅ **Java/Spring + Python tiers** — Spring OTLP / OTel SDK, same deal.
>
> The one thing that can still come up empty is per-request: a trace whose service didn't write a log
> line for it has nothing to match, so you drop the `|= "<id>"` and scope by service. (`$${...}` in the
> YAML is Grafana's provisioning env-escape — see the file header.)

> This is the *payoff* module — it deliberately contrasts with the by-hand lab, where the three
> tools stand alone. Seeing them correlate is the lead-in to "why you reach for a unified stack."
