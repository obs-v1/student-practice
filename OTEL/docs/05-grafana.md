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

## Trace → logs: by service, not by trace id

`make -C OTEL datasources` wires the **OTEL-specific** correlation
([`OTEL/scripts/add-datasources.sh`](../scripts/add-datasources.sh)) because bankobs logs carry
`correlation_id`, not `trace_id` ([03](03-logs-with-otel.md)):

- **Jaeger → Loki** ("Trace to logs"): maps the span's `service.name` to the Loki label
  `k8s_container_name` and opens **that service's logs in the span's time window**
  (`filterByTraceID: false`). So from a slow span you jump straight to that service's logs around
  that moment.
- **Loki** derived field surfaces `correlation_id` for pivoting within a request.

To use it: Explore → **jaeger** → pick a service → open a trace → a span → **"Logs for this
span"** → Loki opens filtered to that service.

## Troubleshooting

**Dashboards empty?**
- Give it ~1 min after `make -C OTEL traffic-bg`, then `make -C OTEL verify-metric-names` — if no
  `http_*` names appear, the Collector isn't scraping. Check the pods are annotated
  (`make enable-annotations-to-deploy` *before* deploy) and `make -C OTEL verify-collector`.
- Panels read "datasource not found" → re-run `make -C OTEL datasources` (it binds the dashboards
  to the Prometheus/Jaeger datasource uids).

➡ Next: [06-incident-drills.md](06-incident-drills.md)
