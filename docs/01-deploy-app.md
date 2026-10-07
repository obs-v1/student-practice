# Section 1 — The application, with observability OFF

**Goal:** get the 75 bankobs services running and completely silent — nothing collecting
metrics, nothing collecting logs, nothing collecting traces. A true blank slate, so every
pillar you add later is something *you* turned on.

**Run it:** `make app`  (or `make app DRY=1` to see the commands first)

> **Prerequisite — the cluster (Section 0).** This step deploys *onto* the empty Kubernetes
> cluster you created with `make cluster` (see [`cluster/`](../cluster/README.md)). It does
> **not** create a cluster of its own.

---

## What "the app" actually is

bankobs isn't one service — it's ~75 of them, plus the databases (Oracle, Postgres, Mongo,
Cassandra), Kafka, RabbitMQ and a license-checker the services refuse to start without.
Standing all that up is the *platform*, and it's already solved by the bootcamp deploy. This
lab is about observability, not about re-deploying databases, so Section 1 **reuses** that
deploy — pointed at the cluster you built in Section 0:

```bash
make -C ../student-bootcamp/ec2-k8s deploy
```

Note `deploy`, not `up`: `up` would create its *own* kind cluster, but you already have one
from `make cluster`. `deploy` applies the platform (databases, Kafka, license-checker) onto
the current cluster, Helm-installs the 75 application services, and wires their runtime env.
First run pulls a lot of images and waits on slow starters (Oracle) — budget **15–40 minutes**.
Later runs are fast.

> The bootcamp deploy does **not** deploy any observability stack (it leaves that to its own
> Week-1 `make obs-on`). So right after it, there is no Prometheus, no Loki, no Jaeger, no OTel
> Collector — exactly the empty canvas this lab wants.

## Making "silent" explicit

Even with no backends, the services' telemetry SDKs are configured on by default, so they'd
*try* to export (and fail, loudly, against a Collector that isn't there). We switch them fully
off so the starting state is unambiguous:

```bash
kubectl -n bankobs set env deployment -l domain \
  OTEL_SDK_DISABLED=true \
  OBSERVABILITY_MODE=dark \
  MANAGEMENT_TRACING_ENABLED=false \
  MANAGEMENT_OTLP_METRICS_EXPORT_ENABLED=false
```

- `-l domain` selects every application deployment (they all carry a `domain` label; the
  databases and platform pods do not, so they're left alone).
- `OTEL_SDK_DISABLED=true` tells the OpenTelemetry SDK inside each service to do nothing.
- `OBSERVABILITY_MODE=dark` is bankobs's own switch for the same idea.

All the app deployments roll once (in parallel) and come back silent.

## Check it

```bash
kubectl -n bankobs get pods | head
```

You should see the services `Running`. Nothing is scraping them, nothing is tailing their
logs, nothing is receiving traces — because none of those tools exist yet. That's the point.

**Two bits of latent config worth knowing about** (we'll use them later, honestly):
- Each app pod carries `prometheus.io/scrape` / `prometheus.io/path` annotations — inert
  until *you* deploy a Prometheus that acts on them (Section 2).
- Each service's OTLP endpoint env exists but is disabled by `OTEL_SDK_DISABLED=true` — you'll
  re-enable only the traces slice in Section 4.

A truly greenfield app would start with neither; bankobs ships them, so we neutralize them and
light them up deliberately.

➡ Next: [02-metrics-prometheus.md](02-metrics-prometheus.md) — `make metrics`
