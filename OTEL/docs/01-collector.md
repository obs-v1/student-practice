# 01 — The OpenTelemetry Collector

## The one idea

The Collector is a small service that **receives** telemetry in one place and **exports** it to
wherever it needs to go. It sits between your app and your backends so the app only ever needs
to know **one** address.

```mermaid
flowchart LR
  R["receivers\n(OTLP :4317/:4318)"] --> PR["processors\n(memory_limiter → resource → batch)"]
  PR --> E1["exporter: otlp/jaeger"]
  PR --> E2["exporter: prometheusremotewrite"]
  PR --> E3["exporter: loki"]
  E1 --> J["Jaeger"]
  E2 --> P["Prometheus"]
  E3 --> L["Loki"]
  classDef x fill:#fef3e8,stroke:#d6914a,color:#14213d; class R,PR,E1,E2,E3 x;
```

A Collector config is just three lists plus pipelines that connect them:
**receivers → processors → exporters**.

## The concrete values (this lab)

Everything is in [`collector/values.yaml`](../collector/values.yaml). The important lines:

- **Chart:** `open-telemetry/opentelemetry-collector`, `mode: deployment` (one pod; the app
  pushes to it over the network, so it needn't run on every node).
- **Image:** `otel/opentelemetry-collector-contrib` (the **contrib** build — the
  `prometheusremotewrite` and `loki` exporters are not in the core image), with
  `command.name: otelcol-contrib`.
- **Service name:** `fullnameOverride: otel-collector` → the app reaches it at
  `otel-collector.monitoring.svc:4317`.

Receivers / processors / exporters:

| Part | Value | Why |
|---|---|---|
| receiver | `otlp` grpc `:4317`, http `:4318` | one door for traces + metrics + logs |
| processor | `memory_limiter` | sheds load before OOM — **must be first** |
| processor | `resource` → `deployment.environment=training` | stamps an attribute on every signal |
| processor | `batch` | groups exports for efficiency |
| exporter | `otlp/jaeger` → `jaeger-collector.monitoring:4317` | traces |
| exporter | `prometheusremotewrite` → `http://prometheus-server.monitoring/api/v1/write` | metrics (push) |
| exporter | `loki` → `http://loki.monitoring:3100/loki/api/v1/push` | logs |
| exporter | `debug` | one-line batch summaries in the Collector's own log |

Three pipelines wire them up — one per signal — all sharing the single OTLP receiver.

## The steps

```bash
# install the Collector (Helm)
make collector
```

What the target runs:

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  -n monitoring --create-namespace -f collector/values.yaml
kubectl -n monitoring rollout status deploy/otel-collector --timeout=180s
```

## See it work

Nothing flows yet — the app isn't pointed at it (that's [docs/02](02-app-otel.md)). But you can
confirm it's healthy and watch it live:

```bash
kubectl -n monitoring get deploy otel-collector          # 1/1 ready
kubectl -n monitoring logs -f deploy/otel-collector       # the debug exporter prints here
make verify-collector                                     # accepted/exported counters (0 until app-otel)
```

Once traffic flows, `make verify-collector` shows non-zero
`otelcol_receiver_accepted_*` (coming in) and `otelcol_exporter_sent_*` (going out) — your proof
the pipeline is moving data.

## Why a Collector at all? (the contrast)

In the by-hand lab the app talked to Jaeger directly and Prometheus/Promtail reached in from
outside. That works, but every backend is wired separately and the app is coupled to each one.
With the Collector:

- the **app** has one config line (`OTEL_EXPORTER_OTLP_ENDPOINT`) regardless of how many
  backends you run;
- you **swap, add or remove a backend** by editing the Collector, never the app (change
  `prometheusremotewrite` to an OTLP vendor endpoint and you've switched metrics vendors with
  zero app redeploys);
- you can **process** signals in flight (filter, redact, batch, add attributes) in one place.

➡ Next: [02-app-otel.md](02-app-otel.md)
