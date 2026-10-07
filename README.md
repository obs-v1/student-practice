# student-practice — Observability by hand, without OpenTelemetry

A hands-on lab that builds the three observability pillars for bankobs **one at a time, by
hand**, with no OpenTelemetry Collector:

- **Metrics** → Prometheus *pulls* `/metrics`
- **Logs** → Promtail *tails* stdout → Loki
- **Traces** → the app *pushes* OTLP straight to Jaeger

…and then shows **why OpenTelemetry exists** once you've felt the by-hand version.

## Start here

Read **[docs/00-overview.md](docs/00-overview.md)** — it explains the arc and how the docs and
the Makefile mirror each other.

## Quick start

```bash
# 0. an empty Kubernetes cluster on this host (see cluster/ — tools + kind)
bash cluster/scripts/install-tools.sh   # once, on a fresh VM; then re-login for docker
make cluster    # == make -C cluster up

# 1-4. build the lab on top of that cluster
make app        # 1. deploy bankobs onto the cluster, observability OFF
make metrics    # 2. Prometheus, the pull model
make logs       # 3. Loki + Promtail
make traces     # 4. Jaeger, direct (and the lesson about why traces are different)
make traffic    # generate load
make verify     # check all three pillars
make urls       # the UIs
```

Every target prints each command as it runs. To **print without running** (type it yourself):
`make metrics DRY=1`. The printed steps match `docs/02-metrics-prometheus.md` line for line.

## Layout

```
cluster/   STEP 0 — make Kubernetes available (kind on a VM): tools, kind-config, expose
docs/      00..05  the teaching spine (read these)
metrics/   Prometheus: namespace, RBAC, scrape config, server
logs/      Loki + Promtail: store, RBAC, config, DaemonSet
traces/    Jaeger all-in-one with native OTLP
app/       values-no-obs.yaml — the "observability OFF" overlay
scripts/   step.sh / section.sh — the narration helpers the Makefile uses
Makefile   run any section; DRY=1 to print-only
```

## Requirements

- Kubernetes (validated on single-node **kind**), `kubectl`, `helm`, `jq`.
- A bankobs license in `../student-bootcamp/.env` — `make app` reuses that deploy.
- App namespace `bankobs`; backends namespace `monitoring`.

> Status: code complete; pending end-to-end validation on a fresh VM (see the lab's
> validation checklist).
