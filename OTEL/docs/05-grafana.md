# 05 — Grafana: one pane over the OTel-collected signals

Because the Collector preserves the Prometheus-client metric names and labels, the Grafana layer
is **reused from the parent lab** — same datasources, same dashboards. One command:

```bash
make -C OTEL observe       # = grafana + datasources + golden-dashboard
```

| Sub-step | What it does |
|---|---|
| `make -C OTEL grafana` | installs Grafana (parent's values: v13, login **admin / admin**) |
| `make -C OTEL datasources` | registers Prometheus (default) + Loki + Jaeger, and wires trace→logs |
| `make -C OTEL golden-dashboard` | imports **bankobs — Golden Signals** + **bankobs — Errors by service** |

Open it: `make -C OTEL urls` → Grafana → **http://&lt;box-ip&gt;:3000** (admin / admin).

## The dashboards

**bankobs — Golden Signals** (service variable = **All** or one service): Latency (p50/p95/p99),
Traffic (req/s), Errors (non-2xx share), Saturation (CPU/mem from `process_*`), and an
Availability row from `up`. The Errors panel's **▸** link opens **bankobs — Errors by service**,
whose table/rows link on to Jaeger. All of it runs on the metrics the **Collector** scraped.

## Trace ↔ logs: by trace id (partial coverage — the lesson)

`make -C OTEL datasources` wires the correlation
([`OTEL/scripts/add-datasources.sh`](../scripts/add-datasources.sh)) **by trace id**, with two
OTEL-specific twists: the Loki labels are `k8s_*`, and the Collector wraps each log as
`{"body":"<escaped JSON>"}` so the derived-field regex matches `trace_id` through the escaping.

- **Jaeger → Loki** ("Related logs"): a span's button queries Loki for the span's trace id
  (`{k8s_namespace_name="bankobs"} |= "<traceId>"`). For a **journey-tier** service
  (`loan-origination`, `notification-orchestrator`, `remittance-service`) you land on that **exact
  request's** log lines. For the Go tier (no spans here — no Beyla) and services that don't log a
  trace id it's **empty**: drop the `|= "<id>"` and narrow by `{k8s_container_name="<service>"}`.
- **Loki → Jaeger**: a log line's `trace_id` is a derived field that links back to its trace.

To use it: Explore → **jaeger** → pick a service → open a trace → expand a span → **"Related
logs"**. Try `loan-origination` (a POST / disbursement trace) to see the exact-match land; try a
Python/Java service to see the empty case that you narrow by service.

> **Why it's only partial — the real "why OTel" point.** The Collector *forwards* the app's existing
> logs; it does **not** inject the trace id into them. So correlation is only as good as what the app
> writes — bankobs stamps a `trace_id` into its logs for the Spring journey tier and nowhere else.
> True one-click-everywhere correlation needs the app to run an OTel **log appender** that puts the
> active trace id on every line. That gap — collector present, but logs still un-stamped — is exactly
> what a fully OTel-instrumented app closes.

## Troubleshooting

**Dashboards empty?**
- Give it ~1 min after `make -C OTEL traffic-bg`, then `make -C OTEL verify-metric-names` — if no
  `http_*` names appear, the Collector isn't scraping. Check the pods are annotated
  (`make enable-annotations-to-deploy` *before* deploy) and `make -C OTEL verify-collector`.
- Panels read "datasource not found" → re-run `make -C OTEL datasources` (it binds the dashboards
  to the Prometheus/Jaeger datasource uids).

➡ Next: [06-incident-drills.md](06-incident-drills.md)
