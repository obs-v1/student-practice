# 07 — Incident drills: inject a fault, find the root cause

Everything is wired. Now practice the loop a real on-call does: **something breaks → the Golden
Signals dashboard shows it → you follow metrics → traces → logs to the actual cause.**

Two drills: a **5xx outage** and a **latency** incident. Each is one command to inject, one to
revert, and a fixed path through the three pillars.

## Before you start
```bash
make all                 # cluster must exist first: make cluster  (or tf-apply)
make grafana && make datasources && make golden-dashboard
make traffic-bg          # steady traffic so there is something to break
```
Open Grafana (`make urls` → Grafana, login **admin / admin**) → dashboard **bankobs — Golden
Signals**, Service = **All**, Last 15 minutes.

---

## Drill 1 — a 5xx outage (payment chain)

**Inject:**
```bash
make fault NAME=app-down TARGET=upi-service
```
This takes `upi-service` out from under the payment chain.

**1. Metrics — Golden Signals → which service.** The **Errors** panel (non-2xx) climbs. Click its
**▸ "Which service?"** link → **bankobs — Errors by service**. The **Top services by errors** table
and the per-service chart show **`payment-gateway`** and **`gateway-service`** spiking **5xx**
(not the Python 404 noise — real server errors).

**2. Traces — where in the chain.** Explore → **jaeger** → Service **`payment-gateway`** (or
`gateway-service`) → open a recent trace. The span that calls `upi-service` **fails** — you'll see
the error on that hop. (These Go services only appear because **Beyla** eBPF-instruments them;
without it the trace would have a hole here.) Copy the **trace_id**.

**3. Logs — the actual cause.** Explore → **loki**:
```
{namespace="bankobs"} |= "<trace_id>"
```
or go straight to the caller: `{app="gateway-service"}`. You'll find the real message —
**`ERR_UPSTREAM` / `dial tcp …:8011: connect: connection refused`**. That's upi-service being
unreachable.

**Root cause:** `upi-service` is down; `payment-gateway`/`gateway-service` can't reach it, so they
return **502 `ERR_UPSTREAM`**.

**Revert:** `make fault-stop NAME=app-down TARGET=upi-service`

---

## Drill 2 — a latency incident

**Inject:** (adds a 1500 ms `tc netem` delay to `account-service`'s network; override with `LAT_MS=3000`)
```bash
make fault NAME=latency
```

**1. Metrics — Golden Signals → which service.** The **Latency** panel's p95 climbs. Set
**Service = `account-service`**: its p95 jumps from ~8 ms to **~2 s** (every account-touching call
now waits on the delayed network). The services that *call* it (e.g. `branch-service`,
`loan-origination`) climb too, since they inherit the wait. The **Saturation** panels stay flat —
the tell that this is *wait*, not CPU/memory.

**2. Traces — where the time goes.** Explore → **jaeger** → Service **`account-service`** → open a
slow trace. The waterfall shows the time sitting in `account-service`'s own span (its outbound
hop is slow), not spread across the tree — the *trace* localises the single culprit, while the
per-service dashboard made several services look regressed at once.

**3. Logs.** `{app="account-service"}` — the logs are normal (no errors): a latency incident has
**no error signature**, which is itself the diagnosis. The time is in the span, not the log.

**Root cause:** an injected **network delay on `account-service`** — a slow hop, not a failure.

**Revert:** `make fault-stop NAME=latency`

---

## The mental model (both drills)
| Pillar | Question it answers |
|---|---|
| **Metrics** (Golden Signals / Errors / Latency) | *Is* something wrong, and **which** service? |
| **Traces** (Jaeger) | **Where** in the request — which hop/span? |
| **Logs** (Loki) | **Why** — the exact error, or (for latency) the absence of one |

Check in-flight faults any time with `make fault-status`, and `make fault-stop NAME=…` always
reverts. Keep `make traffic-bg` running throughout so the panels have live data.
