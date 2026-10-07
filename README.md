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

## Two ways to get a cluster

**A — provision a box with Terraform (from your workstation), bootcamp-style:**
```bash
make tf-apply      # creates an EC2 box + an EMPTY kind cluster on it (no app). See main.tf.
make kubeconfig    # writes ~/.kube/lab-ec2.config pointing at it
export KUBECONFIG=~/.kube/lab-ec2.config && kubectl get nodes
make tf-destroy    # when done
```

**B — use a VM you already have (run on the box itself):**
```bash
bash cluster/scripts/install-tools.sh    # once; then re-login so docker works without sudo
make cluster                              # == make -C cluster up
```

Either way you then build the lab (A: with `KUBECONFIG` set, or ssh to the box; B: on the box):

## Quick start (building the lab, once a cluster exists)

```bash
make cluster    # (path B) == make -C cluster up — skip if you used tf-apply

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
main.tf    provision an EC2 box + empty kind cluster (make tf-apply), no app — like the bootcamp
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
