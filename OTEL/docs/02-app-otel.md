# 02 — Pointing the app at the Collector

## The one idea

OpenTelemetry-instrumented apps are configured **entirely by environment variables**. You don't
touch code — you set a handful of `OTEL_*` vars and the SDK does the rest. Here we flip the SDK
on and tell it to send **all three signals** to the Collector over OTLP.

## By-hand lab vs. here — the same switch, used differently

The by-hand lab's `make traces` turned the SDK on but sent **only traces**, straight to Jaeger:

```bash
OTEL_SDK_DISABLED=false MANAGEMENT_TRACING_ENABLED=true \
OTEL_METRICS_EXPORTER=none OTEL_LOGS_EXPORTER=none \
OTEL_EXPORTER_OTLP_ENDPOINT=http://jaeger-collector.monitoring.svc:4317
```

This module's `make app-otel` turns on **all three** and sends them to the **Collector**:

```bash
OTEL_SDK_DISABLED=false MANAGEMENT_TRACING_ENABLED=true \
OTEL_TRACES_EXPORTER=otlp OTEL_METRICS_EXPORTER=otlp OTEL_LOGS_EXPORTER=otlp \
OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.monitoring.svc:4317
```

## The concrete values

| Variable | Value | Meaning |
|---|---|---|
| `OTEL_SDK_DISABLED` | `false` | turn the SDK on (the app ships "dark" = `true`) |
| `OTEL_TRACES_EXPORTER` | `otlp` | send traces over OTLP |
| `OTEL_METRICS_EXPORTER` | `otlp` | send metrics over OTLP |
| `OTEL_LOGS_EXPORTER` | `otlp` | send logs over OTLP |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `grpc` | use the gRPC OTLP transport (port 4317) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector.monitoring.svc:4317` | **the Collector**, not a backend |
| `MANAGEMENT_TRACING_ENABLED` | `true` | the Spring/Java services gate span creation on this |

Notice: **one** endpoint for everything. In the by-hand lab you needed a scrape annotation
(metrics), a log tailer (logs) **and** a trace endpoint (traces) — three separate mechanisms.
Here it's one variable.

## The steps

```bash
make app-otel
```

which runs a single `kubectl set env` across every app deployment (selected by the `domain`
label, same as the parent lab):

```bash
kubectl -n bankobs set env deployment -l domain \
  OTEL_SDK_DISABLED=false MANAGEMENT_TRACING_ENABLED=true \
  OTEL_TRACES_EXPORTER=otlp OTEL_METRICS_EXPORTER=otlp OTEL_LOGS_EXPORTER=otlp \
  OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
  OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.monitoring.svc:4317
```

Each deployment rolls once to pick up the new env.

## See it work

```bash
make traffic            # drive some requests
make verify-collector   # the Collector's accepted/exported counters should climb
make verify             # services show up in Prometheus / Loki / Jaeger
```

Then watch the Collector actually receive and forward the data:

```bash
kubectl -n monitoring logs -f deploy/otel-collector
```

## Honest caveat — does the app honour all three exporters?

Setting `OTEL_METRICS_EXPORTER=otlp` / `OTEL_LOGS_EXPORTER=otlp` only works if each service's
runtime actually wires metrics and logs into the SDK (Spring Boot / the OTel Java agent does;
a service that only set up tracing will export traces and quietly ignore the rest). bankobs is a
mix of languages. **Verify per signal** with `make verify` — if traces arrive but metrics or
logs don't, that service isn't emitting that signal through the SDK, and the fix is on the app
side, not here. This is itself a real-world lesson: "OTLP for everything" is only as true as
the instrumentation behind it.

➡ Next: [03-metrics-with-otel.md](03-metrics-with-otel.md)
