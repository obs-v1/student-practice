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

> **Why the trace-id jump works for some services and is empty for others — that split IS the lesson.**
> Correlating a span to its *exact* log lines needs the **same trace id** stamped into both. bankobs
> only does that in part:
> - ✅ **Journey tier** (`loan-origination`, `notification-orchestrator`, `remittance-service`, …) logs
>   the OTel trace id that Jaeger also has → the button lands on that request's lines.
> - ❌ **Go payment tier** (`gateway-service`, `payment-gateway`) is traced by **Beyla** (eBPF), which
>   mints its *own* trace ids — so the app's logged `trace_id` never matches the Jaeger one.
> - ❌ **Python/Java tiers** (`fraud-detection`, `account-service`, …) don't log a trace id at all.
>
> So the result is precise where the id propagates and empty where it doesn't. There's no single id
> crossing every hop — which is exactly *why* you reach for a unified, OTel-based stack (collector +
> SDK log-correlation) that stamps one trace id into every span **and** every log line. Feeling that
> gap by hand is the whole point. (`$${...}` in the YAML is Grafana's provisioning env-escape — see the
> file header.)

> This is the *payoff* module — it deliberately contrasts with the by-hand lab, where the three
> tools stand alone. Seeing them correlate is the lead-in to "why you reach for a unified stack."
