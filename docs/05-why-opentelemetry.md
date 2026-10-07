# Section 5 — Now, why OpenTelemetry

You just built all three pillars by hand. Stand back and look at what that took.

## Three pillars, three completely different mechanisms

| Pillar | How you collected it | Who did the work | App change |
|--------|----------------------|------------------|------------|
| Metrics | Prometheus **pulls** `/metrics` | a scrape config + RBAC | none (annotation) |
| Logs | Promtail **tails** stdout, pushes to Loki | a Promtail config + DaemonSet | none |
| Traces | App **pushes** OTLP to Jaeger | in-process **OTel SDK** in every service | the SDK itself |

Three mental models (pull vs tail vs push). Three agents to deploy and keep alive. Three
config languages (scrape relabeling, Promtail pipelines, SDK env vars). Three label/metadata
schemes that *don't automatically agree* — your Prometheus `app` label, your Loki `app` label
and your Jaeger service name are correlated only because you were careful. And traces forced a
library into every service, in every language.

Now imagine operating that across hundreds of services and a dozen languages. Every new
service is three integrations. Every language needs its own tracing library. Correlating a
slow trace with its logs and metrics means hoping three independent pipelines labeled things
the same way.

**That is the problem OpenTelemetry was built to solve.**

## What OTel collapses

OpenTelemetry attacks the mess from both ends:

**One SDK, one API, per language — for all three signals.** Instead of a metrics library *and*
a logging setup *and* a per-language tracing library, you instrument once with the OTel SDK and
get metrics, logs and traces that already share the same resource attributes (so
`service.name` is the *same* string everywhere — automatic correlation). For many services you
don't even write code: **auto-instrumentation** adds the spans for you.

**One Collector in the middle — for all three signals.** Instead of a pull-scraper *and* a
log-tailer *and* a direct trace path, every service speaks **one protocol (OTLP)** to **one
agent (the Collector)**, which does the batching, sampling, relabeling and PII-scrubbing in
*one* place and fans out to Prometheus, Loki and Jaeger behind it. Swap Jaeger for Tempo?
Change one line in the Collector, touch no service. Add a new backend? Add one exporter.

```
            BY HAND (this lab)                      WITH OTEL (the course)

  app /metrics ──pull── Prometheus          app ─┐
  app stdout  ──tail── Promtail→Loki        app ─┼─ OTLP ─► OTel Collector ─┬─► Prometheus
  app OTLP    ──push── Jaeger               app ─┘                          ├─► Loki
                                                                            └─► Jaeger
  3 mechanisms, 3 agents, 3 configs         1 protocol, 1 agent, 1 config, swappable backends
```

## The sharpest point — from Section 4

Metrics and logs, you collected with **zero** OpenTelemetry: the app exposed a page and wrote
to stdout, and tools reached in from outside. You could run that forever without OTel.

**Traces, you could not.** A trace only exists if something inside the process creates it as
the request flows. Pre-OTel that meant a different tracing library for every language — the
fragmentation (OpenTracing *vs* OpenCensus, Zipkin *vs* Jaeger clients) that made distributed
tracing painful for a decade. OpenTelemetry is the **merger that ended it**: one vendor-neutral
standard for the one signal you can't collect any other way — and, having solved tracing, it
unified metrics and logs under the same roof so you stop running three of everything.

That's the "why." You felt the by-hand version; OTel is what you reach for so you don't have to
do it by hand at scale.

## Clean up

```bash
make clean                               # remove Prometheus/Loki/Promtail/Jaeger; app back to dark
make -C ../student-bootcamp/ec2-k8s down # (optional) tear the whole platform down
```
