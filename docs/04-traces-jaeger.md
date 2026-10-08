# 4. Traces with Jaeger

**Goal:** get distributed traces into Jaeger. You'll point the app straight at Jaeger with
**no OpenTelemetry Collector** in the middle. But this section is also where the "without
OpenTelemetry" story **breaks** — on purpose. Read to the end.

**Run it:** `make traces`  (or `make traces DRY=1`)

---

## Why traces are different

Metrics and logs were things the app *emits* that a tool collects from outside:
- a `/metrics` page Prometheus pulls,
- stdout lines Promtail tails.

A **trace** is not like that. A trace is the story of **one request** as it hops through
gateway → payment-gateway → upi-service → fraud-detection → …, with a shared trace ID and a
parent/child span for every hop. To build it, each service must:

1. **read** the incoming trace context from the request headers,
2. **start a span**, time the work,
3. **inject** the context into every outbound call, and
4. **send** the finished span to a backend.

All of that happens **inside the process, in the request path**. Nothing standing outside the
app — no scraper, no log tailer — can reconstruct it. Traces *require* in-process
instrumentation. Full stop.

## What "without OpenTelemetry" means here

Two honest layers:

**Layer 1 — no Collector (we do this).** Jaeger can receive OTLP *natively*, so we drop the
OTel **Collector** and let the app send traces **straight to Jaeger**. Deploy Jaeger, then
turn the SDK back on (the switch you flipped off in Section 1) and point it at Jaeger:

```bash
kubectl apply -f traces/jaeger.yaml

kubectl -n bankobs set env deployment -l domain \
  OTEL_SDK_DISABLED=false MANAGEMENT_TRACING_ENABLED=true \
  OTEL_METRICS_EXPORTER=none OTEL_LOGS_EXPORTER=none \
  OTEL_EXPORTER_OTLP_ENDPOINT=http://jaeger-collector.monitoring.svc:4317
```

Turn the SDK back on (`OTEL_SDK_DISABLED=false`) and point it at Jaeger. The
`OTEL_*_EXPORTER=none` pair keeps metrics and logs off this path — they stay with Prometheus
and Loki — so only traces go to Jaeger.

That's a real simplification over the course's setup — one fewer moving part, the app talks to
Jaeger directly.

**Layer 2 — no OTel *at all* (we cannot, with this app).** Those two env vars only mean
something because **every bankobs service is instrumented with the OpenTelemetry SDK**. Turn
OTel fully off and the app produces **no traces** — not fewer, *none*. There is no `/traces`
page to scrape, no trace file to tail. The spans exist only if code inside the service creates
them.

To get traces here with *truly* no OpenTelemetry, you'd have to rip the OTel SDK out of all 75
services and replace it with a pre-OTel tracing library **per language** — jaeger-client for
the Python/Go services, Spring Cloud Sleuth / Brave for the Java ones, something else for the
Node ones — each with its own API, its own config, its own propagation format. (That pre-OTel
world is shown, runnable, in `code-blocks/2.3.11/before-otel/`.)

So: metrics and logs were genuinely OTel-optional. **Traces are not.** That is not a gap in
this lab — it *is* the lesson.

## Open Jaeger

```bash
make traffic            # generate journeys
make verify-traces      # which services have reported traces to Jaeger?
```

Open the Jaeger UI (`make urls` → Jaeger, default `http://<node>:30686`):
- pick a service like `upi-service` or `gateway-service` → **Find Traces**,
- open a payment trace and see the waterfall span the whole fleet.

## The point

You removed the Collector and wired traces app → Jaeger directly — a legitimate, simpler
setup. But you also hit the wall: traces can't be collected from the outside, and the only
reason this app can emit them at all is the OpenTelemetry SDK baked into every service.

Keep that fresh for the final section.

➡ Next: [05-why-opentelemetry.md](05-why-opentelemetry.md)
