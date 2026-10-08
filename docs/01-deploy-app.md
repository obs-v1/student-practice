# 1. Deploy the app with observability off

**Goal:** get the 75 bankobs services running and completely silent — nothing collecting
metrics, nothing collecting logs, nothing collecting traces. A true blank slate, so every
pillar you add later is something *you* turned on.

**Run it:** `make app`  (or `make app DRY=1` to see the commands first)

> **Prerequisite — the cluster (Section 0).** This step deploys *onto* the empty Kubernetes
> cluster you created with `make cluster` (see [`cluster/`](../cluster/README.md)). It does
> **not** create a cluster of its own.

---

## What we're deploying

bankobs isn't one service — it's ~75 of them, plus the databases (Oracle, Postgres, Mongo,
Cassandra), Kafka, RabbitMQ and a license-checker the services refuse to start without. All of
that — the Helm chart, the database manifests, the init scripts — lives in this repo under
[`bankobs/`](../bankobs/), so the deploy is self-contained:

```bash
make -C bankobs deploy
```

It applies the platform (databases, Kafka, license-checker) onto the cluster you built in
Section 0, Helm-installs the application services, and wires their runtime env. First run pulls
a lot of images and waits on slow starters (Oracle) — budget **15–40 minutes**; later runs are
fast. (`make app`, below, runs this for you and then turns telemetry off.)

> This deploys **no** observability stack — no Prometheus, no Loki, no Jaeger, no OTel
> Collector. That's the point: an empty canvas you wire up by hand in the next sections.

> **License:** the images need a `LICENSE_KEY`. Put yours in `bankobs/.env`
> (`cp bankobs/.env.example bankobs/.env`) or pass it inline: `LICENSE_KEY=... make -C bankobs deploy`.

## Start from silence

bankobs is OpenTelemetry-instrumented, so each service would otherwise try to export
telemetry on startup. There's no backend to receive it yet, so we turn the SDK off and begin
from a clean slate:

```bash
kubectl -n bankobs set env deployment -l domain OTEL_SDK_DISABLED=true
```

(`-l domain` hits the application services only — the databases and platform pods aren't
labelled `domain`.) That's the only setting we touch here. Everything else you'll switch on
yourself, one section at a time, as each backend goes in.

## Check it worked

```bash
kubectl -n bankobs get pods | head
```

You should see the services `Running`. Nothing is scraping them, nothing is tailing their
logs, nothing is receiving traces, because none of those tools exist yet.

The services do already expose a `/metrics` endpoint and write to stdout — that's just how
they're built. Those outputs sit there unused until you add a backend to collect them, which
is what the next three sections do, one at a time.

➡ Next: [02-metrics-prometheus.md](02-metrics-prometheus.md) — `make metrics`
